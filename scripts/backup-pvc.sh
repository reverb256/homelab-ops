#!/bin/bash
# Simple PVC backup script

set -e

BACKUP_DIR="/var/backups/k8s-pvc"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RETENTION_DAYS=30

# Create backup directory
sudo mkdir -p "$BACKUP_DIR"

echo "=== Backing up Provider PVC ==="

# PVC details
PVC_NAME="home-default-default-fixed-0"

# Get the PV details
PV_NAME=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
echo "PVC: $PVC_NAME"
echo "PV: $PV_NAME"

# Create a temporary pod to access the PVC
POD_NAME="backup-${PVC_NAME}-${TIMESTAMP}"

echo "Creating temporary backup pod..."
kubectl run "$POD_NAME" -n "$NAMESPACE" \
  --image=ubuntu:22.04 \
  --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"backup","image":"ubuntu:22.04","command":["sleep","3600"],"volumeMounts":[{"name":"pvc","mountPath":"/data"}]}],"volumes":[{"name":"pvc","persistentVolumeClaim":{"claimName":"'$PVC_NAME'"}}]}}' \
  --request-timeout=10s > /dev/null

# Wait for pod to be ready
echo "Waiting for backup pod to be ready..."
kubectl wait --for=condition=Ready pod/"$POD_NAME" -n "$NAMESPACE" --timeout=120s

# Create backup archive
BACKUP_FILE="${BACKUP_DIR}/${NAMESPACE}-${PVC_NAME}-${TIMESTAMP}.tar.gz"

echo "Creating backup archive..."
kubectl exec "$POD_NAME" -n "$NAMESPACE" -- tar czf /tmp/backup.tar.gz -C /data . 2>/dev/null || \
  kubectl exec "$POD_NAME" -n "$NAMESPACE" -- tar czf /tmp/backup.tar.gz -C /data . 

# Copy backup to host
kubectl cp "$NAMESPACE/$POD_NAME:/tmp/backup.tar.gz" "$BACKUP_FILE"

# Verify backup
BACKUP_SIZE=$(stat -f%z "$BACKUP_FILE" 2>/dev/null || stat -c%s "$BACKUP_FILE")
echo "✓ Backup created: $BACKUP_FILE (${BACKUP_SIZE} bytes)"

# Clean up
echo "Cleaning up backup pod..."
kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --timeout=30s > /dev/null

echo "✓ PVC backup completed successfully"
ls -lh "$BACKUP_FILE"
