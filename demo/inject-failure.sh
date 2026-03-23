#!/usr/bin/env bash
# =============================================================================
# inject-failure.sh — Trigger intentional DAG failure for demo
# Configures which error scenario to use (0-4) then triggers the DAG
# =============================================================================
set -euo pipefail

NAMESPACE="airflow"
DAG_ID="test_failure_dag"
SCENARIO="${1:-2}"  # Default: Spark OOM (most impressive for demo)

SCENARIO_NAMES=(
  "FileNotFoundError: Missing input CSV file"
  "ConnectionError: Hive metastore unreachable"
  "OutOfMemoryError: Spark executor Java heap space"
  "OperationalError: PostgreSQL connection pool exhausted"
  "PermissionError: GCS bucket write access denied"
)

echo "============================================="
echo " Injecting Demo Failure"
echo " DAG:      $DAG_ID"
echo " Scenario: [$SCENARIO] ${SCENARIO_NAMES[$SCENARIO]}"
echo "============================================="

# Get scheduler pod
SCHEDULER_POD=$(kubectl get pods -n "$NAMESPACE" -l component=scheduler \
  -o jsonpath='{.items[0].metadata.name}')

# Set the scenario environment variable via Airflow Variable
kubectl exec -n "$NAMESPACE" "$SCHEDULER_POD" -- \
  airflow variables set DEMO_FAILURE_SCENARIO "$SCENARIO" 2>/dev/null || true

# Trigger the DAG
echo "Triggering $DAG_ID..."
kubectl exec -n "$NAMESPACE" "$SCHEDULER_POD" -- \
  airflow dags trigger "$DAG_ID" \
  --conf "{\"demo_scenario\": $SCENARIO}" \
  --run-id "demo-failure-$(date +%Y%m%d-%H%M%S)"

echo ""
echo "✅ DAG triggered! Expected timeline:"
echo "  00:00 — DAG starts"
echo "  00:05 — pre_failure_task succeeds"
echo "  00:12 — intentional_failure raises: ${SCENARIO_NAMES[$SCENARIO]}"
echo "  00:13 — on_failure_callback fires → Ollama RCA starts"
echo "  00:45 — Ollama generates JSON RCA (gemma2:2b ~30s inference)"
echo "  00:50 — Email sent to: subhashbohra003@gmail.com"
echo "  00:52 — Slack notification sent (if configured)"
echo ""
echo "Watch in Airflow UI:"
echo "  kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow"
echo "  http://localhost:8080/dags/test_failure_dag/grid"
