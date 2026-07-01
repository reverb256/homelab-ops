#!/usr/bin/env bash
# configure-garage-cluster.sh - Configure Garage S3 cluster
# Sets up cluster layout, buckets, and access keys

set -euo pipefail

# Node configuration
ZEPHYR_ID="35ba2a0bd6db0c86ed663cbd32d0dbe4e103cbc7438df59f663e03cc54a41acb@10.1.1.110:3901"
SENTRY_ID="1c10c1bfb54bcaa5a9cce11364a1f0faa38fb43b8331fe77081af380ddde0c39@10.1.1.140:3901"
#NEXUS_ID=""  # Will be added after Nexus is deployed

# Cluster configuration
REPLICATION_FACTOR=2  # 2-node cluster initially (zephyr + sentry)
ZONES=("zephyr" "sentry")
CAPACITIES=("1" "1")

echo "[garage] Configuring Garage cluster..."

# Step 1: Connect nodes together (run on zephyr)
echo "[garage] Step 1: Connecting Sentry to Zephyr..."
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml node connect $SENTRY_ID" || {
    echo "[garage] Warning: Node connect may have failed, continuing anyway..."
}

# Step 2: Check cluster status
echo "[garage] Step 2: Checking cluster status..."
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml status"

# Step 3: Create cluster layout
echo "[garage] Step 3: Creating cluster layout..."
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml layout assign $ZEPHYR_ID -z zephyr -c 1 -t zephyr" || echo "[garage] May already be assigned"
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml layout assign $SENTRY_ID -z sentry -c 1 -t sentry" || echo "[garage] May already be assigned"

# Step 4: Apply layout
echo "[garage] Step 4: Applying layout (version 1)..."
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml layout apply --version 1" || {
    echo "[garage] Note: Layout may already be applied or needs more nodes"
}

# Step 5: Show final layout
echo "[garage] Step 5: Current cluster layout:"
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml layout show"

# Step 6: Create buckets
echo "[garage] Step 6: Creating buckets..."
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml bucket create backups || echo 'Bucket may already exist'"
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml bucket create media || echo 'Bucket may already exist'"
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml bucket create projects || echo 'Bucket may already exist'"

# Step 7: List buckets
echo "[garage] Step 7: Bucket list:"
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml bucket list"

echo "[garage] Cluster configuration complete!"
echo ""
echo "[garage] Next steps:"
echo "  1. Create S3 access keys (see create-garage-keys.sh)"
echo "  2. Configure applications to use Garage S3 endpoint"
echo "  3. Add Nexus to cluster once deployed"
