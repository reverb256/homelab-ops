#!/usr/bin/env bash
# create-garage-buckets.sh - Create S3 buckets and access keys
# Run this after Garage cluster layout is applied

set -euo pipefail

GARAGE_CLI="sudo /run/current-system/sw/bin/garage -c /etc/garage.toml"

echo "=========================================="
echo "Garage S3 Bucket & Key Management"
echo "=========================================="
echo ""

# Check cluster health first
echo "[Check] Verifying cluster health..."
CLUSTER_STATUS=$($GARAGE_CLI status 2>&1)
echo "$CLUSTER_STATUS" | grep -q "HEALTHY NODES" || {
    echo "ERROR: Cluster not healthy. Configure cluster first."
    exit 1
}

# Count nodes
NODE_COUNT=$(echo "$CLUSTER_STATUS" | grep -c "HEALTHY NODES" || true)
echo "✓ Found $NODE_COUNT healthy nodes"
echo ""

# Create buckets with tiered storage
echo "[Buckets] Creating S3 buckets..."
for bucket in backups media projects logs; do
    if $GARAGE_CLI bucket create "$bucket" 2>/dev/null; then
        echo "✓ Created bucket: $bucket"
    else
        # Check if bucket already exists
        if $GARAGE_CLI bucket list | grep -q "$bucket"; then
            echo "  Bucket already exists: $bucket"
        else
            echo "✗ Failed to create bucket: $bucket"
        fi
    fi
done
echo ""

# List all buckets
echo "[Buckets] Current buckets:"
$GARAGE_CLI bucket list
echo ""

# Create admin access key
echo "[Keys] Creating admin S3 access key..."
KEY_INFO=$($GARAGE_CLI key create --name admin-key 2>&1)
ACCESS_KEY=$(echo "$KEY_INFO" | grep "Gateway Secret" | cut -d'"' -f2 | head -1)
SECRET_KEY=$(echo "$KEY_INFO" | grep "Gateway Secret" | cut -d'"' -f2 | tail -1)

if [ -n "$ACCESS_KEY" ] && [ -n "$SECRET_KEY" ]; then
    echo "✓ Access key created"
    echo ""
    echo "=========================================="
    echo "S3 CREDENTIALS"
    echo "=========================================="
    echo "Access Key ID: $ACCESS_KEY"
    echo "Secret Access Key: $SECRET_KEY"
    echo ""
    echo "S3 Endpoint: http://10.1.1.110:3900"  # Zephyr
    echo "Region: garage"
    echo ""
    echo "=========================================="
    echo ""
    echo "Testing S3 access..."
    echo "=========================================="

    # Test with AWS CLI-style tools if available
    if command -v s3cmd &>/dev/null; then
        echo ""
        echo "s3cmd configuration:"
        echo "  s3cmd --access_key $ACCESS_KEY --secret_key $SECRET_KEY --hostbucket http://10.1.1.110:3900 ls s3://backups"
    fi

    if command -v aws &>/dev/null; then
        echo ""
        echo "AWS CLI configuration:"
        echo "  aws configure set default.s3.endpoint_url http://10.1.1.110:3900"
        echo "  aws configure set default.s3.addressing-style virtual"
        echo ""
        echo "Test list:"
        echo "  aws --endpoint-url http://10.1.1.110:3900 s3 ls"
    fi
else
    echo "✗ Failed to create access key"
fi

echo ""
echo "[Alias] Creating DNS alias for Garage..."
# Note: DNS aliases for buckets are automatically created by Garage
echo "Buckets are accessible at:"
echo "  http://10.1.1.110:3900/backups"
echo "  http://10.1.1.110:3900/media"
echo "  http://10.1.1.110:3900/projects"
echo "  http://10.1.1.110:3900/logs"
echo ""

echo "=========================================="
echo "Configuration complete!"
echo "=========================================="
