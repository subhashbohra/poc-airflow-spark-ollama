#!/usr/bin/env bash
# =============================================================================
# install.sh — Airflow Helm Install (Phase 5)
# Mirrors GDC enterprise Helm deployment pattern
# =============================================================================
set -euo pipefail

NAMESPACE="airflow"
RELEASE_NAME="airflow"
CHART_VERSION="1.14.0"   # Helm chart version for Airflow 2.9.2
EMAIL="${EMAIL:-subhashbohra003@gmail.com}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

echo "============================================="
echo " Airflow Helm Installation"
echo " Namespace:  $NAMESPACE"
echo " Chart:      apache-airflow/airflow v$CHART_VERSION"
echo "============================================="

# Add Airflow Helm repo
echo "[1/8] Adding Apache Airflow Helm repo..."
helm repo add apache-airflow https://airflow.apache.org
helm repo update

# Create namespace
echo "[2/8] Creating airflow namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" name=airflow --overwrite

# Generate fernet key and webserver secret
echo "[3/8] Generating Fernet key and webserver secret..."
FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || \
             openssl rand -base64 32)
WEBSERVER_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || \
                   openssl rand -hex 32)

echo "  Fernet key generated (32 bytes)"
echo "  Webserver secret generated (32 bytes)"

# Create secret for SMTP password (if provided)
if [ -n "$SMTP_PASSWORD" ]; then
  echo "[4/8] Creating SMTP password secret..."
  kubectl create secret generic airflow-smtp-secret \
    --from-literal=smtp_password="$SMTP_PASSWORD" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "[4/8] Skipping SMTP password secret (not provided — set SMTP_PASSWORD env var)"
fi

# Create secret for Slack webhook (if provided)
if [ -n "$SLACK_WEBHOOK_URL" ]; then
  echo "Creating Slack webhook secret..."
  kubectl create secret generic airflow-slack-secret \
    --from-literal=webhook_url="$SLACK_WEBHOOK_URL" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# Apply webserver secret YAML
echo "[5/8] Applying webserver secret..."
kubectl apply -f "$(dirname "$0")/../webserver-secret.yaml" 2>/dev/null || true

# Install/upgrade Airflow via Helm
echo "[6/8] Installing Airflow via Helm (this takes 3-5 minutes)..."
helm upgrade --install "$RELEASE_NAME" apache-airflow/airflow \
  --namespace "$NAMESPACE" \
  --version "$CHART_VERSION" \
  --values "$(dirname "$0")/values.yaml" \
  --set fernetKey="$FERNET_KEY" \
  --set webserverSecretKey="$WEBSERVER_SECRET" \
  --set "config.smtp.smtp_mail_from=${EMAIL}" \
  --timeout 10m \
  --wait

# Wait for all pods
echo "[7/8] Waiting for all Airflow pods to be Ready..."
kubectl rollout status deployment/"${RELEASE_NAME}-webserver" -n "$NAMESPACE" --timeout=300s
kubectl rollout status deployment/"${RELEASE_NAME}-scheduler" -n "$NAMESPACE" --timeout=300s

echo "[8/8] Verifying installation..."
kubectl get pods -n "$NAMESPACE"

echo ""
echo "✅ Airflow installed successfully!"
echo ""
echo "Access Airflow UI:"
echo "  kubectl port-forward svc/${RELEASE_NAME}-webserver 8080:8080 -n airflow"
echo "  Then open: http://localhost:8080"
echo "  Default login: admin / admin"
echo ""
echo "Next: bash airflow/connections/setup-connections.sh"
