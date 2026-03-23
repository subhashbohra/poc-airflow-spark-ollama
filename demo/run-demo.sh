#!/usr/bin/env bash
# =============================================================================
# run-demo.sh — Full end-to-end verification script
# Run this after setup.sh to verify everything is working before the demo
# =============================================================================
set -euo pipefail

NAMESPACE_AIRFLOW="airflow"
NAMESPACE_SPARK="spark-jobs"
NAMESPACE_LLM="llm-serving"
NAMESPACE_MONITORING="monitoring"

PASS=0
FAIL=0

check() {
  local desc="$1"
  local cmd="$2"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "============================================="
echo " PoC End-to-End Verification"
echo " $(date)"
echo "============================================="

# -----------------------------------------------------------------------
echo ""
echo "[ Cluster Health ]"
check "kubectl connected" "kubectl cluster-info"
check "All system pods running" "kubectl get pods -n kube-system --field-selector=status.phase!=Running --field-selector=status.phase!=Succeeded | grep -c '' | grep -q '^0$'"

# -----------------------------------------------------------------------
echo ""
echo "[ Namespaces ]"
for ns in airflow spark-operator spark-jobs llm-serving monitoring; do
  check "Namespace $ns exists" "kubectl get namespace $ns"
done

# -----------------------------------------------------------------------
echo ""
echo "[ Airflow ]"
check "Airflow webserver running" "kubectl get pods -n $NAMESPACE_AIRFLOW -l component=webserver --field-selector=status.phase=Running | grep -q Running"
check "Airflow scheduler running" "kubectl get pods -n $NAMESPACE_AIRFLOW -l component=scheduler --field-selector=status.phase=Running | grep -q Running"
check "Airflow DAGs accessible" "kubectl exec -n $NAMESPACE_AIRFLOW \$(kubectl get pods -n $NAMESPACE_AIRFLOW -l component=scheduler -o jsonpath='{.items[0].metadata.name}') -- airflow dags list 2>/dev/null | grep -q rca_dag"

# -----------------------------------------------------------------------
echo ""
echo "[ Spark Operator ]"
check "Spark Operator running" "kubectl get pods -n spark-operator --field-selector=status.phase=Running | grep -q Running"
check "Spark ServiceAccount exists" "kubectl get sa spark -n spark-jobs"
check "Spark RBAC configured" "kubectl get rolebinding spark-role-binding -n spark-jobs"

# -----------------------------------------------------------------------
echo ""
echo "[ Ollama LLM ]"
check "Ollama pod running" "kubectl get pods -n $NAMESPACE_LLM -l app=ollama --field-selector=status.phase=Running | grep -q Running"
check "Ollama service exists" "kubectl get svc ollama-service -n $NAMESPACE_LLM"

OLLAMA_POD=$(kubectl get pods -n "$NAMESPACE_LLM" -l app=ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$OLLAMA_POD" ]; then
  check "Ollama API responding" "kubectl exec -n $NAMESPACE_LLM $OLLAMA_POD -- curl -s http://localhost:11434/api/tags --max-time 10 | grep -q models"
  check "gemma2:2b model loaded" "kubectl exec -n $NAMESPACE_LLM $OLLAMA_POD -- ollama list 2>/dev/null | grep -q gemma2"
fi

# -----------------------------------------------------------------------
echo ""
echo "[ PostgreSQL Metrics ]"
check "Postgres metrics pod running" "kubectl get pods -n $NAMESPACE_MONITORING -l app=postgres-metrics --field-selector=status.phase=Running | grep -q Running"
check "Postgres metrics service exists" "kubectl get svc postgres-metrics-svc -n $NAMESPACE_MONITORING"

# -----------------------------------------------------------------------
echo ""
echo "[ Monitoring ]"
check "Grafana running" "kubectl get pods -n $NAMESPACE_MONITORING -l app.kubernetes.io/name=grafana --field-selector=status.phase=Running | grep -q Running" || true
check "Prometheus running" "kubectl get pods -n $NAMESPACE_MONITORING -l app=prometheus --field-selector=status.phase=Running | grep -q Running" || true

# -----------------------------------------------------------------------
echo ""
echo "============================================="
echo " Verification Summary"
echo " PASSED: $PASS  |  FAILED: $FAIL"
echo "============================================="

if [ $FAIL -gt 0 ]; then
  echo ""
  echo "⚠️  Some checks failed. Review the output above."
  echo "    See CLAUDE.md 'If Something Fails' section for fixes."
  echo ""
  exit 1
else
  echo ""
  echo "✅ All checks passed! Ready for demo."
  echo ""
  echo "Demo commands:"
  echo "  1. Open Airflow UI:    kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow"
  echo "  2. Run Spark test:     bash spark/apps/wordcount/wordcount-trigger.sh"
  echo "  3. Inject failure:     bash demo/inject-failure.sh 2"
  echo "  4. Open Grafana:       kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
  echo ""
fi
