#!/bin/bash
# apply-k3s-resolv-conf.sh <host> [<host> ...]
#
# Install the managed kubelet resolv.conf (cluster DNS upstream) on one or more k3s
# hosts, then restart k3s on each so the kubelet picks it up. Idempotent: a host
# whose files already match is skipped, restart included.
#
# ONE HOST AT A TIME is the rule for applying this (kanban t_02f7d489). The script
# enforces a `kubectl get nodes`-visible gap by handling hosts sequentially, but it
# is on YOU to re-check node health between hosts when you pass several: etcd needs
# 2 of 3 members (nexus, forge, sentry) for quorum.
#
# Why a k3s restart is needed: the kubelet reads resolvConf once, at startup, and
# k3s only writes the value into
# /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/00-k3s-defaults.conf when k3s
# starts. No reload exists.
#
# Restarting a k3s service does NOT restart running containers (containerd shims
# keep them alive) — verified 2026-10-05 on this fleet: sentry-agent restarted k3s
# at 2026-09-25 04:00 with the host up 11d, and a 14d-old pod on it still showed
# its last container restart 11d earlier. That is why the miners are not disturbed
# by this script; confirm it per node anyway with
#   scripts/verify/k3s-resolv-conf.sh --before / --after
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE_SH="$ROOT/scripts/k3s-resolv-conf-node.sh"
[ -f "$NODE_SH" ] || { echo "missing $NODE_SH" >&2; exit 1; }
[ "$#" -ge 1 ] || { echo "usage: $0 <host> [<host> ...]" >&2; exit 1; }

for HOST in "$@"; do
  RESOLV="$ROOT/omarchy/$HOST/etc/rancher/k3s/resolv.conf"
  DROPIN="$ROOT/omarchy/$HOST/etc/rancher/k3s/config.yaml.d/10-resolv-conf.yaml"
  for f in "$RESOLV" "$DROPIN"; do
    [ -f "$f" ] || { echo "missing $f (no managed copy for host '$HOST')" >&2; exit 1; }
  done

  echo "== $HOST"
  # Upload the two managed files and the node routine to /tmp (no sudo needed to write /tmp).
  ssh -o ConnectTimeout=10 "$HOST" 'install -m 644 /dev/stdin /tmp/k3s-pod-resolv.conf' < "$RESOLV"
  ssh -o ConnectTimeout=10 "$HOST" 'install -m 644 /dev/stdin /tmp/k3s-10-resolv-conf.yaml' < "$DROPIN"
  ssh -o ConnectTimeout=10 "$HOST" 'install -m 755 /dev/stdin /tmp/k3s-resolv-conf-node.sh' < "$NODE_SH"

  # Apply on the node (root): validate, back up, install, restart if changed, prove.
  ssh -n -o ConnectTimeout=10 "$HOST" 'sudo -n /tmp/k3s-resolv-conf-node.sh'
done

echo
echo "Now re-check the cluster before touching the next host:"
echo "  kubectl --kubeconfig=/home/j_kro/.kube/config get nodes"
echo "  bash $ROOT/scripts/verify/k3s-resolv-conf.sh"
