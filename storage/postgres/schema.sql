-- =============================================================================
-- schema.sql — DAG metrics and RCA storage schema
-- Applied to PostgreSQL in monitoring namespace
-- =============================================================================

CREATE TABLE IF NOT EXISTS dag_metrics (
    id                          SERIAL PRIMARY KEY,
    dag_id                      VARCHAR(250) NOT NULL,
    task_id                     VARCHAR(250),
    run_id                      VARCHAR(250) NOT NULL,
    execution_date              TIMESTAMP NOT NULL,
    start_date                  TIMESTAMP,
    end_date                    TIMESTAMP,
    duration_seconds            FLOAT,
    state                       VARCHAR(50),             -- success | failed | running
    error_message               TEXT,
    error_type                  VARCHAR(250),
    -- RCA fields (populated by Ollama on failure)
    rca_root_cause              TEXT,
    rca_category                VARCHAR(100),            -- data_issue | resource_exhaustion | etc
    rca_confidence              FLOAT,
    rca_immediate_fix           TEXT,
    rca_prevention              TEXT,
    rca_severity                VARCHAR(50),             -- low | medium | high | critical
    rca_retry_recommended       BOOLEAN,
    rca_affected_downstream     TEXT,
    rca_similar_past_incidents  TEXT,
    rca_estimated_fix_minutes   INTEGER,
    rca_generated_at            TIMESTAMP,
    rca_model_used              VARCHAR(100),
    rca_response_time_seconds   FLOAT,
    -- Notification tracking
    notification_sent           BOOLEAN DEFAULT FALSE,
    notification_channels       TEXT,                    -- email,slack
    created_at                  TIMESTAMP DEFAULT NOW()
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_dag_metrics_dag_id        ON dag_metrics(dag_id);
CREATE INDEX IF NOT EXISTS idx_dag_metrics_execution_date ON dag_metrics(execution_date);
CREATE INDEX IF NOT EXISTS idx_dag_metrics_state          ON dag_metrics(state);
CREATE INDEX IF NOT EXISTS idx_dag_metrics_run_id         ON dag_metrics(run_id);

-- View for anomaly detection baseline calculation
CREATE OR REPLACE VIEW dag_baselines AS
SELECT
    dag_id,
    COUNT(*)                                                    AS total_runs,
    AVG(duration_seconds)                                       AS avg_duration,
    STDDEV(duration_seconds)                                    AS stddev_duration,
    AVG(duration_seconds) + (2 * STDDEV(duration_seconds))     AS upper_threshold,
    GREATEST(0, AVG(duration_seconds) - (2 * STDDEV(duration_seconds))) AS lower_threshold,
    MAX(execution_date)                                         AS last_run,
    SUM(CASE WHEN state = 'failed' THEN 1 ELSE 0 END)          AS failure_count,
    ROUND(
        100.0 * SUM(CASE WHEN state = 'success' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0),
        2
    )                                                           AS success_rate_pct
FROM dag_metrics
WHERE state IN ('success', 'failed')
  AND execution_date > NOW() - INTERVAL '30 days'
GROUP BY dag_id
HAVING COUNT(*) >= 5;

-- View for recent RCA summary (last 50 failures)
CREATE OR REPLACE VIEW recent_rca_summary AS
SELECT
    dag_id,
    task_id,
    execution_date,
    rca_severity,
    rca_category,
    rca_root_cause,
    rca_confidence,
    rca_immediate_fix,
    rca_model_used,
    created_at
FROM dag_metrics
WHERE state = 'failed'
  AND rca_root_cause IS NOT NULL
ORDER BY created_at DESC
LIMIT 50;

-- Grant privileges
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO metrics_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO metrics_user;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO metrics_user;
