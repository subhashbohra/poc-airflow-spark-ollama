#!/usr/bin/env bash
# =============================================================================
# verify-models.sh — Health check + model list for Ollama
# =============================================================================
set -euo pipefail

NAMESPACE="llm-serving"

echo "============================================="
echo " Ollama Health Check"
echo "============================================="

POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app=ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD_NAME" ]; then
  echo "❌ No Ollama pod found in namespace $NAMESPACE"
  exit 1
fi

echo "Pod: $POD_NAME"
echo ""

# Check pod status
STATUS=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
echo "Pod status: $STATUS"

# Check API health
echo ""
echo "Checking /api/tags endpoint..."
HEALTH=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
  curl -s http://localhost:11434/api/tags --max-time 10 || echo '{"error":"unreachable"}')
echo "$HEALTH" | python3 -m json.tool 2>/dev/null || echo "$HEALTH"

# List models
echo ""
echo "Loaded models:"
kubectl exec -n "$NAMESPACE" "$POD_NAME" -- ollama list 2>/dev/null || echo "  (none loaded)"

# Quick inference test
echo ""
echo "Quick inference test (gemma2:2b)..."
RESULT=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
  curl -s -X POST http://localhost:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma2:2b","prompt":"Say OK","stream":false,"options":{"num_predict":5}}' \
  --max-time 60 2>/dev/null || echo '{"error":"failed"}')
echo "Response: $RESULT" | head -c 200

echo ""
echo "✅ Ollama health check complete"
