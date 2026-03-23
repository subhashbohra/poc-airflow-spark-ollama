#!/usr/bin/env bash
# =============================================================================
# setup.sh — One-shot setup script for Airflow + Spark + Ollama PoC
#
# Usage:
#   PROJECT_ID=ollama-491104 \
#   EMAIL=subhashbohra003@gmail.com \
#   SMTP_PASSWORD=your_gmail_app_password \
#   bash setup.sh
#
# Optional:
#   SLACK_WEBHOOK_URL=https://hooks.slack.com/... \
#   BILLING_ACCOUNT=01XXXX-XXXXXX-XXXXXX \
#   bash setup.sh
# =============================================================================
set -euo pipefail

# =========================================================
# Configuration — set defaults, allow env override
# =========================================================
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
echo " Slack:    ${SLACK_WEBHOOK_URL:+(configured)}"
echo "============================================================"
echo ""

if [ -z "$SMTP_PASSWORD" ]; then
  echo "⚠️  SMTP_PASSWORD not set. Email notifications will not work."
  echo "   Set it with: export SMTP_PASSWORD=your_gmail_app_password"
  echo "   (Use a Gmail App Password, not your account password)"
  echo ""
fi

# =========================================================
# Phase 1 — GKE Cluster
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 1 — GKE Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/infra/gke/create-cluster.sh"

echo ""
echo "Applying namespaces..."
kubectl apply -f "$SCRIPT_DIR/infra/namespaces/namespaces.yaml"

echo "Applying network policies..."
kubectl apply -f "$SCRIPT_DIR/infra/network-policies/network-policies.yaml"

echo "Verifying cluster health..."
kubectl get nodes
echo ""

# =========================================================
# Phase 2 — Spark Operator
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 2 — Spark Operator"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/spark/operator/install.sh"

echo "Running WordCount smoke test..."
bash "$SCRIPT_DIR/spark/apps/wordcount/wordcount-trigger.sh" || \
  echo "⚠️  WordCount test failed — check Spark operator logs before continuing"
echo ""

# =========================================================
# Phase 3 — Ollama LLM Service
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 3 — Ollama LLM Service"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl apply -f "$SCRIPT_DIR/ollama/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/ollama/pvc.yaml"
kubectl apply -f "$SCRIPT_DIR/ollama/configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/ollama/deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/ollama/service.yaml"
kubectl apply -f "$SCRIPT_DIR/ollama/network-policy.yaml"

echo "Waiting for Ollama pod to be Ready (may take 2-3 min)..."
kubectl wait --for=condition=ready pod -l app=ollama -n llm-serving --timeout=300s

echo "Pulling gemma2:2b model (5-10 min first run)..."
bash "$SCRIPT_DIR/ollama/model-loader/load-models.sh"
echo ""

# =========================================================
# Phase 4 — PostgreSQL for Metrics
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 4 — PostgreSQL Metrics Database"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl apply -f "$SCRIPT_DIR/storage/postgres/deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/storage/postgres/service.yaml"

echo "Waiting for PostgreSQL to be Ready..."
kubectl wait --for=condition=ready pod -l app=postgres-metrics -n monitoring --timeout=180s

echo "Creating schema..."
PG_POD=$(kubectl get pods -n monitoring -l app=postgres-metrics -o jsonpath='{.items[0].metadata.name}')
kubectl cp "$SCRIPT_DIR/storage/postgres/schema.sql" "monitoring/$PG_POD:/tmp/schema.sql"
kubectl exec -n monitoring "$PG_POD" -- \
  psql -U metrics_user -d metrics -f /tmp/schema.sql
echo ""

# =========================================================
# Phase 5 — Airflow
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 5 — Airflow (Helm)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SMTP_PASSWORD="$SMTP_PASSWORD" \
SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL" \
EMAIL="$EMAIL" \
bash "$SCRIPT_DIR/airflow/helm/install.sh"

echo "Setting up Airflow connections..."
SMTP_PASSWORD="$SMTP_PASSWORD" \
SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL" \
bash "$SCRIPT_DIR/airflow/connections/setup-connections.sh"
echo ""

# =========================================================
# Phase 6 — Deploy DAGs
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 6 — DAGs Deployment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get the DAGs PVC and copy files
echo "Copying DAG files to Airflow..."
AIRFLOW_SCHEDULER=$(kubectl get pods -n airflow -l component=scheduler \
  -o jsonpath='{.items[0].metadata.name}')

for dag_file in "$SCRIPT_DIR/dags/"*.py; do
  fname=$(basename "$dag_file")
  kubectl cp "$dag_file" "airflow/$AIRFLOW_SCHEDULER:/opt/airflow/dags/$fname"
  echo "  Copied: $fname"
done

mkdir -p /tmp/airflow-utils
for util_file in "$SCRIPT_DIR/dags/utils/"*.py; do
  fname=$(basename "$util_file")
  kubectl cp "$util_file" "airflow/$AIRFLOW_SCHEDULER:/opt/airflow/dags/utils/$fname"
  echo "  Copied: utils/$fname"
done

# Create __init__.py for utils package
kubectl exec -n airflow "$AIRFLOW_SCHEDULER" -- \
  touch /opt/airflow/dags/utils/__init__.py

# Unpause all DAGs
echo ""
echo "Unpausing DAGs..."
for dag in rca_dag wordcount_dag anomaly_detection_dag test_failure_dag; do
  kubectl exec -n airflow "$AIRFLOW_SCHEDULER" -- airflow dags unpause "$dag" 2>/dev/null || true
  echo "  Unpaused: $dag"
done
echo ""

# =========================================================
# Phase 7 — Monitoring
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 7 — Monitoring (Prometheus + Grafana)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/monitoring/grafana/install.sh"
echo ""

# =========================================================
# Final Verification
# =========================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " VERIFICATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/demo/run-demo.sh"

echo ""
echo "============================================================"
echo " ✅ PoC Setup Complete!"
echo "============================================================"
echo ""
echo "Access the services:"
echo ""
echo "  Airflow UI:"
echo "    kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow"
echo "    http://localhost:8080  (admin / admin)"
echo ""
echo "  Grafana:"
echo "    kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
echo "    http://localhost:3000  (admin / poc-grafana-admin)"
echo ""
echo "  Run demo:     bash demo/run-demo.sh"
echo "  Inject fail:  bash demo/inject-failure.sh 2"
echo "  Teardown:     bash teardown.sh"
echo ""
echo "  Demo guide:   demo/DEMO-SCRIPT.md"
echo "============================================================"
