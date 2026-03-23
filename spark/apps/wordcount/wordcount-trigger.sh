#!/usr/bin/env bash
# wordcount-trigger.sh — Manually trigger a WordCount SparkApplication
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
APP_NAME="wordcount-${TIMESTAMP}"

echo "Submitting WordCount SparkApplication: $APP_NAME"

# Create a copy with unique name
sed "s/wordcount-manual/${APP_NAME}/g" \
  spark/apps/wordcount/wordcount-app.yaml | kubectl apply -f -

echo "Submitted. Watching status..."
echo ""

# Watch until complete or failed
for i in $(seq 1 60); do
  STATE=$(kubectl get sparkapplication "$APP_NAME" -n spark-jobs \
    -o jsonpath='{.status.applicationState.state}' 2>/dev/null || echo "PENDING")
  echo "[${i}/60] State: $STATE"
  if [[ "$STATE" == "COMPLETED" ]]; then
    echo "✅ WordCount job completed successfully!"
    echo ""
    echo "Driver logs:"
    DRIVER_POD=$(kubectl get pods -n spark-jobs -l "spark-role=driver" \
      --field-selector=status.phase=Succeeded \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$DRIVER_POD" ]; then
      kubectl logs "$DRIVER_POD" -n spark-jobs | tail -20
    fi
    echo ""
    echo "Cleaning up SparkApplication CR..."
    kubectl delete sparkapplication "$APP_NAME" -n spark-jobs
    exit 0
  elif [[ "$STATE" == "FAILED" ]]; then
    echo "❌ WordCount job failed!"
    kubectl describe sparkapplication "$APP_NAME" -n spark-jobs
    exit 1
  fi
  sleep 10
done

echo "Timeout waiting for job to complete"
exit 1
