#!/usr/bin/env bash
# Alertmanager MCP (ntk148v/alertmanager-mcp-server) — vmalertmanager is a HEADLESS
# service (no ClusterIP), so reach it with kubectl port-forward (proven pattern).
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n monitoring port-forward svc/vmalertmanager-vmstack-victoria-metrics-k8s-stack 19093:9093 >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT
sleep 2
export ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://127.0.0.1:19093}"
export MCP_TRANSPORT=http MCP_HOST=0.0.0.0 MCP_PORT=8797
exec /usr/bin/uv run --directory /home/j_kro/services/alertmanager-mcp src/alertmanager_mcp_server/server.py
