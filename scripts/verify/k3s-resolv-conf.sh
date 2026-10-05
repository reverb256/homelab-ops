#!/bin/bash
# k3s-resolv-conf.sh — verify the managed kubelet resolv.conf is in force fleet-wide.
#
# Encodes the incident this exists for (kanban t_02f7d489 / t_53727458): each node's
# kubelet used a DIFFERENT upstream (8.8.8.8 stub, the dropped 10.1.1.53 LB, or
# 1.1.1.1), so CoreDNS replicas silently bypassed Pi-hole and any replica that landed
# on forge SERVFAIL-flooded. This checks the files AND the behaviour.
#
# Needs ssh to nexus/forge/sentry/zephyr, kubectl, and dig. zephyr has no dig, so run
# this from nexus or any host that has it, e.g.:
#   bash scripts/verify/k3s-resolv-conf.sh
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-/home/j_kro/.kube/config}"
EXPECT_NS="${EXPECT_NS:-10.43.77.126}"     # pihole-dns ClusterIP (reachable from pods)
EXPECT_PATH="${EXPECT_PATH:-/etc/rancher/k3s/resolv.conf}"
CANARY="${CANARY:-doubleclick.net}"        # Pi-hole blocks this -> 0.0.0.0 from Pi-hole
HOSTS="nexus forge sentry zephyr"
PASS=0; FAIL=0
ok(){ printf 'PASS  %-52s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
no(){ printf 'FAIL  %-52s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

command -v dig >/dev/null || { echo "dig not found - run this from a host that has it (nexus)"; exit 2; }

# -n on every ssh: with `bash -s < file` the script arrives on stdin, and an ssh
# child would otherwise consume the rest of it (seen as a silently truncated run).
SSH="ssh -n -o ConnectTimeout=6 -o BatchMode=yes"

# 1. Every node declares the drop-in and the kubelet actually uses that path.
for h in $HOSTS; do
  drop=$($SSH "$h" \
    "grep -h '^resolv-conf:' /etc/rancher/k3s/config.yaml.d/*.yaml 2>/dev/null | head -1" 2>/dev/null || true)
  case "$drop" in
    *"$EXPECT_PATH") ok "$h declares resolv-conf" "$drop";;
    "")              no "$h declares resolv-conf" "no config.yaml.d/*.yaml drop-in found";;
    *)               no "$h declares resolv-conf" "got '$drop' want '$EXPECT_PATH'";;
  esac
  live=$($SSH "$h" \
    "sudo -n grep -E '^resolvConf:' /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/00-k3s-defaults.conf 2>/dev/null | awk '{print \$2}'" 2>/dev/null || true)
  case "$live" in
    "$EXPECT_PATH") ok "$h kubelet resolvConf" "$live";;
    "")             no "$h kubelet resolvConf" "unreadable / not set";;
    *)              no "$h kubelet resolvConf" "got '$live' want '$EXPECT_PATH'";;
  esac
  ns=$($SSH "$h" \
    "awk '/^[[:space:]]*nameserver/{print \$2}' $EXPECT_PATH 2>/dev/null | tr '\n' ' '" 2>/dev/null || true)
  case "$(echo $ns)" in
    "$EXPECT_NS") ok "$h resolv.conf upstream" "$EXPECT_NS";;
    *)            no "$h resolv.conf upstream" "${ns:-missing} (want $EXPECT_NS)";;
  esac
done

# 2. Behaviour: every READY CoreDNS replica must answer the canary the way Pi-hole
#    does (0.0.0.0/:: = blocked). A public answer means the replica forwards to a
#    public resolver instead of Pi-hole; no answer means its upstream is unreachable
#    (this is exactly the forge/10.1.1.53 drop).
IPS=$(kubectl -n kube-system get pods -l k8s-app=kube-dns \
        -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.status.podIP} {.metadata.name}{"\n"}{end}' 2>/dev/null || true)
[ -n "$IPS" ] || no "coredns replicas present" "kubectl found none"
while read -r ip name; do
  [ -n "${ip:-}" ] || continue
  out=$(dig +short +time=3 +tries=1 "@$ip" "$CANARY" 2>/dev/null | head -1)
  case "$out" in
    0.0.0.0|::) ok "replica $name forwards to Pi-hole" "canary blocked ($out)";;
    "")         no "replica $name forwards to Pi-hole" "no answer for $CANARY (upstream unreachable?)";;
    *)          no "replica $name forwards to Pi-hole" "$CANARY -> $out (public resolver, Pi-hole bypassed)";;
  esac
done <<< "$IPS"

# 3. Cluster DNS still resolves through kube-dns.
out=$(dig +short +time=3 +tries=1 @10.43.0.10 github.com 2>/dev/null | head -1)
[ -n "$out" ] && ok "kube-dns ClusterIP answers" "$out" || no "kube-dns ClusterIP answers" "no answer"

echo
echo "k3s-resolv-conf: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
