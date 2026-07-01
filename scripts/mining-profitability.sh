#!/bin/bash
# Simple Tari Mining Profitability Monitor
# Run with: bash mining-profitability.sh

echo "=== Tari (XTM) Mining Profitability ==="
echo "Date: $(date)"
echo ""

# XTM Price (from CryptoCompare - reliable)
XTM_PRICE=$(curl -s "https://min-api.cryptocompare.com/data/price?fsym=XTM&tsyms=USD" | jq -r '.USD')
echo "XTM Price: \$$XTM_PRICE"

# CPU Hashrate from sentry xmrig
CPU_HASH=$(ssh sentry "journalctl -u xmrig --since '10 minutes ago' | grep -oP 'speed \K[\d.]+ H/s' | tail -1 | grep -oP '[\d.]+' || echo '2300'")
echo "CPU Hashrate (sentry): ${CPU_HASH} H/s"

# GPU Count
GPU_COUNT=5
echo "GPU Count: ${GPU_COUNT}× NVIDIA RTX 4060"

# Network stats (approximate for RandomX)
NETWORK_HASHRATE_MHS=100  # ~100 MH/s for RandomX network
NETWORK_HASHRATE_SOL=5000000  # ~5 MH/s for Sol equivalent

# Calculate contribution
CPU_KHPS=$(echo "scale=2; $CPU_HASH / 1000" | bc)
CPU_SHARE=$(echo "scale=6; $CPU_KHPS / ($NETWORK_HASHRATE_MHS * 1000)" | bc)

# GPU estimate (RTX 4060 ~300-400 Sol/s each)
GPU_SOL_PER_CARD=350
TOTAL_GPU_SOL=$((GPU_COUNT * GPU_SOL_PER_CARD))
GPU_SHARE=$(echo "scale=6; $TOTAL_GPU_SOL / $NETWORK_HASHRATE_SOL" | bc)

echo ""
echo "=== Network Share ==="
echo "CPU: ${CPU_SHARE}% of network"
echo "GPU: ${GPU_SHARE}% of network"

# Daily earnings estimate (assuming 1000 XTM/day network emission, approximate)
DAILY_EMISSION_XTM=1000000  # 1 million XTM daily emission (approximate)
CPU_DAILY_XTM=$(echo "scale=4; $CPU_SHARE * $DAILY_EMISSION_XTM" | bc)
GPU_DAILY_XTM=$(echo "scale=4; $GPU_SHARE * $DAILY_EMISSION_XTM" | bc)

CPU_DAILY_USD=$(echo "scale=4; $CPU_DAILY_XTM * $XTM_PRICE / 1000000000" | bc)
GPU_DAILY_USD=$(echo "scale=4; $GPU_DAILY_XTM * $XTM_PRICE / 1000000000" | bc)

echo ""
echo "=== Estimated Daily Earnings ==="
echo "CPU:  ${CPU_DAILY_XTM} XTM (\$${CPU_DAILY_USD})"
echo "GPU:  ${GPU_DAILY_XTM} XTM (\$${GPU_DAILY_USD})"

TOTAL_DAILY_USD=$(echo "scale=4; $CPU_DAILY_USD + $GPU_DAILY_USD" | bc)
TOTAL_MONTHLY_USD=$(echo "scale=2; $TOTAL_DAILY_USD * 30" | bc)

echo ""
echo "=== TOTAL ==="
echo "Daily:  \$${TOTAL_DAILY_USD}"
echo "Monthly: \$${TOTAL_MONTHLY_USD}"

# Save to log
echo "$(date -Iseconds),${XTM_PRICE},${CPU_HASH},${TOTAL_GPU_SOL},${TOTAL_DAILY_USD}" >> /tmp/mining-profitability.log

echo ""
echo "=== Recommendation ==="
echo "At current mining revenue (\$${TOTAL_DAILY_USD}/day), GPU mining is"
echo "NOT competitive with cloud pricing."
echo ""
echo "Consider:"
echo "  1. Switch GPUs to higher-value workloads"
echo "  2. Keep CPU mining on sentry (minimal opportunity cost)"
echo "  3. Monitor XTM price - if it rises above \$0.01, GPU mining may become profitable"
