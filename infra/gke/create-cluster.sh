#!/usr/bin/env bash
# =============================================================================
# create-cluster.sh — GKE Cluster Creation for Airflow + Spark + Ollama PoC
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-ollama-491104}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER_NAME="${CLUSTER_NAME:-poc-cluster}"
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"

echo "============================================="
echo " GKE Cluster Creation"
echo " Project:  $PROJECT_ID"
echo " Region:   $REGION"
echo " Zone:     $ZONE"
echo " Cluster:  $CLUSTER_NAME"
echo "============================================="

# Set default project
gcloud config set project "$PROJECT_ID"

# Enable required APIs
echo "[1/6] Enabling required GCP APIs..."
gcloud services enable \
  container.googleapis.com \
  containerregistry.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  --project="$PROJECT_ID" --quiet

# Create GKE Standard cluster (NOT Autopilot — matches GDC behavior)
echo "[2/6] Creating GKE Standard cluster: $CLUSTER_NAME ..."
gcloud container clusters create "$CLUSTER_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --cluster-version="latest" \
  --num-nodes=1 \
  --machine-type="e2-standard-2" \
  --disk-size=50 \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=2 \
  --enable-network-policy \
  --enable-ip-alias \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --logging=SYSTEM,WORKLOAD \
  --monitoring=SYSTEM \
  --no-enable-basic-auth \
  --quiet

# Add Airflow node pool (spot for cost savings)
echo "[3/6] Adding Airflow node pool..."
gcloud container node-pools create airflow-pool \
  --cluster="$CLUSTER_NAME" \
  --zone="$ZONE" \
  --project="$PROJECT_ID" \
  --machine-type="e2-standard-4" \
  --num-nodes=1 \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=2 \
  --spot \
  --node-labels="pool=airflow" \
  --node-taints="pool=airflow:NoSchedule" \
  --disk-size=50 \
  --quiet

# Add Spark node pool (spot, autoscale for ephemeral jobs)
echo "[4/6] Adding Spark node pool..."
gcloud container node-pools create spark-pool \
  --cluster="$CLUSTER_NAME" \
  --zone="$ZONE" \
  --project="$PROJECT_ID" \
  --machine-type="e2-standard-4" \
  --num-nodes=0 \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=3 \
  --spot \
  --node-labels="pool=spark" \
  --node-taints="pool=spark:NoSchedule" \
  --disk-size=50 \
  --quiet

# Add Ollama node pool (spot, CPU only)
echo "[5/6] Adding Ollama node pool..."
gcloud container node-pools create ollama-pool \
  --cluster="$CLUSTER_NAME" \
  --zone="$ZONE" \
  --project="$PROJECT_ID" \
  --machine-type="e2-standard-4" \
  --num-nodes=1 \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=1 \
  --spot \
  --node-labels="pool=ollama" \
  --node-taints="pool=ollama:NoSchedule" \
  --disk-size=50 \
  --quiet

# Configure kubectl credentials
echo "[6/6] Configuring kubectl credentials..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --zone="$ZONE" \
  --project="$PROJECT_ID"

# Set billing budget alert if billing account provided
if [ -n "$BILLING_ACCOUNT" ]; then
  echo "Setting billing budget alert..."
  gcloud billing budgets create \
    --billing-account="$BILLING_ACCOUNT" \
    --display-name="Ollama PoC Budget" \
    --budget-amount=50USD \
    --threshold-rule=percent=0.8 \
    --threshold-rule=percent=1.0 \
    --quiet || echo "Warning: Could not create budget alert. Please set manually."
fi

echo ""
echo "✅ Cluster created successfully!"
echo ""
echo "Next steps:"
echo "  kubectl get nodes"
echo "  bash infra/namespaces/apply-namespaces.sh"
