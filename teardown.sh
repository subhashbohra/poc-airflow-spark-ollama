#!/usr/bin/env bash
# =============================================================================
# teardown.sh — Cleanly remove all GCP resources for the PoC
#
# WARNING: This deletes the GKE cluster and all associated resources.
# Run this when you are done with the demo to stop GCP charges.
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-ollama-491104}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER_NAME="${CLUSTER_NAME:-poc-cluster}"

echo "============================================================"
echo " PoC Teardown — Removing All GCP Resources"
echo "============================================================"
echo " Project:  $PROJECT_ID"
echo " Zone:     $ZONE"
echo " Cluster:  $CLUSTER_NAME"
echo ""
echo " ⚠️  This will DELETE all resources. Ctrl+C to cancel."
echo "============================================================"
echo ""
read -p "Are you sure? (type 'yes' to confirm): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Teardown cancelled."
  exit 0
fi

# -------------------------------------------------------------------------
# Step 1: Remove Helm releases (to release Load Balancers / PVCs)
# -------------------------------------------------------------------------
echo ""
echo "[1/4] Removing Helm releases..."
helm uninstall airflow -n airflow 2>/dev/null && echo "  ✅ Airflow removed" || echo "  (not found)"
helm uninstall spark-operator -n spark-operator 2>/dev/null && echo "  ✅ Spark Operator removed" || echo "  (not found)"
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null && echo "  ✅ Monitoring removed" || echo "  (not found)"

# -------------------------------------------------------------------------
# Step 2: Delete all namespaces (cleans up PVCs, Deployments, Services)
# -------------------------------------------------------------------------
echo ""
echo "[2/4] Deleting namespaces..."
for ns in airflow spark-operator spark-jobs llm-serving monitoring; do
  kubectl delete namespace "$ns" --ignore-not-found --timeout=120s 2>/dev/null
  echo "  Deleted namespace: $ns"
done

# -------------------------------------------------------------------------
# Step 3: Delete GKE cluster (this also removes all node pools)
# -------------------------------------------------------------------------
echo ""
echo "[3/4] Deleting GKE cluster: $CLUSTER_NAME ..."
gcloud container clusters delete "$CLUSTER_NAME" \
  --zone="$ZONE" \
  --project="$PROJECT_ID" \
  --quiet

echo "  ✅ Cluster deleted"

# -------------------------------------------------------------------------
# Step 4: Clean up any orphaned PVs / Load Balancers
# -------------------------------------------------------------------------
echo ""
echo "[4/4] Checking for orphaned resources..."
# List any remaining disks
echo "  Persistent disks:"
gcloud compute disks list --project="$PROJECT_ID" --filter="name~poc" --format="table(name,zone,status)" 2>/dev/null || true

echo ""
echo "============================================================"
echo " ✅ Teardown Complete"
echo "============================================================"
echo ""
echo "All compute resources removed."
echo "No further GCP charges will accrue for this PoC."
echo ""
echo "If any persistent disks remain above, delete them manually:"
echo "  gcloud compute disks delete DISK_NAME --zone=$ZONE --project=$PROJECT_ID"
