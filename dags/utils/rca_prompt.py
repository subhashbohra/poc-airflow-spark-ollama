"""
rca_prompt.py — Prompt templates for Ollama RCA generation

Critical: prompt forces structured JSON output matching dag_metrics schema.
Temperature must stay at 0.1 for deterministic JSON.
"""

RCA_PROMPT_TEMPLATE = """
You are an expert Apache Airflow and Apache Spark data engineer.
A production data pipeline has failed. Analyze the failure and respond ONLY with valid JSON.

FAILURE DETAILS:
- DAG: {dag_id}
- Task: {task_id}
- Execution Date: {execution_date}
- Duration before failure: {duration_seconds} seconds
- Error Type: {error_type}
- Error Message: {error_message}

RECENT LOG LINES:
{log_excerpt}

HISTORICAL CONTEXT:
- This DAG has run {total_runs} times
- Average duration: {avg_duration} seconds
- Last 3 run statuses: {recent_statuses}

Respond with ONLY this JSON structure, no other text:
{{
  "root_cause": "One clear sentence describing the root cause",
  "root_cause_category": "one of: data_issue | resource_exhaustion | connectivity | configuration | code_error | dependency_failure | permission_denied | timeout",
  "confidence": 0.85,
  "immediate_fix": "Exact actionable step to fix this right now",
  "prevention": "How to prevent this in future",
  "retry_recommended": true,
  "estimated_fix_time_minutes": 15,
  "severity": "one of: low | medium | high | critical",
  "affected_downstream": "Brief description of what downstream processes are at risk",
  "similar_past_incidents": "Pattern match from log history if any"
}}
"""


ANOMALY_PROMPT_TEMPLATE = """
You are a data pipeline reliability expert.
An Apache Airflow DAG execution time anomaly has been detected.

ANOMALY DETAILS:
- DAG: {dag_id}
- Current run duration: {current_duration:.1f} seconds
- Historical average: {avg_duration:.1f} seconds
- Standard deviation: {stddev_duration:.1f} seconds
- Deviation: {deviation_pct:.1f}% above normal
- Upper threshold (2σ): {upper_threshold:.1f} seconds

RECENT RUN HISTORY:
{run_history}

Respond with ONLY this JSON structure, no other text:
{{
  "anomaly_explanation": "One clear sentence explaining why this run took longer",
  "likely_cause": "one of: data_volume_spike | resource_contention | network_latency | dependency_slowness | memory_pressure | configuration_drift | external_system",
  "confidence": 0.75,
  "recommended_action": "Specific action to investigate or resolve",
  "severity": "one of: low | medium | high",
  "escalate_to_oncall": false,
  "estimated_resolution_minutes": 20
}}
"""


def build_rca_prompt(
    dag_id: str,
    task_id: str,
    execution_date,
    duration_seconds: float,
    error_type: str,
    error_message: str,
    log_excerpt: str,
    total_runs: int,
    avg_duration: float,
    recent_statuses: list,
) -> str:
    """Build the RCA prompt from the template with all context filled in."""
    return RCA_PROMPT_TEMPLATE.format(
        dag_id=dag_id,
        task_id=task_id,
        execution_date=str(execution_date),
        duration_seconds=round(duration_seconds, 1),
        error_type=error_type,
        error_message=str(error_message)[:500],
        log_excerpt=str(log_excerpt)[:2000],
        total_runs=total_runs,
        avg_duration=round(avg_duration, 1),
        recent_statuses=recent_statuses,
    )


def build_anomaly_prompt(
    dag_id: str,
    current_duration: float,
    avg_duration: float,
    stddev_duration: float,
    upper_threshold: float,
    run_history: list,
) -> str:
    """Build the anomaly detection prompt."""
    deviation_pct = ((current_duration - avg_duration) / max(avg_duration, 1)) * 100
    history_str = "\n".join([
        f"  - Run {i+1}: {r.get('duration_seconds', 0):.1f}s ({r.get('state', 'unknown')})"
        for i, r in enumerate(run_history[-5:])
    ])
    return ANOMALY_PROMPT_TEMPLATE.format(
        dag_id=dag_id,
        current_duration=current_duration,
        avg_duration=avg_duration,
        stddev_duration=stddev_duration,
        deviation_pct=deviation_pct,
        upper_threshold=upper_threshold,
        run_history=history_str or "  - No history available",
    )
