#!/usr/bin/env bash
# =============================================================================
# setup-connections.sh — Configure Airflow connections via CLI
# Run after Airflow is fully installed and pods are Ready
# =============================================================================
set -euo pipefail

NAMESPACE="airflow"
RELEASE_NAME="airflow"
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-subhashbohra003@gmail.com}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

echo "============================================="
echo " Airflow Connections Setup"
echo "============================================="

# Get scheduler pod name
SCHEDULER_POD=$(kubectl get pods -n "$NAMESPACE" -l component=scheduler \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$SCHEDULER_POD" ]; then
  echo "❌ Could not find Airflow scheduler pod. Is Airflow installed?"
  exit 1
fi

echo "Using scheduler pod: $SCHEDULER_POD"
echo ""

# Helper to run airflow CLI in scheduler pod
airflow_cli() {
  kubectl exec -n "$NAMESPACE" "$SCHEDULER_POD" -- airflow "$@"
}

# SMTP connection for email notifications
if [ -n "$SMTP_PASSWORD" ]; then
  echo "[1/4] Setting up SMTP email connection..."
  airflow_cli connections delete 'smtp_default' 2>/dev/null || true
  airflow_cli connections add 'smtp_default' \
    --conn-type 'email' \
    --conn-host "$SMTP_HOST" \
    --conn-port "$SMTP_PORT" \
    --conn-login "$SMTP_USER" \
    --conn-password "$SMTP_PASSWORD" \
    --conn-extra '{"use_tls": true}'
  echo "  ✅ SMTP connection configured"
else
  echo "[1/4] Skipping SMTP (SMTP_PASSWORD not set)"
fi

# Slack connection (if webhook provided)
if [ -n "$SLACK_WEBHOOK_URL" ]; then
  echo "[2/4] Setting up Slack connection..."
  airflow_cli connections delete 'slack_default' 2>/dev/null || true
  airflow_cli connections add 'slack_default' \
    --conn-type 'slack_incoming_webhook' \
    --conn-password "$SLACK_WEBHOOK_URL"
  echo "  ✅ Slack connection configured"
else
  echo "[2/4] Skipping Slack (SLACK_WEBHOOK_URL not set)"
fi

# PostgreSQL metrics connection
echo "[3/4] Setting up PostgreSQL metrics connection..."
airflow_cli connections delete 'postgres_metrics' 2>/dev/null || true
airflow_cli connections add 'postgres_metrics' \
  --conn-type 'postgres' \
  --conn-host 'postgres-metrics-svc.monitoring.svc.cluster.local' \
  --conn-port '5432' \
  --conn-schema 'metrics' \
  --conn-login 'metrics_user' \
  --conn-password 'metrics_poc_password_2024'
echo "  ✅ PostgreSQL metrics connection configured"

# Kubernetes connection (for SparkKubernetesOperator)
echo "[4/4] Setting up Kubernetes connection..."
airflow_cli connections delete 'kubernetes_default' 2>/dev/null || true
airflow_cli connections add 'kubernetes_default' \
  --conn-type 'kubernetes' \
  --conn-extra '{"in_cluster": true}'
echo "  ✅ Kubernetes connection configured"

echo ""
echo "Configured connections:"
airflow_cli connections list

echo ""
echo "✅ All connections configured!"
