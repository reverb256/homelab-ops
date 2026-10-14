#!/bin/bash
# verify/k3s-kubeconfig-readable.sh — can the unprivileged agent lanes READ and
# USE the k3s kubeconfig?
#
# INCIDENT 2026-10-14 (this script is its regression check): the 15:32 k3s restart
# rewrote /etc/rancher/k3s/k3s.yaml as 0600 root:root. Every lane that shells
# `kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml` then failed with
#   error loading config file "...": open ...: permission denied
# and media-mcp-health.sh (cron 5f534c9b54e4) reported all six media services as
# "service <x> not found in ns/media" — a misleading message that hid the real
# cause — which put the media-mcp-health job in a failure streak and turned the
# trading sentinel RED ("SENTINEL-RED: cron streak: FAIL profilarr ...") while the
# media stack was healthy the whole time.
#
# Why this checks TWO things: a bare `chmod` is not a fix, because k3s rewrites the
# file on every start and takes the mode with it. Durability (the systemd
# ExecStartPost drop-in) is as load-bearing as the current mode, so it is asserted
# too — otherwise this check passes right after a manual chmod and the same silent
# failure returns at the next restart.
#
# Read-only. Exit: 0 = OK, 1 = FAIL, 2 = INCONCLUSIVE.
# Overrides (so the gate can be proven to fire without touching the live file):
#   K3S_KC          kubeconfig path            (default /etc/rancher/k3s/k3s.yaml)
#   K3S_KC_DROPIN   durability drop-in path    (default /etc/systemd/system/k3s.service.d/40-kubeconfig-readable.conf)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"

KC="${K3S_KC:-/etc/rancher/k3s/k3s.yaml}"
DROPIN="${K3S_KC_DROPIN:-/etc/systemd/system/k3s.service.d/40-kubeconfig-readable.conf}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

echo "k3s-kubeconfig-readable.sh  host=$(hostname)  user=$(id -un)  $(date '+%Y-%m-%d %H:%M:%S%z')"

if [ "$(id -u)" -eq 0 ]; then
  inconclusive "running as root — root reads anything, so this check cannot see the agent lanes' failure"
  finish
fi
if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
  inconclusive "kubectl not on PATH ($KUBECTL_BIN)"
  finish
fi

section "kubeconfig reachable by $(id -un)"
if [ ! -e "$KC" ]; then
  check 1 "kubeconfig is missing: $KC"
elif [ -r "$KC" ]; then
  check 0 "readable: $KC ($(stat -c '%U:%G %a' "$KC" 2>/dev/null))"
else
  check 1 "NOT readable by $(id -un): $KC ($(stat -c '%U:%G %a' "$KC" 2>/dev/null)) — k3s resets this to 0600 root:root on every start"
fi

section "kubeconfig usable"
OUT="$("$KUBECTL_BIN" --kubeconfig="$KC" get ns media -o name 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then
  check 0 "kubectl --kubeconfig=$KC get ns media (rc=0)"
  assert_nonempty "kubectl get ns media" "$OUT"
else
  check 1 "kubectl --kubeconfig=$KC get ns media failed rc=$RC: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-120)"
fi

section "durability across k3s restarts"
if [ -f "$DROPIN" ]; then
  check 0 "drop-in installed: $DROPIN"
  if grep -q 'chmod 0640' "$DROPIN" 2>/dev/null; then
    check 0 "drop-in re-applies group-read (chmod 0640) after each k3s start"
  else
    check 1 "drop-in present but no 'chmod 0640' in it: $(grep -c . "$DROPIN" 2>/dev/null) lines — it will not restore the mode"
  fi
else
  check 1 "drop-in missing: $DROPIN — the next k3s restart resets $KC to 0600 root:root and every kubectl lane goes dark again"
fi

finish
