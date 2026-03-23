#!/usr/bin/env bash
# =============================================================================
# install.sh — Prometheus + Grafana installation (Phase 7)
# =============================================================================
set -euo pipefail

NAMESPACE="monitoring"

echo "============================================="
echo " Monitoring Stack Installation"
echo " (Prometheus + Grafana)"
echo "============================================="

# Add Helm repos
echo "[1/5] Adding Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create namespace
echo "[2/5] Ensuring monitoring namespace exists..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create Grafana dashboard ConfigMap
echo "[3/5] Loading pipeline health dashboard..."
kubectl create configmap grafana-pipeline-health-dashboard \
  --from-file="$(dirname "$0")/dashboards/pipeline-health.json" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

# Install kube-prometheus-stack (Prometheus + Grafana bundled)
echo "[4/5] Installing Prometheus + Grafana..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --values "$(dirname "$0")/../prometheus/values.yaml" \
  --wait \
  --timeout 8m

echo "[5/5] Verifying installation..."
kubectl get pods -n "$NAMESPACE"

echo ""
echo "✅ Monitoring stack installed!"
echo ""
echo "Access Grafana:"
echo "  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
echo "  Then open: http://localhost:3000"
echo "  Login: admin / poc-grafana-admin"
echo ""
echo "Access Prometheus:"
echo "  kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring"
