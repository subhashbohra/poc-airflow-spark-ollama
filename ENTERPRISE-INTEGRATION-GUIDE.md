# Enterprise Integration Guide — AI-Powered RCA for Existing Airflow + Spark

> This guide assumes you already have Airflow and Spark Operator running in your
> enterprise GDC/GKE cluster. Follow these steps to add Ollama LLM-based RCA
> to your existing pipelines with minimal disruption.

---

## What You Are Adding

```
Your Existing Setup          What Gets Added
─────────────────            ──────────────────────────────────
Airflow (running)     +      Ollama LLM (new deployment)
Spark Operator        +      ollama_client.py (utility)
Your DAGs             +      rca_callback.py (on_failure_callback)
                      +      dag_metrics table (PostgreSQL)
                      +      Email + Slack RCA notifications
```

No changes to your existing DAG logic. You only **add** the callback.

---

## Prerequisites Checklist

Before starting, confirm the following:

- [ ] kubectl access to the enterprise cluster
- [ ] Helm access (v3+)
- [ ] Airflow namespace name (note it down)
- [ ] Airflow DAGs folder path (e.g. `/opt/airflow/dags`)
- [ ] Existing PostgreSQL or ability to deploy one
- [ ] Internal container registry URL (for Ollama image)
- [ ] SMTP credentials for email notifications
- [ ] Slack webhook URL (optional)
- [ ] Pip package install method (git-sync, custom image, or Artifactory)

---

## Step 1 — Deploy Ollama in the Cluster

### 1.1 Create the llm-serving namespace

```bash
kubectl create namespace llm-serving
kubectl label namespace llm-serving name=llm-serving
```

### 1.2 Create PVC for model storage

```yaml
# ollama-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models-pvc
  namespace: llm-serving
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 30Gi
  storageClassName: standard-rwo   # change to your storage class
```

```bash
kubectl apply -f ollama-pvc.yaml

# Check your available storage classes if unsure:
kubectl get storageclass
```

### 1.3 Deploy Ollama

```yaml
# ollama-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: llm-serving
  labels:
    app: ollama
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      containers:
        - name: ollama
          image: ollama/ollama:latest
          # If your cluster has no internet, push this image to your
          # internal registry first:
          # image: your-registry.internal/ollama/ollama:latest
          ports:
            - containerPort: 11434
          env:
            - name: OLLAMA_HOST
              value: "0.0.0.0"
            - name: OLLAMA_MODELS
              value: "/models"
          resources:
            requests:
              memory: "3Gi"
              cpu: "1000m"
            limits:
              memory: "6Gi"
              cpu: "3000m"
          volumeMounts:
            - name: models-storage
              mountPath: /models
          readinessProbe:
            httpGet:
              path: /api/tags
              port: 11434
            initialDelaySeconds: 30
            periodSeconds: 15
            failureThreshold: 20
      volumes:
        - name: models-storage
          persistentVolumeClaim:
            claimName: ollama-models-pvc
```

```bash
kubectl apply -f ollama-deployment.yaml
```

### 1.4 Create ClusterIP Service (internal only — no external traffic)

```yaml
# ollama-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: ollama-service
  namespace: llm-serving
spec:
  type: ClusterIP
  selector:
    app: ollama
  ports:
    - port: 11434
      targetPort: 11434
```

```bash
kubectl apply -f ollama-service.yaml
```

### 1.5 Apply Network Policy (allow only Airflow namespace)

Replace `your-airflow-namespace` with your actual Airflow namespace name.

```yaml
# ollama-network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-airflow-to-ollama
  namespace: llm-serving
spec:
  podSelector:
    matchLabels:
      app: ollama
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: your-airflow-namespace
      ports:
        - protocol: TCP
          port: 11434
```

```bash
# Label your Airflow namespace (required for network policy)
kubectl label namespace your-airflow-namespace name=your-airflow-namespace

kubectl apply -f ollama-network-policy.yaml
```

### 1.6 Wait for Ollama to be Ready

```bash
kubectl rollout status deployment/ollama -n llm-serving --timeout=5m
kubectl get pods -n llm-serving
```

### 1.7 Pull the gemma2:2b Model

```bash
OLLAMA_POD=$(kubectl get pods -n llm-serving -l app=ollama \
  -o jsonpath='{.items[0].metadata.name}')

# Pull model (takes 5-10 min on first run, ~1.6GB)
kubectl exec -n llm-serving $OLLAMA_POD -- ollama pull gemma2:2b

# Verify it loaded
kubectl exec -n llm-serving $OLLAMA_POD -- ollama list
```

### 1.8 Test Inference

```bash
OLLAMA_POD=$(kubectl get pods -n llm-serving -l app=ollama \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n llm-serving $OLLAMA_POD -- \
  curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"gemma2:2b\",\"prompt\":\"Reply only with valid JSON: {status ok}\",\"format\":\"json\",\"stream\":false}"
```

Expected: JSON response with status ok in the response field.

---

## Step 2 — Create the dag_metrics PostgreSQL Table

### Option A — Use your existing PostgreSQL

```bash
psql -h your-postgres-host -U your-user -d your-database -f storage/postgres/schema.sql
```

### Option B — Deploy a dedicated PostgreSQL

```bash
kubectl apply -f storage/postgres/deployment.yaml
kubectl apply -f storage/postgres/service.yaml

kubectl wait --for=condition=ready pod -l app=postgres-metrics \
  -n monitoring --timeout=180s

PG_POD=$(kubectl get pods -n monitoring -l app=postgres-metrics \
  -o jsonpath='{.items[0].metadata.name}')
kubectl cp storage/postgres/schema.sql monitoring/$PG_POD:/tmp/schema.sql
kubectl exec -n monitoring $PG_POD -- \
  psql -U metrics_user -d metrics -f /tmp/schema.sql
```

---

## Step 3 — Add Utility Files to Your DAGs Folder

Copy these files into your Airflow DAGs folder under a `utils/` subdirectory:

```
your-airflow-dags-folder/
└── utils/
    ├── __init__.py          <- empty file, required for Python import
    ├── ollama_client.py     <- Ollama API caller
    ├── rca_prompt.py        <- Prompt templates
    ├── rca_callback.py      <- on_failure_callback function
    └── notifier.py          <- Email + Slack senders
```

### Copy files to Airflow scheduler pod

```bash
AIRFLOW_NS="your-airflow-namespace"
SCHEDULER_POD=$(kubectl get pods -n $AIRFLOW_NS -l component=scheduler \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n $AIRFLOW_NS $SCHEDULER_POD -- \
  mkdir -p /opt/airflow/dags/utils

for f in ollama_client.py rca_prompt.py rca_callback.py notifier.py; do
  kubectl cp dags/utils/$f $AIRFLOW_NS/$SCHEDULER_POD:/opt/airflow/dags/utils/$f
  echo "Copied: $f"
done

kubectl exec -n $AIRFLOW_NS $SCHEDULER_POD -- \
  touch /opt/airflow/dags/utils/__init__.py
```

> **If you use git-sync:** Add the utils/ folder to your DAGs git repo and push.

### Required Python packages

Add to your Airflow pip requirements:

```
requests==2.31.0
psycopg2-binary==2.9.9
apache-airflow-providers-smtp==1.6.0
apache-airflow-providers-slack==8.0.0
```

---

## Step 4 — Set Environment Variables in Airflow

Add to your existing Airflow Helm values.yaml under extraEnv:

```yaml
extraEnv: |
  - name: OLLAMA_BASE_URL
    value: "http://ollama-service.llm-serving.svc.cluster.local:11434"
  - name: METRICS_DB_HOST
    value: "your-postgres-host"
  - name: METRICS_DB_PORT
    value: "5432"
  - name: METRICS_DB_NAME
    value: "your-database"
  - name: METRICS_DB_USER
    value: "your-user"
  - name: METRICS_DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-secret
        key: password
  - name: SMTP_MAIL_FROM
    value: "your-email@company.com"
  - name: ALERT_EMAIL
    value: "your-team@company.com"
  - name: AIRFLOW_UI_URL
    value: "http://your-airflow-webserver-url"
```

Apply the updated Helm values:

```bash
helm upgrade airflow apache-airflow/airflow \
  --namespace your-airflow-namespace \
  --reuse-values \
  --values your-updated-values.yaml
```

---

## Step 5 — Configure Airflow SMTP Connection

```bash
AIRFLOW_NS="your-airflow-namespace"
SCHEDULER_POD=$(kubectl get pods -n $AIRFLOW_NS -l component=scheduler \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n $AIRFLOW_NS $SCHEDULER_POD -- \
  airflow connections add smtp_default \
  --conn-type smtp \
  --conn-host smtp.gmail.com \
  --conn-login your-email@company.com \
  --conn-password your-app-password \
  --conn-port 587

kubectl exec -n $AIRFLOW_NS $SCHEDULER_POD -- \
  airflow connections get smtp_default
```

---

## Step 6 — Update Your Existing DAGs (Minimal Change — 3 Lines Only)

This is the only change needed in your existing DAGs.

### Before (your existing DAG)

```python
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator

default_args = {
    "owner": "data-engineering",
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="your_existing_dag",
    default_args=default_args,
    schedule_interval="@daily",
) as dag:
    # your existing tasks unchanged
    pass
```

### After (add 3 lines — nothing else changes)

```python
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator

# ADD THESE 3 LINES
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "utils"))
from rca_callback import generate_rca_on_failure

default_args = {
    "owner": "data-engineering",
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "on_failure_callback": generate_rca_on_failure,   # ADD THIS
}

with DAG(
    dag_id="your_existing_dag",
    default_args=default_args,
    schedule_interval="@daily",
) as dag:
    # your existing tasks — NO CHANGES NEEDED
    pass
```

When any task fails, automatically:
1. Collects logs + error context
2. Calls Ollama API (internal ClusterIP — no internet)
3. Stores RCA in dag_metrics table
4. Sends email + Slack with full analysis within 30-60 seconds

---

## Step 7 — Create a Test DAG to Validate End-to-End

Before touching production DAGs, deploy this test DAG:

```python
# test_rca_validation.py
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "utils"))

from datetime import datetime
from airflow import DAG
from airflow.operators.python import PythonOperator
from rca_callback import generate_rca_on_failure

with DAG(
    dag_id="test_rca_validation",
    default_args={
        "owner": "data-engineering",
        "on_failure_callback": generate_rca_on_failure,
    },
    schedule_interval=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["test", "rca", "validation"],
) as dag:

    def succeed(**ctx):
        print("Pre-task running successfully...")

    def fail(**ctx):
        raise ConnectionError(
            "Could not connect to Hive metastore at hive:9083 after 3 retries."
        )

    t1 = PythonOperator(task_id="pre_task", python_callable=succeed)
    t2 = PythonOperator(task_id="failing_task", python_callable=fail)
    t1 >> t2
```

Trigger and check email:

```bash
AIRFLOW_NS="your-airflow-namespace"
SCHEDULER_POD=$(kubectl get pods -n $AIRFLOW_NS -l component=scheduler \
  -o jsonpath='{.items[0].metadata.name}')

kubectl cp test_rca_validation.py \
  $AIRFLOW_NS/$SCHEDULER_POD:/opt/airflow/dags/test_rca_validation.py

kubectl exec -n $AIRFLOW_NS $SCHEDULER_POD -- \
  airflow dags trigger test_rca_validation
```

Within 60 seconds you should receive an email with full RCA.

---

## Step 8 — Rollout to Production DAGs

```bash
# Find all DAGs missing the RCA callback
grep -rL "generate_rca_on_failure" /opt/airflow/dags/*.py
```

Recommended rollout order:

| Week | Scope |
|---|---|
| Week 1 | 1-2 non-critical DAGs — monitor for issues |
| Week 2 | All Spark DAGs |
| Week 3 | All production DAGs |

---

## Verification Checklist

```bash
# 1. Ollama pod running
kubectl get pods -n llm-serving

# 2. gemma2:2b model loaded
OLLAMA_POD=$(kubectl get pods -n llm-serving -l app=ollama \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n llm-serving $OLLAMA_POD -- ollama list

# 3. Airflow can reach Ollama
AIRFLOW_NS="your-airflow-namespace"
SCHEDULER=$(kubectl get pods -n $AIRFLOW_NS -l component=scheduler \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n $AIRFLOW_NS $SCHEDULER -- \
  curl -s http://ollama-service.llm-serving.svc.cluster.local:11434/api/tags

# 4. dag_metrics table exists
psql -h your-postgres-host -U your-user -d your-db \
  -c "SELECT COUNT(*) FROM dag_metrics;"

# 5. Trigger test DAG and check email arrives within 60s
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `curl: could not resolve host ollama-service` | Network policy label mismatch | `kubectl label namespace your-airflow-ns name=your-airflow-ns` |
| `Connection refused` on port 11434 | Ollama pod not ready | `kubectl rollout status deployment/ollama -n llm-serving` |
| `ModuleNotFoundError: utils` | utils/ not in DAGs path | Verify `sys.path.insert` line and `__init__.py` exists |
| `json.JSONDecodeError` from Ollama | LLM returning non-JSON | Temperature is 0.1 — retry usually fixes it |
| Email not sending | SMTP connection not set up | Re-run Step 5 |
| `psycopg2.OperationalError` | Wrong DB credentials | Verify `METRICS_DB_*` env vars in Airflow pods |
| Ollama pull times out | Large model download | Increase pod `initialDelaySeconds` to 120 |
| Model not found | gemma2:2b not pulled | `kubectl exec -n llm-serving $POD -- ollama pull gemma2:2b` |

---

## Architecture After Integration

```
Your Enterprise GDC Cluster
|
|-- namespace: your-airflow-namespace  (existing — minor env var additions)
|   |-- Airflow Webserver
|   |-- Airflow Scheduler
|   |-- Airflow Workers
|   +-- DAGs with on_failure_callback  (add 3 lines per DAG)
|
|-- namespace: spark-operator          (existing — no changes)
|-- namespace: spark-jobs              (existing — no changes)
|
|-- namespace: llm-serving             <-- NEW
|   |-- Ollama Deployment (gemma2:2b, CPU only)
|   |-- ClusterIP Service :11434
|   +-- PVC 30GB (model storage)
|
+-- dag_metrics table                  <-- NEW (PostgreSQL)
```

---

## Key Points for Enterprise Review

1. **No external API calls** — Ollama runs entirely inside the cluster
2. **No GPU required** — gemma2:2b runs on CPU (2-4 vCPU sufficient)
3. **No task logic changes** — only default_args gets one new line
4. **Backward compatible** — if Ollama is down, callback logs a warning but does not block task retry
5. **Air-gap friendly** — pull image and model once into PVC; no internet needed after
6. **Follows GDC namespace pattern** — same separation as existing namespaces

---

*Guide version 1.0 — Airflow + Spark + Ollama RCA Enterprise Integration*
*Based on PoC: github.com/subhashbohra/poc-airflow-spark-ollama*
