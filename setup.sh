#!/usr/bin/env bash
# =============================================================================
# setup.sh — One-shot setup for Airflow + Spark + Ollama RCA PoC
#
# Usage:
#   PROJECT_ID=ollama-491104 \
#   EMAIL=subhashbohra003@gmail.com \
#   SMTP_PASSWORD=your_gmail_app_password \
#   bash setup.sh
# =============================================================================
set -euo pipefail

export PROJECT_ID="${PROJECT_ID:-ollama-491104}"
export REGION="${REGION:-us-central1}"
export ZONE="${ZONE:-us-central1-a}"
export CLUSTER_NAME="${CLUSTER_NAME:-poc-cluster}"
export EMAIL="${EMAIL:-subhashbohra003@gmail.com}"
export SMTP_PASSWORD="${SMTP_PASSWORD:-}"
export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
export BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo " Airflow + Spark + Ollama RCA PoC — Full Setup"
echo "============================================================"
echo " Project:  $PROJECT_ID"
echo " Region:   $REGION / $ZONE"
echo " Cluster:  $CLUSTER_NAME"
echo " Email:    $EMAIL"
echo "============================================================"
echo ""

if [ -z "$SMTP_PASSWORD" ]; then
  echo "⚠️  SMTP_PASSWORD not set. Email notifications will not work."
  echo ""
fi

# =========================================================
# Phase 1 — GKE Cluster
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 1 — GKE Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/infra/gke/create-cluster.sh"

kubectl apply -f "$SCRIPT_DIR/infra/namespaces/namespaces.yaml"
kubectl apply -f "$SCRIPT_DIR/infra/network-policies/network-policies.yaml"

# Auto-detect the available storage class
STORAGE_CLASS=$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "standard")
echo "Detected storage class: $STORAGE_CLASS"
export STORAGE_CLASS

kubectl get nodes
echo ""

# =========================================================
# Phase 2 — Spark Operator
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 2 — Spark Operator"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
helm repo add spark-operator https://kubeflow.github.io/spark-operator 2>/dev/null || true
helm repo update

# webhook.enable=false avoids context deadline exceeded on first install
helm upgrade --install spark-operator spark-operator/spark-operator \
  --namespace spark-operator \
  --create-namespace \
  --set webhook.enable=false \
  --set sparkJobNamespace=spark-jobs \
  --wait \
  --timeout 5m

kubectl apply -f "$SCRIPT_DIR/spark/rbac/spark-rbac.yaml"
kubectl rollout status deployment/spark-operator -n spark-operator --timeout=3m
echo "✅ Spark Operator ready"
echo ""

# =========================================================
# Phase 3 — Ollama LLM Service
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 3 — Ollama LLM Service"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl apply -f "$SCRIPT_DIR/ollama/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/ollama/configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/ollama/service.yaml"
kubectl apply -f "$SCRIPT_DIR/ollama/network-policy.yaml"

# Deploy Ollama with emptyDir (no PVC storage class issues)
kubectl apply -f - <<EOF
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
      tolerations:
        - key: "pool"
          operator: "Equal"
          value: "ollama"
          effect: "NoSchedule"
      nodeSelector:
        pool: ollama
      containers:
        - name: ollama
          image: ollama/ollama:latest
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
          livenessProbe:
            httpGet:
              path: /api/tags
              port: 11434
            initialDelaySeconds: 60
            periodSeconds: 30
            failureThreshold: 5
      volumes:
        - name: models-storage
          emptyDir: {}
EOF

echo "Waiting for Ollama pod to be Ready (2-3 min)..."
kubectl wait --for=condition=ready pod -l app=ollama -n llm-serving --timeout=300s

echo "Pulling gemma2:2b model (5-10 min first run)..."
OLLAMA_POD=$(kubectl get pods -n llm-serving -l app=ollama -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n llm-serving "$OLLAMA_POD" -- ollama pull gemma2:2b
kubectl exec -n llm-serving "$OLLAMA_POD" -- ollama list
echo "✅ Ollama ready with gemma2:2b"
echo ""

# =========================================================
# Phase 4 — PostgreSQL for Metrics
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 4 — PostgreSQL Metrics Database"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Deploy PostgreSQL with emptyDir — no PVC needed for PoC
kubectl apply -f "$SCRIPT_DIR/storage/postgres/deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/storage/postgres/service.yaml"

echo "Waiting for PostgreSQL..."
kubectl wait --for=condition=ready pod -l app=postgres-metrics -n monitoring --timeout=120s

PG_POD=$(kubectl get pods -n monitoring -l app=postgres-metrics -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n monitoring "$PG_POD" -- psql -U metrics_user -d metrics -c "
CREATE TABLE IF NOT EXISTS dag_metrics (
    id SERIAL PRIMARY KEY,
    dag_id VARCHAR(250) NOT NULL,
    task_id VARCHAR(250),
    run_id VARCHAR(250) NOT NULL,
    execution_date TIMESTAMP NOT NULL,
    start_date TIMESTAMP,
    end_date TIMESTAMP,
    duration_seconds FLOAT,
    state VARCHAR(50),
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
);"

kubectl exec -n monitoring "$PG_POD" -- psql -U metrics_user -d metrics -c \
  "CREATE INDEX IF NOT EXISTS idx_dag_metrics_dag_id ON dag_metrics(dag_id);"
kubectl exec -n monitoring "$PG_POD" -- psql -U metrics_user -d metrics -c \
  "CREATE INDEX IF NOT EXISTS idx_dag_metrics_state ON dag_metrics(state);"

echo "✅ PostgreSQL schema applied"
echo ""

# =========================================================
# Phase 5 — Airflow (Helm)
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 5 — Airflow (Helm)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
helm repo add apache-airflow https://airflow.apache.org 2>/dev/null || true
helm repo update

FERNET_KEY=$(openssl rand -base64 32)
WEBSERVER_SECRET=$(openssl rand -hex 32)

# Create SMTP secret before install
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic airflow-smtp-secret \
  --namespace airflow \
  --from-literal=smtp_password="${SMTP_PASSWORD}" \
  --from-literal=smtp_user="${EMAIL}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Installing Airflow (10-15 min)..."
# All persistence disabled — uses emptyDir, avoids ALL PVC/storageclass issues
helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  --create-namespace \
  --set airflowVersion=2.11.0 \
  --set defaultAirflowTag=2.11.0 \
  --set executor=KubernetesExecutor \
  --set fernetKey="$FERNET_KEY" \
  --set webserverSecretKey="$WEBSERVER_SECRET" \
  --set dags.persistence.enabled=false \
  --set logs.persistence.enabled=false \
  --set triggerer.persistence.enabled=false \
  --set postgresql.primary.persistence.enabled=false \
  --set postgresql.auth.postgresPassword=airflow123 \
  --set postgresql.auth.password=airflow123 \
  --set postgresql.auth.username=airflow \
  --set postgresql.auth.database=airflow \
  --set "config.smtp.smtp_host=smtp.gmail.com" \
  --set "config.smtp.smtp_starttls=True" \
  --set "config.smtp.smtp_ssl=False" \
  --set "config.smtp.smtp_port=587" \
  --set "config.smtp.smtp_mail_from=${EMAIL}" \
  --set "config.core.load_examples=False" \
  --set "extraEnv[0].name=OLLAMA_BASE_URL" \
  --set "extraEnv[0].value=http://ollama-service.llm-serving.svc.cluster.local:11434" \
  --set "extraEnv[1].name=METRICS_DB_HOST" \
  --set "extraEnv[1].value=metrics-postgres.monitoring.svc.cluster.local" \
  --set "extraEnv[2].name=METRICS_DB_PORT" \
  --set "extraEnv[2].value=5432" \
  --set "extraEnv[3].name=METRICS_DB_NAME" \
  --set "extraEnv[3].value=metrics" \
  --set "extraEnv[4].name=METRICS_DB_USER" \
  --set "extraEnv[4].value=metrics_user" \
  --set "extraEnv[5].name=METRICS_DB_PASSWORD" \
  --set "extraEnv[5].value=metrics_poc_password_2024" \
  --set "extraEnv[6].name=ALERT_EMAIL" \
  --set "extraEnv[6].value=${EMAIL}" \
  --set "extraEnv[7].name=SMTP_PASSWORD" \
  --set "extraEnv[7].value=${SMTP_PASSWORD}" \
  --set "_pip_extra_requirements=requests==2.31.0 psycopg2-binary==2.9.9 apache-airflow-providers-smtp apache-airflow-providers-slack apache-airflow-providers-cncf-kubernetes" \
  --timeout 15m \
  --wait

echo "✅ Airflow installed"
kubectl get pods -n airflow
echo ""

# =========================================================
# Phase 6 — Deploy DAGs
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 6 — Deploy DAGs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
AIRFLOW_SCHEDULER=$(kubectl get pods -n airflow -l component=scheduler \
  -o jsonpath='{.items[0].metadata.name}')
echo "Scheduler: $AIRFLOW_SCHEDULER"

kubectl exec -n airflow "$AIRFLOW_SCHEDULER" -- mkdir -p /opt/airflow/dags/utils

for dag_file in "$SCRIPT_DIR/dags/"*.py; do
  fname=$(basename "$dag_file")
  kubectl cp "$dag_file" "airflow/$AIRFLOW_SCHEDULER:/opt/airflow/dags/$fname"
  echo "  Copied: $fname"
done

for util_file in "$SCRIPT_DIR/dags/utils/"*.py; do
  fname=$(basename "$util_file")
  kubectl cp "$util_file" "airflow/$AIRFLOW_SCHEDULER:/opt/airflow/dags/utils/$fname"
  echo "  Copied: utils/$fname"
done

kubectl exec -n airflow "$AIRFLOW_SCHEDULER" -- touch /opt/airflow/dags/utils/__init__.py

# Setup SMTP connection
kubectl exec -n airflow "$AIRFLOW_SCHEDULER" -- \
  airflow connections add smtp_default \
  --conn-type smtp \
  --conn-host smtp.gmail.com \
  --conn-login "$EMAIL" \
  --conn-password "$SMTP_PASSWORD" \
  --conn-port 587 2>/dev/null || \
kubectl exec -n airflow "$AIRFLOW_SCHEDULER" -- \
  airflow connections delete smtp_default && \
kubectl exec -n airflow "$AIRFLOW_SCHEDULER" -- \
  airflow connections add smtp_default \
  --conn-type smtp \
  --conn-host smtp.gmail.com \
  --conn-login "$EMAIL" \
  --conn-password "$SMTP_PASSWORD" \
  --conn-port 587

echo "Unpausing DAGs..."
for dag in rca_dag wordcount_dag anomaly_detection_dag test_failure_dag; do
  kubectl exec -n airflow "$AIRFLOW_SCHEDULER" -- \
    airflow dags unpause "$dag" 2>/dev/null || true
  echo "  Unpaused: $dag"
done
echo "✅ DAGs deployed"
echo ""

# =========================================================
# Phase 7 — Monitoring
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 7 — Monitoring (Prometheus + Grafana)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.storageSpec=null \
  --set alertmanager.enabled=false \
  --set grafana.adminPassword=admin \
  --set grafana.persistence.enabled=false \
  --wait \
  --timeout 10m

echo "✅ Monitoring installed"
echo ""

# =========================================================
# Final
# =========================================================
echo "============================================================"
echo " ✅ PoC Setup Complete!"
echo "============================================================"
echo ""
echo "  Airflow UI:"
echo "    kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow"
echo "    http://localhost:8080  (admin / admin)"
echo ""
echo "  Grafana:"
echo "    kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring"
echo "    http://localhost:3000  (admin / admin)"
echo ""
echo "  Trigger demo failure + RCA:"
echo "    bash demo/inject-failure.sh"
echo ""
echo "  Teardown when done:"
echo "    bash teardown.sh"
echo "============================================================"
