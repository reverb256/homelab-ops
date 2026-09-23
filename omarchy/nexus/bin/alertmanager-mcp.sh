#!/usr/bin/env bash
# Alertmanager MCP (ntk148v/alertmanager-mcp-server) — launcher for the
# alertmanager-mcp.service user unit.
#
# Deployed copy: ~/services/alertmanager-mcp.sh (the path the systemd --user
# unit's ExecStart names). This repo copy under scripts/ is the versioned one;
# keep the two in sync, or point ExecStart here on the next restart.
#
# vmalertmanager is a HEADLESS service (no ClusterIP), so the MCP reaches it
# through a kubectl port-forward. Two things this script must get right:
#
# 1) The forward must die WITH this unit. This script used to `exec` uvicorn,
#    which replaced the shell and discarded its EXIT trap, so the forward
#    survived as an orphan holding the port. The next start could not bind it
#    and every alert call failed with
#        Error executing tool get_alerts: slice(0, 10, None)
#    So: no exec, run the server as a child and trap its termination.
#
# 2) The forward must be re-established if it dies while the MCP is up (an
#    API-server blip kills it; the MCP then answers every call with an upstream
#    error while still looking healthy). So it runs under a restart loop, and
#    uvicorn only starts once the port actually answers.
set -uo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

LOCAL_PORT="${ALERTMANAGER_LOCAL_PORT:-19093}"
MCP_PORT="${MCP_PORT:-8797}"
TARGET="svc/vmalertmanager-vmstack-victoria-metrics-k8s-stack"
MCP_DIR="/home/j_kro/services/alertmanager-mcp"

# Clear an orphan forward left by an earlier run before claiming the port.
# The pattern must match kubectl's actual command line, which ends in
# "<local-port>:9093" - a bare ":<local-port>" never appears there.
if ss -ltn "sport = :${LOCAL_PORT}" 2>/dev/null | grep -q LISTEN; then
  echo "port ${LOCAL_PORT} already in use - clearing stale port-forward" >&2
  pkill -f "kubectl.*port-forward.*${LOCAL_PORT}:" 2>/dev/null || true
  sleep 2
fi

keep_forward() {
  while true; do
    kubectl -n monitoring port-forward "$TARGET" "${LOCAL_PORT}:9093" >/dev/null 2>&1
    echo "port-forward on ${LOCAL_PORT} exited; re-establishing in 2s" >&2
    sleep 2
  done
}
keep_forward &
FORWARD_PID=$!

shutdown() {
  kill "$SERVER_PID" "$FORWARD_PID" 2>/dev/null || true
  pkill -f "kubectl.*port-forward.*${LOCAL_PORT}:" 2>/dev/null || true
}
trap shutdown EXIT INT TERM HUP

# Do not hand a dead Alertmanager URL to the MCP: wait for it to answer.
for _ in $(seq 1 60); do
  if curl -sf -m 2 "http://127.0.0.1:${LOCAL_PORT}/-/ready" >/dev/null 2>&1; then
    echo "alertmanager reachable on ${LOCAL_PORT}" >&2
    break
  fi
  sleep 0.5
done

export ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://127.0.0.1:${LOCAL_PORT}}"
export MCP_TRANSPORT=http MCP_HOST=0.0.0.0 MCP_PORT="${MCP_PORT}"

# NOTE: deliberately NOT `exec` — see (1) above.
/usr/bin/uv run --directory "$MCP_DIR" src/alertmanager_mcp_server/server.py &
SERVER_PID=$!
wait "$SERVER_PID"
exit $?
