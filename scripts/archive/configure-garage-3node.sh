#!/usr/bin/env bash
# configure-garage-3node.sh - Configure 3-node Garage S3 cluster
# Nodes: Zephyr (fast), Nexus (medium), Sentry (slow)
# Capacity tiers based on storage speed

set -euo pipefail

# Node configuration (short IDs for layout commands)
# Capacity values: Garage uses byte units (T=TB, G=GB, M=MB)
# Based on actual available storage from `garage status`
ZEPHYR_SHORT="35ba2a0bd6db0c86"    # Fast - SSD
ZEPHYR_FULL="35ba2a0bd6db0c86ed663cbd32d0dbe4e103cbc7438df59f663e03cc54a41acb@10.1.1.110:3901"
ZEPHYR_CAP="500G"  # ~466GB available on SSD (use conservative value)

NEXUS_SHORT=""  # Will be populated after Nexus Garage is running
NEXUS_CAP="3T"  # ~4TB available on bcache (use conservative value)

SENTRY_SHORT="1c10c1bfb54bcaa5"    # Slow - HDD
SENTRY_FULL="1c10c1bfb54bcaa5a9cce11364a1f0faa38fb43b8331fe77081af380ddde0c39@10.1.1.140:3901"
SENTRY_CAP="900G"  # ~998GB available on HDD (use conservative value)

REPLICATION_FACTOR=3  # 3-node cluster

echo "=========================================="
echo "Garage 3-Node Cluster Configuration"
echo "=========================================="
echo ""
echo "Nodes:"
echo "  Zephyr (fast):  ${ZEPHYR_CAP} (~466GB SSD)"
echo "  Nexus (medium): ${NEXUS_CAP} (~4TB bcache)"
echo "  Sentry (slow):  ${SENTRY_CAP} (~998GB HDD)"
echo ""
echo "Replication factor: ${REPLICATION_FACTOR}"
echo ""
echo "=========================================="

# Step 1: Connect Sentry to Zephyr
echo "[Step 1/6] Connecting Sentry to Zephyr..."
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml node connect $SENTRY_FULL" && echo "✓ Sentry connected to Zephyr" || echo "✗ Connection failed (may already be connected)"

# Step 2: Check cluster status
echo ""
echo "[Step 2/6] Checking cluster status..."
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml status"

# Step 3: Check if Garage is running on Nexus
echo ""
echo "[Step 3/6] Checking Nexus Garage status..."
if ssh nexus "systemctl is-active garage.service" 2>/dev/null | grep -q active; then
    echo "✓ Garage is running on Nexus"

    # Get Nexus node ID
    NEXUS_FULL=$(ssh nexus "sudo /run/current-system/sw/bin/garage node id" | grep -o '[a-f0-9]\+@10\.1\.1\.120:3901')
    NEXUS_SHORT=$(echo "$NEXUS_FULL" | cut -d@ -f1 | cut -c1-16)

    echo "  Nexus ID: ${NEXUS_SHORT}"

    # Connect Nexus to Zephyr
    echo "[Step 3b/6] Connecting Nexus to cluster..."
    ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml node connect $NEXUS_FULL" && echo "✓ Nexus connected" || echo "✗ Connection failed"
else
    echo "⚠ Garage NOT running on Nexus"
    echo "  Deploy Nexus first, then run:"
    echo "  garage node connect \$NEXUS_FULL"
fi

# Step 4: Create cluster layout
echo ""
echo "[Step 4/6] Creating cluster layout..."

# Assign Zephyr (fast, high capacity)
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml layout assign ${ZEPHYR_SHORT} -z zephyr -c ${ZEPHYR_CAP}" && echo "✓ Zephyr assigned (zephyr zone, ${ZEPHYR_CAP} capacity)" || echo "  May already be assigned"

# Assign Sentry (slow, low capacity)
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml layout assign ${SENTRY_SHORT} -z sentry -c ${SENTRY_CAP}" && echo "✓ Sentry assigned (sentry zone, ${SENTRY_CAP} capacity)" || echo "  May already be assigned"

# Step 5: Show staged layout
echo ""
echo "[Step 5/6] Staged cluster layout:"
ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml layout show"

# Step 6: Apply layout
echo ""
echo "[Step 6/6] Applying cluster layout..."
if ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml layout apply --version 1" 2>&1; then
    echo "✓ Cluster layout applied successfully"
else
    echo "⚠ Layout apply failed - may need 3 nodes with replication_factor=3"
    echo "  Current nodes in layout:"
    ssh zephyr "sudo /run/current-system/sw/bin/garage -c /etc/garage.toml layout show" 2>/dev/null || true
fi

echo ""
echo "=========================================="
echo "Next steps:"
echo "=========================================="
echo "1. Ensure Garage is running on all 3 nodes"
echo "2. Verify cluster health: garage status"
echo "3. Create buckets and S3 keys"
echo ""
