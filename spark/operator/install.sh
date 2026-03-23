#!/usr/bin/env bash
# spark/operator/install.sh — Install Spark Operator via Helm
set -euo pipefail

echo "============================================="
echo " Spark Operator Installation"
echo "============================================="

# Add Helm repo
echo "[1/4] Adding Spark Operator Helm repo..."
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm repo update

# Install Spark Operator
echo "[2/4] Installing Spark Operator in spark-operator namespace..."
helm upgrade --install spark-operator spark-operator/spark-operator \
  --namespace spark-operator \
  --create-namespace \
  --values spark/operator/values.yaml \
  --set sparkJobNamespace=spark-jobs \
  --wait \
  --timeout 5m

# Apply RBAC for spark-jobs namespace
echo "[3/4] Applying Spark RBAC..."
kubectl apply -f spark/rbac/spark-rbac.yaml

# Wait for operator to be ready
echo "[4/4] Waiting for Spark Operator pod to be ready..."
kubectl rollout status deployment/spark-operator -n spark-operator --timeout=3m

echo ""
echo "✅ Spark Operator installed successfully!"
kubectl get pods -n spark-operator
