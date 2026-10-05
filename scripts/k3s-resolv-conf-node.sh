#!/bin/bash
# k3s-resolv-conf-node.sh — run as root ON a k3s node. Called by
# scripts/apply-k3s-resolv-conf.sh; see there for why a k3s restart is involved.
#
# Installs:
#   /etc/rancher/k3s/resolv.conf                        (kubelet upstream for pods)
#   /etc/rancher/k3s/config.yaml.d/10-resolv-conf.yaml  (resolv-conf: -> that file)
# Refuses to install an upstream a pod must not use (loopback / link-local / 8.8.8.8),
# backs up any file it replaces, restarts k3s only when something changed, and
# prints the kubelet's live resolvConf as proof.
set -uo pipefail
RESOLV_SRC="${1:-/tmp/k3s-pod-resolv.conf}"
DROPIN_SRC="${2:-/tmp/k3s-10-resolv-conf.yaml}"
DEST_RESOLV=/etc/rancher/k3s/resolv.conf
DEST_DROPIN=/etc/rancher/k3s/config.yaml.d/10-resolv-conf.yaml
STAMP="$(date +%Y%m%d%H%M%S)"

if [ "$(id -u)" != 0 ]; then echo "must run as root" >&2; exit 1; fi
for f in "$RESOLV_SRC" "$DROPIN_SRC"; do
  [ -s "$f" ] || { echo "REFUSING: $f is missing or empty" >&2; exit 1; }
done

# ---- guard: an upstream that must never be used inside a pod -------------------
NS_ALL=$(awk '/^[[:space:]]*nameserver/{print $2}' "$RESOLV_SRC")
[ -n "$NS_ALL" ] || { echo "REFUSING: $RESOLV_SRC declares no nameserver" >&2; exit 1; }
BAD=$(printf '%s\n' "$NS_ALL" | grep -E '^(127\.|::1$|fe80:|ff0[0-9a-f]:|8\.8\.8\.8$|8\.8\.4\.4$|2001:4860:)' || true)
if [ -n "$BAD" ]; then
  echo "REFUSING: $RESOLV_SRC declares an upstream a pod must not use: $BAD" >&2
  exit 1
fi

install -d -m 755 /etc/rancher/k3s /etc/rancher/k3s/config.yaml.d
changed=0
for pair in "$RESOLV_SRC:$DEST_RESOLV" "$DROPIN_SRC:$DEST_DROPIN"; do
  src="${pair%%:*}"; dst="${pair#*:}"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    echo "unchanged: $dst"
    continue
  fi
  if [ -f "$dst" ]; then
    cp -a "$dst" "$dst.bak-$STAMP" && echo "backup:    $dst.bak-$STAMP"
  fi
  install -m 644 "$src" "$dst" && echo "installed: $dst"
  changed=1
done

# ---- restart only when a file actually changed ---------------------------------
if systemctl is-active --quiet k3s-agent; then UNIT=k3s-agent; else UNIT=k3s; fi
if [ "$changed" = 0 ]; then
  echo "no change -> not restarting $UNIT (idempotent)"
else
  echo "restarting $UNIT ..."
  systemctl restart "$UNIT"
  for i in $(seq 1 60); do systemctl is-active --quiet "$UNIT" && break; sleep 2; done
fi
systemctl show -p ActiveEnterTimestamp "$UNIT"

# ---- prove it ------------------------------------------------------------------
# The proof must not race the restart: k3s rewrites this file a moment AFTER the
# unit reports active (seen 2026-10-05: caught it still holding the previous start's
# value). Retry until it names the file we just installed.
KCFG=/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/00-k3s-defaults.conf
live=""
for i in $(seq 1 30); do
  live=$(sed -n 's/^resolvConf:[[:space:]]*//p' "$KCFG" 2>/dev/null | head -1)
  [ "$live" = "$DEST_RESOLV" ] && break
  sleep 2
done
echo "--- kubelet resolvConf: ${live:-NOT FOUND}"
[ "$live" = "$DEST_RESOLV" ] || { echo "WARNING: kubelet resolvConf is '${live:-unset}', expected $DEST_RESOLV" >&2; exit 1; }
echo "--- $DEST_RESOLV:"
awk '/^[[:space:]]*(nameserver|search|options)/{print}' "$DEST_RESOLV"
