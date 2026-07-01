#!/usr/bin/env bash
#
# Setup AI Inference Monitoring Dashboard in Grafana
#

set -euo pipefail

GRAFANA_URL="http://127.0.0.1:3001"
GRAFANA_USER="admin"
GRAFANA_PASSWORD="cluster-admin"
DASHBOARD_FILE="/etc/nixos/modules/services/monitoring/ai-inference-dashboard-comprehensive.json"

echo "Setting up AI Inference Monitoring Dashboard..."

# Check if Grafana is running
if ! curl -s -f "${GRAFANA_URL}/api/health" >/dev/null; then
    echo "ERROR: Grafana is not running at ${GRAFANA_URL}"
    echo "Start Grafana with: systemctl start grafana"
    exit 1
fi

echo "✓ Grafana is running"

# Import dashboard (overwrite if exists)
echo "Importing dashboard..."
RESPONSE=$(curl -s -X POST "${GRAFANA_URL}/api/dashboards/db" \
    -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{
        \"dashboard\": $(cat ${DASHBOARD_FILE}),
        \"overwrite\": true,
        \"message\": \"AI Inference Model Health Dashboard\"
    }")

if echo "$RESPONSE" | jq -e '.status == "success"' >/dev/null 2>&1; then
    echo "✓ Dashboard imported successfully!"
    DASHBOARD_ID=$(echo "$RESPONSE" | jq -r '.id')
    DASHBOARD_UID=$(echo "$RESPONSE" | jq -r '.uid')
    DASHBOARD_URL=$(echo "$RESPONSE" | jq -r '.url')
    echo "  ID: ${DASHBOARD_ID}"
    echo "  UID: ${DASHBOARD_UID}"
    echo "  URL: ${GRAFANA_URL}${DASHBOARD_URL}"
else
    echo "✗ Failed to import dashboard"
    echo "Response: $RESPONSE"
    exit 1
fi

echo
echo "AI Inference Dashboard Setup Complete!"
echo
echo "Access the dashboard at:"
echo "  ${GRAFANA_URL}/d/${DASHBOARD_UID}"
echo
echo "Features:"
echo "  - GPU utilization and memory usage (RTX 3060 Ti + RTX 3090)"
echo "  - Backend health status"
echo "  - Request latency metrics"
echo "  - Model availability status"
echo "  - Auto-refresh every 10 seconds"
echo
echo "To run comprehensive model health evaluation:"
echo "  python3 /etc/nixos/scripts/model-health-evaluator.py"
