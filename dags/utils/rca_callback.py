"""
rca_callback.py — on_failure_callback implementation for all DAGs

Full RCA pipeline:
1. Collect context (dag_id, task_id, logs, error)
2. Fetch historical DAG stats
3. Build prompt
4. Call Ollama
5. Store in PostgreSQL
6. Send email + Slack notifications

Include in every DAG's default_args:
    default_args = {
        'on_failure_callback': generate_rca_on_failure,
        ...
    }
"""
import logging
from datetime import datetime

log = logging.getLogger(__name__)


def generate_rca_on_failure(context: dict) -> dict:
    """
    Full RCA pipeline triggered on any task failure.
    Called automatically by Airflow when a task fails.
    """
    # -------------------------------------------------------------------------
    # 1. Extract context
    # -------------------------------------------------------------------------
    dag = context.get("dag")
    task_instance = context.get("task_instance")
    dag_id = dag.dag_id if dag else "unknown_dag"
    task_id = task_instance.task_id if task_instance else "unknown_task"
    run_id = context.get("run_id", "unknown_run")
    execution_date = context.get("execution_date", datetime.utcnow())
    exception = context.get("exception", "Unknown error")

    log.info(f"RCA triggered for {dag_id}/{task_id} run={run_id}")

    # -------------------------------------------------------------------------
    # 2. Get log excerpt (last 100 lines)
    # -------------------------------------------------------------------------
    log_excerpt = ""
    try:
        # Try to get logs from task instance
        if task_instance:
            log_excerpt = str(exception)
            # In production, you'd read from log handlers or Airflow log API
            # For PoC, we use the exception string + any additional context
    except Exception as e:
        log.warning(f"Could not extract logs: {e}")
        log_excerpt = str(exception)

    # -------------------------------------------------------------------------
    # 3. Get historical stats for this DAG
    # -------------------------------------------------------------------------
    try:
        from utils.anomaly_detector import get_dag_history, store_metric, update_rca_in_db
        history = get_dag_history(dag_id)
    except Exception as e:
        log.warning(f"Could not fetch DAG history: {e}")
        history = {"total_runs": 0, "avg_duration": 0, "recent_statuses": []}

    # -------------------------------------------------------------------------
    # 4. Store initial failure metric (without RCA yet)
    # -------------------------------------------------------------------------
    metric_row_id = -1
    try:
        from utils.anomaly_detector import store_metric
        duration = getattr(task_instance, "duration", None) or 0
        start_date = getattr(task_instance, "start_date", None)
        end_date = getattr(task_instance, "end_date", None)

        metric_row_id = store_metric(
            dag_id=dag_id,
            task_id=task_id,
            run_id=run_id,
            execution_date=execution_date if isinstance(execution_date, datetime) else datetime.utcnow(),
            start_date=start_date,
            end_date=end_date,
            duration_seconds=float(duration),
            state="failed",
            error_message=str(exception)[:1000],
            error_type=type(exception).__name__ if exception else "Unknown",
        )
    except Exception as e:
        log.warning(f"Could not store initial metric: {e}")

    # -------------------------------------------------------------------------
    # 5. Build RCA prompt and call Ollama
    # -------------------------------------------------------------------------
    try:
        from utils.rca_prompt import build_rca_prompt
        from utils.ollama_client import generate_rca

        prompt = build_rca_prompt(
            dag_id=dag_id,
            task_id=task_id,
            execution_date=execution_date,
            duration_seconds=float(getattr(task_instance, "duration", None) or 0),
            error_type=type(exception).__name__ if exception else "Unknown",
            error_message=str(exception)[:500],
            log_excerpt=log_excerpt[:2000],
            total_runs=history.get("total_runs", 0),
            avg_duration=history.get("avg_duration", 0),
            recent_statuses=history.get("recent_statuses", []),
        )

        log.info("Calling Ollama for RCA generation...")
        rca = generate_rca(prompt)
        log.info(f"RCA generated: severity={rca.get('severity')}, "
                 f"confidence={rca.get('confidence')}, "
                 f"category={rca.get('root_cause_category')}")

    except Exception as e:
        log.error(f"RCA generation failed: {e}")
        rca = {
            "root_cause": f"RCA pipeline error: {str(e)}",
            "root_cause_category": "configuration",
            "confidence": 0.0,
            "immediate_fix": "Check Ollama service and network policy",
            "prevention": "Ensure Ollama pod is running before DAG execution",
            "retry_recommended": True,
            "estimated_fix_time_minutes": 15,
            "severity": "medium",
            "affected_downstream": "Unknown",
            "similar_past_incidents": "none",
            "_error": str(e),
            "_model_used": "ollama/gemma2:2b",
            "_response_time_seconds": 0,
        }

    # -------------------------------------------------------------------------
    # 6. Update RCA in PostgreSQL
    # -------------------------------------------------------------------------
    if metric_row_id > 0:
        try:
            from utils.anomaly_detector import update_rca_in_db
            update_rca_in_db(metric_row_id, rca)
        except Exception as e:
            log.warning(f"Could not update RCA in DB: {e}")

    # -------------------------------------------------------------------------
    # 7. Send notifications (email + Slack)
    # -------------------------------------------------------------------------
    try:
        from utils.notifier import send_failure_email, send_slack_alert
        send_failure_email(dag_id, task_id, execution_date, exception, rca)
        send_slack_alert(dag_id, task_id, execution_date, exception, rca)
    except Exception as e:
        log.error(f"Notification sending failed: {e}")

    log.info(f"RCA pipeline complete for {dag_id}/{task_id}")
    return rca
