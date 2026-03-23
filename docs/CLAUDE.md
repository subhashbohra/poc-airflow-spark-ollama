# CLAUDE.md — Airflow + Spark + Ollama RCA PoC

## Project Goal
Build a complete AI-enhanced data pipeline PoC on personal GCP that demonstrates:
1. Apache Airflow on GKE (Helm, same pattern as enterprise GDC deployment)
2. Ephemeral Spark jobs via Spark Operator (WordCount sample app)
3. Ollama LLM on GKE as internal ClusterIP service (no external traffic)
4. AI-powered DAG failure RCA — Ollama analyzes logs, generates root cause + fix
5. Anomaly detection — baseline DAG execution times, alert on drift
6. Email + Slack notifications with full AI-generated RCA report
7. A manager-ready demo showing before/after incident response

This PoC mirrors the enterprise GDC architecture exactly.
Everything stays inside the cluster — no calls to Vertex AI or any external API.

---

## GCP Project Details
- Project ID: [USER WILL PROVIDE]
- Region: [USER WILL PROVIDE — default us-central1]
- Zone: [USER WILL PROVIDE — default us-central1-a]
- Cluster name: [USER WILL PROVIDE — default: poc-cluster]
- Kubernetes version: latest stable

Claude must ask the user for these values at the start if not provided.

---

## Repository Structure to Create

```
poc-airflow-spark-ollama/
├── CLAUDE.md                          # This file
├── README.md                          # Manager-facing overview
├── setup.sh                           # One-shot setup script
├── teardown.sh                        # Clean up all resources
│
├── infra/
│   ├── gke/
│   │   ├── create-cluster.sh          # GKE cluster creation
│   │   └── cluster-config.yaml        # Node pool specs
│   ├── namespaces/
│   │   └── namespaces.yaml            # All namespaces + labels
│   └── network-policies/
│       └── network-policies.yaml      # ClusterIP isolation rules
│
├── airflow/
│   ├── helm/
│   │   ├── values.yaml                # Airflow Helm values (mirrors GDC pattern)
│   │   └── install.sh                 # Helm install script
│   ├── webserver-secret.yaml          # Airflow fernet + webserver secret
│   └── connections/
│       └── setup-connections.sh       # Airflow connections (SMTP, Slack)
│
├── spark/
│   ├── operator/
│   │   ├── install.sh                 # Spark Operator Helm install
│   │   └── values.yaml                # Spark Operator Helm values
│   ├── apps/
│   │   ├── wordcount/
│   │   │   ├── wordcount-app.yaml     # SparkApplication CR (ephemeral)
│   │   │   └── wordcount-trigger.sh  # Manual trigger script
│   │   └── sample-etl/
│   │       └── sample-etl-app.yaml   # Sample ETL SparkApplication
│   └── rbac/
│       └── spark-rbac.yaml           # ServiceAccount + RBAC for Spark
│
├── ollama/
│   ├── namespace.yaml
│   ├── deployment.yaml               # Ollama Deployment (CPU mode, no GPU needed)
│   ├── service.yaml                  # ClusterIP service port 11434
│   ├── pvc.yaml                      # 30GB PVC for model storage
│   ├── network-policy.yaml           # Allow only from airflow namespace
│   ├── configmap.yaml                # Model names, temperature settings
│   └── model-loader/
│       ├── load-models.sh            # Pull models into the pod
│       └── verify-models.sh          # Health check + model list
│
├── dags/
│   ├── rca_dag.py                    # Main DAG: Spark job + RCA on failure
│   ├── anomaly_detection_dag.py      # Baseline + drift detection DAG
│   ├── wordcount_dag.py              # Simple WordCount Spark DAG
│   ├── test_failure_dag.py           # Intentional failure DAG for demo
│   └── utils/
│       ├── ollama_client.py          # Reusable Ollama API client
│       ├── rca_prompt.py             # Prompt templates for RCA
│       ├── anomaly_detector.py       # Baseline + drift logic
│       └── notifier.py               # Email + Slack notification helpers
│
├── notifications/
│   ├── email/
│   │   └── rca_email_template.html   # Rich HTML email template
│   └── slack/
│       └── rca_slack_template.py     # Slack Block Kit message builder
│
├── storage/
│   └── postgres/
│       ├── deployment.yaml           # PostgreSQL for metrics storage
│       ├── service.yaml
│       └── schema.sql                # dag_metrics table schema
│
├── monitoring/
│   ├── grafana/
│   │   ├── install.sh
│   │   └── dashboards/
│   │       └── pipeline-health.json  # Pre-built Grafana dashboard
│   └── prometheus/
│       └── values.yaml
│
└── demo/
    ├── run-demo.sh                   # Full end-to-end demo script
    ├── inject-failure.sh             # Trigger a DAG failure for demo
    └── DEMO-SCRIPT.md               # Step-by-step manager demo guide
```

---

## Architecture — What Gets Built

```
GKE Cluster (personal GCP)
│
├── namespace: airflow
│   ├── Airflow Webserver
│   ├── Airflow Scheduler
│   ├── Airflow Workers
│   └── PostgreSQL (Airflow metadata DB)
│
├── namespace: spark-operator
│   └── Spark Operator Controller
│
├── namespace: spark-jobs
│   └── Ephemeral SparkApplication pods (created on DAG trigger, deleted on complete)
│
├── namespace: llm-serving
│   ├── Ollama Deployment (gemma2:2b model)
│   ├── ClusterIP Service :11434
│   └── PVC (model storage)
│
├── namespace: monitoring
│   ├── PostgreSQL (dag_metrics table)
│   ├── Prometheus
│   └── Grafana
│
└── Network Policy: only airflow → llm-serving traffic allowed
```

---

## Step-by-Step Build Order

Claude must execute in this exact order. Do not skip steps.

### Phase 1 — GKE Cluster
1. Create GKE cluster (Standard, not Autopilot — matches GDC behavior)
2. Create all namespaces with labels
3. Apply network policies
4. Verify cluster health

### Phase 2 — Spark Operator
Install Spark Operator before Airflow so DAGs can reference it immediately.
1. Add Helm repo: `helm repo add spark-operator https://kubeflow.github.io/spark-operator`
2. Install Spark Operator in `spark-operator` namespace
3. Create RBAC for Spark jobs in `spark-jobs` namespace
4. Deploy WordCount SparkApplication to verify operator works
5. Verify job completes and pods are ephemeral (deleted after completion)

### Phase 3 — Ollama LLM Service
Must be running before Airflow DAGs are deployed so the RCA callback can reach it.
1. Create `llm-serving` namespace
2. Deploy PVC (30GB)
3. Deploy Ollama (CPU mode — `ollama/ollama:latest`)
4. Create ClusterIP service
5. Apply network policy (allow only from airflow namespace)
6. Exec into pod and pull model: `ollama pull gemma2:2b`
7. Verify API responds: `curl http://ollama-service.llm-serving.svc.cluster.local:11434/api/tags`
8. Run a test inference to confirm model works

### Phase 4 — PostgreSQL for Metrics
1. Deploy PostgreSQL in `monitoring` namespace
2. Create `dag_metrics` table (see schema below)
3. Verify connectivity

### Phase 5 — Airflow (Helm)
1. Create Airflow namespace
2. Generate fernet key and webserver secret
3. Configure Helm values (see Airflow Config section)
4. Install via Helm: `helm install airflow apache-airflow/airflow`
5. Wait for all pods Running
6. Set up SMTP connection for email notifications
7. Set up Slack connection (if webhook URL provided)
8. Copy DAG files to Airflow DAGs folder / configure git-sync

### Phase 6 — DAGs Deployment
1. Deploy all DAGs
2. Unpause DAGs in Airflow UI
3. Trigger test_failure_dag.py to verify RCA pipeline works end-to-end
4. Verify email received with AI-generated RCA
5. Run wordcount_dag.py to verify Spark integration

### Phase 7 — Monitoring
1. Install Prometheus + Grafana
2. Import pipeline health dashboard
3. Verify metrics flowing

---

## Airflow Helm Configuration (values.yaml)

Key settings that mirror the GDC enterprise pattern:

```yaml
# airflow/helm/values.yaml
defaultAirflowTag: "2.9.2"
airflowVersion: "2.9.2"

executor: KubernetesExecutor   # Same as GDC — pods per task, ephemeral

webserver:
  replicas: 1
  resources:
    requests:
      memory: "1Gi"
      cpu: "500m"
    limits:
      memory: "2Gi"
      cpu: "1"

scheduler:
  replicas: 1
  resources:
    requests:
      memory: "1Gi"
      cpu: "500m"
    limits:
      memory: "2Gi"
      cpu: "1"

# Use official postgres subchart
postgresql:
  enabled: true
  auth:
    postgresPassword: "airflow_poc_password"
    username: "airflow"
    password: "airflow_poc_password"
    database: "airflow"

# Git-sync for DAGs (or use persistent volume — Claude should use PV for simplicity)
dags:
  persistence:
    enabled: true
    size: 5Gi
  gitSync:
    enabled: false

# Extra pip packages for Airflow workers
_pip_extra_requirements: >-
  ollama==0.1.8
  requests
  psycopg2-binary
  apache-airflow-providers-smtp
  apache-airflow-providers-slack

config:
  core:
    dags_folder: /opt/airflow/dags
    load_examples: false
  smtp:
    smtp_host: "smtp.gmail.com"
    smtp_starttls: true
    smtp_ssl: false
    smtp_port: 587
    smtp_mail_from: "[USER WILL PROVIDE]"
```

---

## Spark Operator Configuration

```yaml
# spark/operator/values.yaml
replicaCount: 1

webhook:
  enable: true
  port: 8080

sparkJobNamespace: spark-jobs

serviceAccounts:
  spark:
    name: spark
    annotations: {}

resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 512Mi
```

### WordCount SparkApplication (ephemeral pattern)

```yaml
# spark/apps/wordcount/wordcount-app.yaml
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: wordcount-[TIMESTAMP]    # Unique name per run — use DAG run_id
  namespace: spark-jobs
spec:
  type: Scala
  mode: cluster
  image: "apache/spark:3.5.0"
  imagePullPolicy: Always
  mainClass: org.apache.spark.examples.JavaWordCount
  mainApplicationFile: "local:///opt/spark/examples/jars/spark-examples_2.12-3.5.0.jar"
  arguments:
    - "local:///opt/spark/examples/jars/spark-examples_2.12-3.5.0.jar"
  sparkVersion: "3.5.0"
  restartPolicy:
    type: Never                  # Ephemeral — never restart, matches GDC pattern
  driver:
    cores: 1
    coreLimit: "1200m"
    memory: "512m"
    serviceAccount: spark
    labels:
      version: 3.5.0
  executor:
    cores: 1
    instances: 2
    memory: "512m"
    labels:
      version: 3.5.0
  monitoring:
    exposeDriverMetrics: true
    exposeExecutorMetrics: true
```

---

## Ollama Configuration

### Key settings
- Model: `gemma2:2b` (CPU-friendly, ~1.6GB, good for PoC)
- Mode: CPU only (no GPU required — keeps GCP cost low)
- Service type: ClusterIP only (internal, mirrors GDC air-gap pattern)
- Temperature: 0.1 (low = deterministic JSON output for RCA)

### ConfigMap

```yaml
# ollama/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ollama-config
  namespace: llm-serving
data:
  DEFAULT_MODEL: "gemma2:2b"
  RCA_MODEL: "gemma2:2b"
  ANOMALY_MODEL: "gemma2:2b"
  OLLAMA_BASE_URL: "http://ollama-service.llm-serving.svc.cluster.local:11434"
  MAX_TOKENS: "512"
  TEMPERATURE: "0.1"
  TIMEOUT_SECONDS: "120"
```

---

## DAG Specifications

### 1. rca_dag.py — Main PoC DAG

```
Purpose: Runs a Spark WordCount job. On failure, triggers Ollama RCA.
Schedule: @daily
Tasks:
  check_ollama_health     → HTTP sensor to verify Ollama is up
  run_spark_wordcount     → SparkKubernetesOperator (ephemeral job)
  record_metrics          → PythonOperator: log duration to dag_metrics table
  [on failure anywhere]   → on_failure_callback: generate_rca()

on_failure_callback steps:
  1. Collect: dag_id, task_id, error message, last 100 log lines, run duration
  2. Build prompt (see RCA Prompt Template)
  3. POST to Ollama API
  4. Parse JSON response
  5. Store RCA in dag_metrics table
  6. Send email with HTML template
  7. Send Slack notification (if configured)
```

### 2. anomaly_detection_dag.py

```
Purpose: Every 30 min, check if any DAG's recent run deviated >20% from baseline.
Schedule: */30 * * * *
Tasks:
  fetch_recent_metrics    → Query dag_metrics for last 10 runs per DAG
  compute_baselines       → Calculate mean ± 2σ per DAG
  detect_anomalies        → Flag runs outside threshold
  explain_anomaly         → If anomaly: ask Ollama to explain what might cause it
  send_alert              → Email + Slack if anomaly detected
```

### 3. wordcount_dag.py

```
Purpose: Simple Spark WordCount DAG. No failure injection. Proves Spark works.
Schedule: None (manual trigger)
Tasks:
  submit_wordcount_job    → SparkKubernetesOperator
  verify_completion       → Check SparkApplication status
  cleanup                 → Delete SparkApplication CR after completion
```

### 4. test_failure_dag.py

```
Purpose: Intentionally fails for demo purposes. Triggers full RCA pipeline.
Schedule: None (manual trigger only)
Tasks:
  pre_failure_task        → Succeeds (shows normal flow)
  intentional_failure     → Raises AirflowException with realistic error message
  post_failure_task       → Never runs
  
The failure triggers on_failure_callback which calls Ollama RCA.
This is the primary demo DAG for manager presentation.
Uses realistic error messages like:
  - FileNotFoundError: /data/sales/2024-01-15.csv not found
  - ConnectionError: Could not connect to Hive metastore at hive:9083
  - OutOfMemoryError: Java heap space in Spark executor
```

---

## RCA Prompt Template

This is critical — the prompt must force structured JSON output.

```python
# dags/utils/rca_prompt.py

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
```

---

## PostgreSQL Schema

```sql
-- storage/postgres/schema.sql

CREATE TABLE IF NOT EXISTS dag_metrics (
    id SERIAL PRIMARY KEY,
    dag_id VARCHAR(250) NOT NULL,
    task_id VARCHAR(250),
    run_id VARCHAR(250) NOT NULL,
    execution_date TIMESTAMP NOT NULL,
    start_date TIMESTAMP,
    end_date TIMESTAMP,
    duration_seconds FLOAT,
    state VARCHAR(50),              -- success | failed | running
    error_message TEXT,
    error_type VARCHAR(250),
    rca_root_cause TEXT,
    rca_category VARCHAR(100),
    rca_confidence FLOAT,
    rca_immediate_fix TEXT,
    rca_prevention TEXT,
    rca_severity VARCHAR(50),
    rca_retry_recommended BOOLEAN,
    rca_generated_at TIMESTAMP,
    rca_model_used VARCHAR(100),
    rca_response_time_seconds FLOAT,
    notification_sent BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_dag_metrics_dag_id ON dag_metrics(dag_id);
CREATE INDEX idx_dag_metrics_execution_date ON dag_metrics(execution_date);
CREATE INDEX idx_dag_metrics_state ON dag_metrics(state);

-- View for anomaly detection
CREATE VIEW dag_baselines AS
SELECT
    dag_id,
    COUNT(*) as total_runs,
    AVG(duration_seconds) as avg_duration,
    STDDEV(duration_seconds) as stddev_duration,
    AVG(duration_seconds) + (2 * STDDEV(duration_seconds)) as upper_threshold,
    AVG(duration_seconds) - (2 * STDDEV(duration_seconds)) as lower_threshold,
    MAX(execution_date) as last_run
FROM dag_metrics
WHERE state = 'success'
  AND execution_date > NOW() - INTERVAL '30 days'
GROUP BY dag_id
HAVING COUNT(*) >= 5;
```

---

## Email Notification Template

The HTML email must include:
- Red header banner for failures, orange for anomalies
- DAG name, task, execution time, duration
- AI-Generated RCA section with root cause, confidence score
- Immediate fix in a highlighted box
- Prevention recommendation
- Severity badge
- Link to Airflow UI
- Footer with timestamp and model used

See `notifications/email/rca_email_template.html` for full implementation.

---

## Slack Notification

Use Slack Block Kit format:
- Header block: "DAG Failure — RCA Generated"
- Section: DAG details
- Section: Root cause (bold)
- Section: Immediate fix
- Context: Severity | Confidence | Fix time estimate
- Button: Link to Airflow UI

---

## Ollama Client (dags/utils/ollama_client.py)

```python
import requests
import json
import time
import logging

log = logging.getLogger(__name__)

OLLAMA_BASE_URL = "http://ollama-service.llm-serving.svc.cluster.local:11434"

def check_ollama_health() -> bool:
    """Health check — used by HttpSensor in DAGs"""
    try:
        resp = requests.get(f"{OLLAMA_BASE_URL}/api/tags", timeout=10)
        return resp.status_code == 200
    except Exception:
        return False

def generate_rca(prompt: str, model: str = "gemma2:2b") -> dict:
    """
    Call Ollama generate endpoint and parse JSON response.
    Returns parsed dict or error dict if LLM fails.
    """
    start = time.time()
    try:
        resp = requests.post(
            f"{OLLAMA_BASE_URL}/api/generate",
            json={
                "model": model,
                "prompt": prompt,
                "format": "json",
                "stream": False,
                "options": {
                    "temperature": 0.1,
                    "num_predict": 512,
                    "top_p": 0.9,
                }
            },
            timeout=120
        )
        resp.raise_for_status()
        raw = resp.json().get("response", "{}")
        result = json.loads(raw)
        result["_response_time_seconds"] = round(time.time() - start, 2)
        result["_model_used"] = model
        return result
    except json.JSONDecodeError as e:
        log.error(f"Ollama returned invalid JSON: {e}")
        return {
            "root_cause": "LLM response parsing failed — check Ollama logs",
            "root_cause_category": "configuration",
            "confidence": 0.0,
            "immediate_fix": "Review Ollama pod logs: kubectl logs -n llm-serving deployment/ollama",
            "severity": "medium",
            "_error": str(e)
        }
    except Exception as e:
        log.error(f"Ollama call failed: {e}")
        return {
            "root_cause": f"Could not reach Ollama service: {str(e)}",
            "root_cause_category": "connectivity",
            "confidence": 0.0,
            "immediate_fix": "Check Ollama pod status and network policy",
            "severity": "medium",
            "_error": str(e)
        }
```

---

## on_failure_callback Implementation

```python
# dags/utils/rca_callback.py
# Include this in every DAG's default_args

def generate_rca_on_failure(context):
    """
    Full RCA pipeline triggered on any task failure.
    Collects context → calls Ollama → stores in DB → sends notifications.
    """
    dag_id = context['dag'].dag_id
    task_id = context['task_instance'].task_id
    run_id = context['run_id']
    execution_date = context['execution_date']
    exception = context.get('exception', 'Unknown error')
    
    # Get logs (last 100 lines)
    try:
        log_content = context['task_instance'].log.handlers[0].stream.getvalue()
        log_excerpt = '\n'.join(log_content.split('\n')[-100:])
    except Exception:
        log_excerpt = str(exception)
    
    # Build prompt
    from utils.rca_prompt import RCA_PROMPT_TEMPLATE
    from utils.ollama_client import generate_rca
    from utils.notifier import send_failure_email, send_slack_alert
    from utils.anomaly_detector import get_dag_history
    
    history = get_dag_history(dag_id)
    
    prompt = RCA_PROMPT_TEMPLATE.format(
        dag_id=dag_id,
        task_id=task_id,
        execution_date=execution_date,
        duration_seconds=context['task_instance'].duration or 0,
        error_type=type(exception).__name__,
        error_message=str(exception)[:500],
        log_excerpt=log_excerpt[:2000],
        total_runs=history.get('total_runs', 0),
        avg_duration=history.get('avg_duration', 0),
        recent_statuses=history.get('recent_statuses', [])
    )
    
    # Call Ollama
    rca = generate_rca(prompt)
    
    # Store in PostgreSQL
    store_rca_in_db(dag_id, task_id, run_id, execution_date, exception, rca)
    
    # Send notifications
    send_failure_email(dag_id, task_id, execution_date, exception, rca)
    send_slack_alert(dag_id, task_id, execution_date, exception, rca)
    
    return rca
```

---

## Demo Script for Manager (demo/DEMO-SCRIPT.md)

Claude must create a polished, step-by-step demo script with:

### Scene 1 — Show the existing platform (2 min)
- Open Airflow UI → show running DAGs
- Show Spark operator → show completed WordCount job
- Show cluster: `kubectl get pods --all-namespaces`

### Scene 2 — Traditional failure (before AI) (2 min)
- Trigger `test_failure_dag.py` WITHOUT RCA enabled
- Show raw error in Airflow UI
- Say: "Without AI, this is all an on-call engineer gets at 3am"

### Scene 3 — AI-powered failure (after AI) (3 min)
- Enable RCA callback
- Trigger `test_failure_dag.py` again
- Show email arriving with:
  - Root cause identified
  - Exact fix steps
  - Confidence score
  - Severity level
- Say: "With AI, the engineer gets this within 30 seconds of the failure"

### Scene 4 — Anomaly detection (2 min)
- Show `anomaly_detection_dag.py` running
- Show baseline metrics in Grafana dashboard
- Show alert triggered when simulated slow run injected

### Scene 5 — The business case (1 min)
- Open README.md which has the ROI numbers
- 90 min → 15 min diagnosis
- 780 hours/year saved
- ~$60 total GCP spend for full PoC

---

## Cost Controls

Important — add these to prevent runaway GCP costs:

```bash
# In create-cluster.sh — set billing alert
gcloud billing budgets create \
  --billing-account=[BILLING_ACCOUNT_ID] \
  --display-name="Ollama PoC Budget" \
  --budget-amount=50USD \
  --threshold-rule=percent=80 \
  --threshold-rule=percent=100

# Use spot/preemptible nodes for non-critical pools
--spot  # Add to all node pool creation commands

# Set cluster auto-shutdown after 8 hours of inactivity
# (remind user to run teardown.sh when done)
```

---

## GCP Resource Sizing (personal project — cost optimized)

| Resource | Machine type | Count | Estimated cost/hr |
|---|---|---|---|
| System node pool | e2-standard-2 | 1 | ~$0.07 |
| Airflow node pool | e2-standard-4 | 1 (spot) | ~$0.05 |
| Spark node pool | e2-standard-4 | 1-2 (spot, autoscale) | ~$0.05-0.10 |
| Ollama node pool | e2-standard-4 | 1 (spot) | ~$0.05 |
| **Total** | | | **~$0.22/hr** |

Full day running = ~$5.30. Well within $300 budget.

---

## README.md Content (manager-facing)

Claude must generate a README that includes:
- Executive summary (2 sentences)
- What was built (architecture diagram in ASCII)
- The 80M rows / 12 min migration achievement (existing work)
- The 4 PoC use cases with before/after metrics
- Business case table (time savings)
- How to run the demo
- GCP cost breakdown
- Next steps for enterprise GDC deployment

---

## Important Constraints

1. **No external API calls from DAGs** — all LLM calls go to `ollama-service.llm-serving.svc.cluster.local:11434` only
2. **Ephemeral Spark** — every SparkApplication must have `restartPolicy.type: Never` and be cleaned up after completion
3. **Helm for Airflow** — must use `apache-airflow/airflow` Helm chart, same pattern as enterprise GDC
4. **KubernetesExecutor** — not LocalExecutor or CeleryExecutor, matches GDC
5. **Spot instances** — use `--spot` on all node pools to minimize cost
6. **Namespaces** — strict namespace separation: airflow / spark-operator / spark-jobs / llm-serving / monitoring
7. **Python package versions** — use `ollama==0.1.8` to match what's in enterprise Artifactory
8. **Port 11434** — Ollama always on this port, ClusterIP only
9. **gemma2:2b** — use this model (CPU friendly, no GPU needed, Google's model = GCP aligned)

---

## Verification Checklist

Claude must verify each of these before declaring the PoC complete:

- [ ] `kubectl get pods --all-namespaces` — all pods Running or Completed
- [ ] Airflow UI accessible via `kubectl port-forward`
- [ ] WordCount SparkApplication completes successfully and pods are deleted
- [ ] `curl` from airflow namespace reaches ollama on port 11434
- [ ] `ollama list` shows gemma2:2b loaded
- [ ] Test inference returns valid JSON
- [ ] test_failure_dag triggers and RCA email is generated
- [ ] RCA stored in PostgreSQL dag_metrics table
- [ ] Anomaly detection DAG runs without error
- [ ] Grafana dashboard shows pipeline metrics
- [ ] teardown.sh cleanly removes all resources

---

## If Something Fails

Common issues and fixes Claude should handle automatically:

| Issue | Fix |
|---|---|
| Spark Operator webhook timeout | Add `--set webhook.enable=false` for initial install |
| Airflow pod OOMKilled | Increase memory limit in values.yaml |
| Ollama model pull timeout | Increase `initialDelaySeconds` in readinessProbe |
| PVC stuck Pending | Check storage class: `kubectl get storageclass` |
| Cross-namespace DNS fails | Verify NetworkPolicy labels match namespace labels |
| Ollama returns non-JSON | Lower temperature to 0.05, add explicit JSON instruction to prompt |
| SparkApplication stuck Pending | Check RBAC: `kubectl describe sparkapplication -n spark-jobs` |

---

## How to Use This File with Claude Code

1. Open Claude Code in the `poc-airflow-spark-ollama/` directory
2. Claude Code will read this CLAUDE.md automatically
3. Provide your GCP details when prompted:
   - Project ID
   - Region/Zone
   - Email address for notifications
   - Slack webhook URL (optional)
   - Billing account ID (for budget alert)
4. Say: "Execute the PoC setup following CLAUDE.md"
5. Claude Code will build everything phase by phase
6. At the end, run `demo/run-demo.sh` to verify everything works
7. Use `demo/DEMO-SCRIPT.md` for the manager presentation

---

*CLAUDE.md version 1.0 — Airflow + Spark + Ollama RCA PoC*
*Architecture mirrors enterprise GDC deployment pattern*
*Target: Personal GCP project, $300 credit budget, complete in 1 day*
