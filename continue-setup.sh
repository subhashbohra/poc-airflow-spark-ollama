#!/usr/bin/env bash
# continue-setup.sh — Continues from Phase 4 onwards
set -euo pipefail

export SMTP_PASSWORD="${SMTP_PASSWORD:-}"
export EMAIL="${EMAIL:-subhashbohra003@gmail.com}"
export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────
# Fix PostgreSQL — check and wait properly
# ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 4 — PostgreSQL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "Checking PostgreSQL pod status..."
kubectl get pod -l app=postgres-metrics -n monitoring
echo ""

# Check if stuck due to storage class — patch if needed
SC=$(kubectl get pvc postgres-metrics-pvc -n monitoring \
  -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
echo "Storage class in use: $SC"

ACTUAL_SC=$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "standard")
echo "Available storage class: $ACTUAL_SC"

# Patch PVC if storage class mismatch
if [ "$SC" != "$ACTUAL_SC" ] && [ -n "$SC" ]; then
  echo "Storage class mismatch — recreating PVC with correct class: $ACTUAL_SC"
  kubectl delete deployment postgres-metrics -n monitoring --ignore-not-found
  kubectl delete pvc postgres-metrics-pvc -n monitoring --ignore-not-found
  sleep 5
  # Recreate with correct storage class
  kubectl apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-metrics-pvc
  namespace: monitoring
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${ACTUAL_SC}
  resources:
    requests:
      storage: 10Gi
YAML
  kubectl apply -f "$SCRIPT_DIR/storage/postgres/deployment.yaml"
  kubectl apply -f "$SCRIPT_DIR/storage/postgres/service.yaml"
fi

echo "Waiting for PostgreSQL pod (up to 3 min)..."
for i in $(seq 1 36); do
  STATUS=$(kubectl get pod -l app=postgres-metrics -n monitoring \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
  READY=$(kubectl get pod -l app=postgres-metrics -n monitoring \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  echo "  [$i/36] Phase=$STATUS Ready=$READY"
  if [ "$READY" = "true" ]; then
    echo "✅ PostgreSQL is ready!"
    break
  fi
  if [ "$i" = "36" ]; then
    echo "❌ PostgreSQL failed to start. Showing describe output:"
    kubectl describe pod -l app=postgres-metrics -n monitoring | tail -30
    exit 1
  fi
  sleep 5
done

echo "Applying schema..."
PG_POD=$(kubectl get pods -n monitoring -l app=postgres-metrics \
  -o jsonpath='{.items[0].metadata.name}')
kubectl cp "$SCRIPT_DIR/storage/postgres/schema.sql" "monitoring/$PG_POD:/tmp/schema.sql"
kubectl exec -n monitoring "$PG_POD" -- \
  psql -U metrics_user -d metrics -f /tmp/schema.sql
echo "✅ PostgreSQL schema applied!"

# ─────────────────────────────────────────────
# Phase 5 — Airflow
# ─────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 5 — Airflow (Helm)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SMTP_PASSWORD="$SMTP_PASSWORD" EMAIL="$EMAIL" \
  bash "$SCRIPT_DIR/airflow/helm/install.sh"

echo "Setting up Airflow connections..."
SMTP_PASSWORD="$SMTP_PASSWORD" SLACK_WEBHOOK="$SLACK_WEBHOOK_URL" \
  bash "$SCRIPT_DIR/airflow/connections/setup-connections.sh"

# ─────────────────────────────────────────────
# Phase 6 — Deploy DAGs
# ─────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 6 — Deploy DAGs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
AIRFLOW_SCHEDULER=$(kubectl get pods -n airflow -l component=scheduler \
  -o jsonpath='{.items[0].metadata.name}')
echo "Scheduler pod: $AIRFLOW_SCHEDULER"

# Copy DAGs
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

kubectl exec -n airflow "$AIRFLOW_SCHEDULER" -- \
  touch /opt/airflow/dags/utils/__init__.py

# Unpause DAGs
echo ""
echo "Unpausing DAGs..."
for dag in rca_dag wordcount_dag anomaly_detection_dag test_failure_dag; do
  kubectl exec -n airflow "$AIRFLOW_SCHEDULER" -- \
    airflow dags unpause "$dag" 2>/dev/null || true
  echo "  Unpaused: $dag"
done

# ─────────────────────────────────────────────
# Phase 7 — Monitoring
# ─────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PHASE 7 — Monitoring"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/monitoring/grafana/install.sh"

# ─────────────────────────────────────────────
# Final
# ─────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " FINAL VERIFICATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$SCRIPT_DIR/demo/run-demo.sh"

echo ""
echo "============================================================"
echo " ✅ PoC Setup Complete!"
echo "============================================================"
echo ""
echo "  Airflow UI:"
echo "    kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow"
echo "    http://localhost:8080  (admin / admin)"
echo ""
echo "  Grafana:"
echo "    kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
echo "    http://localhost:3000  (admin / admin)"
echo ""
echo "  Trigger demo failure:"
echo "    bash demo/inject-failure.sh"
echo ""
echo "  Teardown when done:"
echo "    bash teardown.sh"
echo "============================================================"
