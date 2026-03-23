"""
anomaly_detection_dag.py — Baseline computation + drift detection + Ollama explanation

Runs every 30 minutes. Checks all DAGs' recent run times against 2σ baseline.
If anomaly detected, asks Ollama to explain it and sends alert.

Schedule: */30 * * * *
"""
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator

from utils.rca_callback import generate_rca_on_failure

default_args = {
    "owner": "data-engineering",
    "retries": 1,
    "retry_delay": timedelta(minutes=2),
    "email_on_failure": False,
    "on_failure_callback": generate_rca_on_failure,
}


def _fetch_recent_metrics(**context):
    """Query dag_metrics for all DAG baselines (last 30 days, min 5 runs)."""
    from utils.anomaly_detector import get_all_dag_baselines
    baselines = get_all_dag_baselines()
    print(f"Fetched baselines for {len(baselines)} DAGs:")
    for b in baselines:
        print(f"  {b['dag_id']}: avg={b['avg_duration']:.1f}s, "
              f"2σ_upper={b['upper_threshold']:.1f}s, "
              f"runs={b['total_runs']}, "
              f"success_rate={b['success_rate_pct']:.1f}%")

    context["task_instance"].xcom_push(key="baselines", value=baselines)
    return {"dag_count": len(baselines)}


def _detect_anomalies(**context):
    """
    Compare most recent run duration against 2σ baseline threshold.
    Push anomaly list to XCom for downstream tasks.
    """
    from utils.anomaly_detector import detect_anomalies
    baselines = context["task_instance"].xcom_pull(key="baselines")

    if not baselines:
        print("No baselines available. Skipping anomaly detection.")
        context["task_instance"].xcom_push(key="anomalies", value=[])
        return {"anomaly_count": 0}

    anomalies = detect_anomalies(baselines)

    if anomalies:
        print(f"⚠️  {len(anomalies)} anomaly(ies) detected:")
        for a in anomalies:
            print(f"  DAG: {a['dag_id']}")
            print(f"    Current: {a['current_duration']:.1f}s")
            print(f"    Average: {a['avg_duration']:.1f}s")
            print(f"    Threshold: {a['upper_threshold']:.1f}s")
            print(f"    Deviation: +{a['deviation_pct']:.1f}%")
    else:
        print("✅ No anomalies detected. All DAGs within normal range.")

    context["task_instance"].xcom_push(key="anomalies", value=anomalies)
    return {"anomaly_count": len(anomalies)}


def _explain_anomaly(**context):
    """
    For each detected anomaly, ask Ollama to explain what might cause it.
    Uses shorter prompt (plain text, not JSON) for natural language explanation.
    """
    from utils.ollama_client import generate_anomaly_explanation
    from utils.rca_prompt import build_anomaly_prompt

    anomalies = context["task_instance"].xcom_pull(key="anomalies") or []

    if not anomalies:
        print("No anomalies to explain.")
        context["task_instance"].xcom_push(key="anomaly_explanations", value=[])
        return {"explained": 0}

    explained = []
    for anomaly in anomalies:
        dag_id = anomaly["dag_id"]
        print(f"Getting Ollama explanation for anomaly in {dag_id}...")

        # Build context string for explanation
        context_str = (
            f"DAG: {dag_id}\n"
            f"Current duration: {anomaly['current_duration']:.1f}s\n"
            f"Historical average: {anomaly['avg_duration']:.1f}s\n"
            f"Threshold (2σ): {anomaly['upper_threshold']:.1f}s\n"
            f"Deviation: +{anomaly['deviation_pct']:.1f}% above normal\n"
            f"Total historical runs: {anomaly['total_runs']}\n"
            f"Success rate: {anomaly['success_rate_pct']:.1f}%"
        )

        explanation = generate_anomaly_explanation(context_str)
        print(f"  Explanation: {explanation}")

        # Also get structured analysis
        try:
            from utils.rca_prompt import build_anomaly_prompt
            from utils.ollama_client import generate_rca
            from utils.anomaly_detector import get_recent_runs

            recent_runs = get_recent_runs(dag_id, limit=5)
            prompt = build_anomaly_prompt(
                dag_id=dag_id,
                current_duration=anomaly["current_duration"],
                avg_duration=anomaly["avg_duration"],
                stddev_duration=anomaly["stddev_duration"],
                upper_threshold=anomaly["upper_threshold"],
                run_history=recent_runs,
            )
            ai_analysis = generate_rca(prompt)
        except Exception as e:
            print(f"  Could not get structured analysis: {e}")
            ai_analysis = {
                "anomaly_explanation": explanation,
                "likely_cause": "unknown",
                "confidence": 0.5,
                "recommended_action": "Review recent DAG logs and check system resources",
                "severity": "medium",
                "escalate_to_oncall": False,
                "estimated_resolution_minutes": 30,
            }

        explained.append({
            "anomaly": anomaly,
            "explanation": explanation,
            "ai_analysis": ai_analysis,
        })

    context["task_instance"].xcom_push(key="anomaly_explanations", value=explained)
    return {"explained": len(explained)}


def _send_alert(**context):
    """Send email + Slack alert for each detected anomaly."""
    from utils.notifier import send_anomaly_email, send_slack_alert

    explanations = context["task_instance"].xcom_pull(key="anomaly_explanations") or []

    if not explanations:
        print("No anomalies to alert on.")
        return {"alerts_sent": 0}

    alerts_sent = 0
    for item in explanations:
        anomaly = item["anomaly"]
        explanation = item["explanation"]
        ai_analysis = item["ai_analysis"]
        dag_id = anomaly["dag_id"]

        print(f"Sending anomaly alert for {dag_id}...")
        send_anomaly_email(dag_id, anomaly, explanation, ai_analysis)

        # Slack alert (simplified)
        try:
            from airflow.providers.slack.hooks.slack_webhook import SlackWebhookHook
            hook = SlackWebhookHook(slack_webhook_conn_id="slack_default")
            hook.send(text=(
                f"📊 *Anomaly Detected: {dag_id}*\n"
                f"Duration: {anomaly['current_duration']:.0f}s "
                f"(avg: {anomaly['avg_duration']:.0f}s, +{anomaly['deviation_pct']:.0f}%)\n"
                f"AI: {explanation[:200]}"
            ))
        except Exception:
            pass  # Slack is optional

        alerts_sent += 1

    print(f"✅ {alerts_sent} anomaly alert(s) sent.")
    return {"alerts_sent": alerts_sent}


with DAG(
    dag_id="anomaly_detection_dag",
    description="Baseline computation + drift detection every 30 min",
    default_args=default_args,
    schedule_interval="*/30 * * * *",
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["poc", "anomaly-detection", "monitoring"],
    doc_md="""
## Anomaly Detection DAG

Runs every 30 minutes to detect timing anomalies across all DAGs.

**Algorithm:**
1. Fetch mean ± 2σ baseline from `dag_baselines` view (30-day window, min 5 runs)
2. Compare each DAG's most recent run against its upper threshold
3. If anomaly detected: ask Ollama to explain the likely cause
4. Send email + Slack alert with AI explanation and recommended action

**Threshold:** `avg_duration + 2 * stddev_duration` (covers 95.4% of normal runs)
**Minimum history:** 5 successful runs required before anomaly detection activates
""",
) as dag:

    fetch_metrics = PythonOperator(
        task_id="fetch_recent_metrics",
        python_callable=_fetch_recent_metrics,
    )

    detect_anomalies_task = PythonOperator(
        task_id="detect_anomalies",
        python_callable=_detect_anomalies,
    )

    explain_anomaly = PythonOperator(
        task_id="explain_anomaly",
        python_callable=_explain_anomaly,
    )

    send_alert = PythonOperator(
        task_id="send_alert",
        python_callable=_send_alert,
    )

    fetch_metrics >> detect_anomalies_task >> explain_anomaly >> send_alert
