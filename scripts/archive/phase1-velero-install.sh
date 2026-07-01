# Velero Installation Script
# Phase 1: Foundation - Backup & Disaster Recovery

set -e

echo "🔧 Phase 1: Velero Installation"
echo "================================"

# Step 1: Create namespaces
echo "📦 Creating Velero namespaces..."
kubectl create namespace velero
kubectl create namespace velero-s3

# Step 2: Copy Garage S3 credentials from existing secret
echo "🔑 Configuring Garage S3 credentials for Velero..."
# Copy existing secret from default namespace to velero namespace
kubectl get secret garage-s3-credentials -n default -o yaml \
  | sed 's/namespace: default/namespace: velero/' \
  | kubectl apply -f -

# Also create as velero-s3-credentials for Velero
kubectl get secret garage-s3-credentials -n default -o yaml \
  | sed 's/name: garage-s3-credentials/name: velero-s3-credentials/' \
  | sed 's/namespace: default/namespace: velero/' \
  | kubectl apply -f -

echo "✅ Credentials configured"

# Step 3: Add Velero Helm repository
echo "📊 Adding Velero Helm repository..."
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts

# Step 4: Create Velero values file
echo "📝 Creating Velero configuration..."
cat > /tmp/velero-values.yaml <<EOF
configuration:
  provider: aws
  backupStorageLocation:
    name: garage-s3
    bucket: velero-backups
    url: http://10.1.1.110:3900
    insecure: true
  volumeSnapshotLocation:
    provider: generic
  defaultBackupTTL: 720h

initContainers:
  - name: velero-aws-plugin
    image: velero/velero-plugin-for-aws:v1.9.0
    volumeMounts:
    - mountPath: /credentials
      name: cloud-credentials
    env:
      AWS_SHARED_CREDENTIALS_FILE: /credentials/credentials
  volumes:
  - name: cloud-credentials
    emptyDir: {}

service:
  server:
    timeout: 300s

credentials:
  useSecret: true
  name: velero-s3-credentials
  extraSecretRef:
    namespace: velero

# Resource limits for stability
resources:
  requests:
    cpu: "100m"
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "1Gi"

# Enable pod volume backup
snapshotsEnabled: true
EOF

# Step 5: Install Velero
echo "🚀 Installing Velero (chart version 12.0.0, app version 1.18.0)..."
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --values /tmp/velero-values.yaml \
  --version 12.0.0 \
  --wait --timeout 5m

# Step 6: Cleanup
rm /tmp/velero-values.yaml

echo "✅ Velero installed successfully!"
echo ""
echo "🔍 Next steps:"
echo "  1. Verify Velero: kubectl get pods -n velero"
echo "  2. Check backup location: velero backup-location get"
echo "  3. Test backup: velero backup create test-backup --wait"
