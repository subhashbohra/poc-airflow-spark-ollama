"""
anomaly_detector.py — DAG execution time baseline and drift detection

Uses dag_metrics PostgreSQL table to:
1. Calculate mean ± 2σ baseline per DAG
2. Detect when current run exceeds upper_threshold
3. Return structured anomaly report for Ollama explanation
"""
import logging
import os
from datetime import datetime, timedelta
from typing import Optional

log = logging.getLogger(__name__)

METRICS_DB_HOST = os.getenv("METRICS_DB_HOST", "postgres-metrics-svc.monitoring.svc.cluster.local")
METRICS_DB_PORT = int(os.getenv("METRICS_DB_PORT", "5432"))
METRICS_DB_NAME = os.getenv("METRICS_DB_NAME", "metrics")
METRICS_DB_USER = os.getenv("METRICS_DB_USER", "metrics_user")
METRICS_DB_PASSWORD = os.getenv("METRICS_DB_PASSWORD", "metrics_poc_password_2024")


def _get_connection():
    """Get psycopg2 connection to metrics PostgreSQL."""
    import psycopg2
    return psycopg2.connect(
        host=METRICS_DB_HOST,
        port=METRICS_DB_PORT,
        dbname=METRICS_DB_NAME,
        user=METRICS_DB_USER,
        password=METRICS_DB_PASSWORD,
        connect_timeout=10,
    )


def get_dag_history(dag_id: str, lookback_days: int = 30) -> dict:
    """
    Fetch historical stats for a DAG from dag_metrics.
    Used by RCA callback to populate the prompt with historical context.
    """
    try:
        conn = _get_connection()
        cur = conn.cursor()

        cur.execute("""
            SELECT
                COUNT(*) as total_runs,
                AVG(duration_seconds) as avg_duration,
                STDDEV(duration_seconds) as stddev_duration,
                ARRAY_AGG(state ORDER BY execution_date DESC) as recent_states
            FROM dag_metrics
            WHERE dag_id = %s
              AND execution_date > NOW() - INTERVAL '%s days'
            LIMIT 1
        """, (dag_id, lookback_days))

        row = cur.fetchone()
        cur.close()
        conn.close()

        if row and row[0]:
            states = row[3] or []
            return {
                "total_runs": int(row[0]),
                "avg_duration": round(float(row[1] or 0), 1),
                "stddev_duration": round(float(row[2] or 0), 1),
                "recent_statuses": states[:3],
            }
    except Exception as e:
        log.warning(f"Could not fetch DAG history for {dag_id}: {e}")

    return {
        "total_runs": 0,
        "avg_duration": 0,
        "stddev_duration": 0,
        "recent_statuses": [],
    }


def get_all_dag_baselines() -> list:
    """
    Fetch all DAG baselines from the dag_baselines view.
    Used by anomaly_detection_dag.py.
    """
    try:
        conn = _get_connection()
        cur = conn.cursor()

        cur.execute("""
            SELECT
                dag_id,
                total_runs,
                avg_duration,
                stddev_duration,
                upper_threshold,
                lower_threshold,
                last_run,
                failure_count,
                success_rate_pct
            FROM dag_baselines
            ORDER BY dag_id
        """)

        rows = cur.fetchall()
        cur.close()
        conn.close()

        baselines = []
        for row in rows:
            baselines.append({
                "dag_id": row[0],
                "total_runs": int(row[1]),
                "avg_duration": float(row[2] or 0),
                "stddev_duration": float(row[3] or 0),
                "upper_threshold": float(row[4] or 0),
                "lower_threshold": float(row[5] or 0),
                "last_run": row[6],
                "failure_count": int(row[7] or 0),
                "success_rate_pct": float(row[8] or 0),
            })
        return baselines
    except Exception as e:
        log.error(f"Could not fetch DAG baselines: {e}")
        return []


def get_recent_runs(dag_id: str, limit: int = 10) -> list:
    """Fetch the most recent runs for a specific DAG."""
    try:
        conn = _get_connection()
        cur = conn.cursor()

        cur.execute("""
            SELECT
                run_id, execution_date, duration_seconds, state
            FROM dag_metrics
            WHERE dag_id = %s
              AND state IN ('success', 'failed')
            ORDER BY execution_date DESC
            LIMIT %s
        """, (dag_id, limit))

        rows = cur.fetchall()
        cur.close()
        conn.close()

        return [
            {
                "run_id": r[0],
                "execution_date": r[1],
                "duration_seconds": float(r[2] or 0),
                "state": r[3],
            }
            for r in rows
        ]
    except Exception as e:
        log.error(f"Could not fetch recent runs for {dag_id}: {e}")
        return []


def detect_anomalies(baselines: list) -> list:
    """
    Check each DAG's most recent run against its baseline.
    Returns list of anomaly dicts for DAGs that exceeded 2σ threshold.
    """
    anomalies = []

    for baseline in baselines:
        dag_id = baseline["dag_id"]
        if baseline["total_runs"] < 5:
            continue  # Not enough history

        recent_runs = get_recent_runs(dag_id, limit=1)
        if not recent_runs:
            continue

        latest = recent_runs[0]
        current_duration = latest["duration_seconds"]
        upper_threshold = baseline["upper_threshold"]

        if current_duration > upper_threshold and upper_threshold > 0:
            deviation_pct = ((current_duration - baseline["avg_duration"]) /
                             max(baseline["avg_duration"], 1)) * 100
            anomalies.append({
                "dag_id": dag_id,
                "current_duration": current_duration,
                "avg_duration": baseline["avg_duration"],
                "stddev_duration": baseline["stddev_duration"],
                "upper_threshold": upper_threshold,
                "deviation_pct": round(deviation_pct, 1),
                "run_id": latest["run_id"],
                "execution_date": latest["execution_date"],
                "total_runs": baseline["total_runs"],
                "success_rate_pct": baseline["success_rate_pct"],
            })
            log.warning(
                f"Anomaly detected for {dag_id}: "
                f"{current_duration:.1f}s vs threshold {upper_threshold:.1f}s "
                f"({deviation_pct:.1f}% above avg)"
            )

    return anomalies


def store_metric(
    dag_id: str,
    task_id: Optional[str],
    run_id: str,
    execution_date: datetime,
    start_date: Optional[datetime],
    end_date: Optional[datetime],
    duration_seconds: float,
    state: str,
    error_message: Optional[str] = None,
    error_type: Optional[str] = None,
) -> int:
    """
    Insert a DAG run metric into dag_metrics table.
    Returns the new row ID, or -1 on failure.
    """
    try:
        conn = _get_connection()
        cur = conn.cursor()

        cur.execute("""
            INSERT INTO dag_metrics (
                dag_id, task_id, run_id, execution_date,
                start_date, end_date, duration_seconds, state,
                error_message, error_type
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id
        """, (
            dag_id, task_id, run_id, execution_date,
            start_date, end_date, duration_seconds, state,
            error_message, error_type,
        ))

        row_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
        conn.close()

        log.info(f"Stored metric for {dag_id}/{run_id}: id={row_id}, state={state}")
        return row_id
    except Exception as e:
        log.error(f"Failed to store metric for {dag_id}: {e}")
        return -1


def update_rca_in_db(row_id: int, rca: dict) -> bool:
    """Update an existing dag_metrics row with Ollama RCA data."""
    try:
        conn = _get_connection()
        cur = conn.cursor()

        cur.execute("""
            UPDATE dag_metrics SET
                rca_root_cause              = %s,
                rca_category                = %s,
                rca_confidence              = %s,
                rca_immediate_fix           = %s,
                rca_prevention              = %s,
                rca_severity                = %s,
                rca_retry_recommended       = %s,
                rca_affected_downstream     = %s,
                rca_similar_past_incidents  = %s,
                rca_estimated_fix_minutes   = %s,
                rca_generated_at            = NOW(),
                rca_model_used              = %s,
                rca_response_time_seconds   = %s
            WHERE id = %s
        """, (
            rca.get("root_cause"),
            rca.get("root_cause_category"),
            rca.get("confidence"),
            rca.get("immediate_fix"),
            rca.get("prevention"),
            rca.get("severity"),
            rca.get("retry_recommended"),
            rca.get("affected_downstream"),
            rca.get("similar_past_incidents"),
            rca.get("estimated_fix_time_minutes"),
            rca.get("_model_used"),
            rca.get("_response_time_seconds"),
            row_id,
        ))

        conn.commit()
        cur.close()
        conn.close()
        log.info(f"Updated RCA for metric row {row_id}")
        return True
    except Exception as e:
        log.error(f"Failed to update RCA in DB (row {row_id}): {e}")
        return False
