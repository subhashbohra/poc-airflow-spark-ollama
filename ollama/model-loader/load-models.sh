#!/usr/bin/env bash
# =============================================================================
# load-models.sh — Pull Ollama models into the running pod
# Run this AFTER Ollama pod is Ready
# =============================================================================
set -euo pipefail

NAMESPACE="llm-serving"
MODEL="${MODEL:-gemma2:2b}"
TIMEOUT="${TIMEOUT:-600}"

echo "============================================="
echo " Ollama Model Loader"
echo " Model:     $MODEL"
echo " Namespace: $NAMESPACE"
echo "============================================="

# Wait for Ollama pod to be ready
echo "[1/4] Waiting for Ollama pod to be Ready..."
kubectl wait --for=condition=ready pod -l app=ollama -n "$NAMESPACE" --timeout="${TIMEOUT}s"

# Get pod name
POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app=ollama -o jsonpath='{.items[0].metadata.name}')
echo "  Pod: $POD_NAME"

# Pull model
echo "[2/4] Pulling model: $MODEL (this may take 5-10 minutes on first run)..."
kubectl exec -n "$NAMESPACE" "$POD_NAME" -- ollama pull "$MODEL"

echo "[3/4] Verifying model is available..."
kubectl exec -n "$NAMESPACE" "$POD_NAME" -- ollama list

# Run a test inference
echo "[4/4] Running test inference to verify model works..."
TEST_RESPONSE=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
  curl -s -X POST http://localhost:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d "{\"model\": \"${MODEL}\", \"prompt\": \"Reply with only valid JSON: {\\\"status\\\": \\\"ok\\\"}\", \"format\": \"json\", \"stream\": false, \"options\": {\"temperature\": 0.1, \"num_predict\": 50}}" \
  --max-time 120)

echo "  Test inference response:"
echo "  $TEST_RESPONSE" | head -c 500

echo ""
echo "✅ Model $MODEL loaded and verified!"
echo ""
echo "Ollama API endpoint (cluster-internal):"
echo "  http://ollama-service.llm-serving.svc.cluster.local:11434"
