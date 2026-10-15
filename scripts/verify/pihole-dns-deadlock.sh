#!/usr/bin/env bash
# scripts/verify/pihole-dns-deadlock.sh
#
# Guards the cluster-DNS deadlock seen 2026-10-15 01:48-02:20Z (kanban: cluster DNS outage
# -> trading CronJobs failed with "Temporary failure in name resolution", image pulls and
# ExternalSecrets failed cluster-wide).
#
# Mechanism this exists for: Pi-hole's pod carries a postStart hook
# (configmap pihole-lists -> /usr/local/bin/import-lists.sh) that runs `pihole -g`
# (gravity). gravity needs to resolve blocklist hostnames, and every pod resolves through
# CoreDNS, which forwards to the pihole-dns ClusterIP. So after a k3s/containerd restart
# wave the pod deadlocks: FTL is up inside the container but the hook never returns, the
# pod stays ContainerCreating -> NotReady -> pihole-dns has no endpoints -> CoreDNS has no
# upstream -> gravity can never finish. It does NOT self-heal; the operator has to break it.
#
# What the watchdog must therefore assert, in order (a "clean" result on a partial run is
# worthless — see _lib.sh):
#   1. the pihole pod exists and is Ready
#   2. Service pihole-dns has endpoints (no endpoints == cluster-wide DNS outage)
#   3. a real name resolves through the pihole-dns ClusterIP
#   4. the specific wedged-hook state is named, not just "pod not ready"
#
# HOST: nexus (kubectl + dig). READ-ONLY: no apply/patch/exec/delete, writes nothing.
# Exit: 0 = serving, 1 = FAIL (DNS dead / wedged hook), 2 = INCONCLUSIVE (no input).
# Overrides so the gate can be proven to fire (and not to false-fire):
#   PI_NS(pihole) PI_LABEL(app.kubernetes.io/name=pihole) PI_SVC(pihole-dns)
#   PI_CLUSTERIP(10.43.77.126) PI_PROBE(registry-1.docker.io) PI_STUCK_S(300)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
: "${PI_NS:=pihole}"
: "${PI_LABEL:=app.kubernetes.io/name=pihole}"
: "${PI_SVC:=pihole-dns}"
: "${PI_CLUSTERIP:=10.43.77.126}"
: "${PI_PROBE:=registry-1.docker.io}"
: "${PI_CANARY:=doubleclick.net}"
: "${PI_STUCK_S:=300}"

command -v kubectl >/dev/null || { echo "INCONCLUSIVE: kubectl not found (run on nexus)"; exit 2; }
command -v dig >/dev/null    || { echo "INCONCLUSIVE: dig not found (run on nexus)"; exit 2; }

echo "verify/pihole-dns-deadlock.sh  host=$(hostname)  read-only"
echo "  ns=$PI_NS svc=$PI_SVC clusterip=$PI_CLUSTERIP probe=$PI_PROBE"
_hr

section "pihole pod"
pod_line=$(kubectl -n "$PI_NS" get pod -l "$PI_LABEL" --no-headers 2>/dev/null | head -1)
if ! assert_nonempty "kubectl get pod -l $PI_LABEL -n $PI_NS" "$pod_line"; then
  echo "   (namespace/labels moved? nothing else here can be evaluated)"
  finish
fi
note "$pod_line"
pod_name=$(awk '{print $1}' <<<"$pod_line")
ready=$(awk '{print $2}' <<<"$pod_line")
start=$(kubectl -n "$PI_NS" get pod "$pod_name" -o jsonpath='{.status.startTime}' 2>/dev/null)
age=0
if [[ -n "$start" ]]; then
  start_epoch=$(date -d "$start" +%s 2>/dev/null || echo 0)
  [[ "$start_epoch" -gt 0 ]] && age=$(( $(date +%s) - start_epoch ))
fi
check "$([[ "$ready" == "1/1" ]] && echo 0 || echo 1)" "pod $pod_name is Ready (got '$ready')"

# The wedge: sandbox/FTL alive but kubelet never finishes the start because the postStart
# gravity hook is blocked on the very DNS this pod is supposed to serve.
phase=$(kubectl -n "$PI_NS" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null)
waiting=$(kubectl -n "$PI_NS" get pod "$pod_name" \
          -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
case "$phase/$waiting" in
  Pending/ContainerCreating)
    if [[ "$age" -ge "$PI_STUCK_S" ]]; then
      echo "   [FAIL] wedged postStart hook: pod Pending/ContainerCreating for ${age}s"
      echo "          gravity (pihole -g) cannot resolve: CoreDNS -> $PI_SVC has no endpoints -> deadlock"
      echo "          break-glass: sudo k3s crictl exec <pihole-container> kill -TERM \$(pgrep -f 'gravity.sh')"
      echo "          then re-run: sudo k3s crictl exec <pihole-container> pihole -g"
      bump_rc 1
    else
      note "pod still starting (${age}s < ${PI_STUCK_S}s) — not yet a wedge"
    fi
    ;;
  *) check 0 "no Pending/ContainerCreating wedge (phase=$phase waiting=${waiting:-none})" ;;
esac

section "pihole-dns endpoints"
eps=$(kubectl -n "$PI_NS" get endpointslice -l "kubernetes.io/service-name=$PI_SVC" \
      -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null)
if assert_nonempty "endpointslices for $PI_SVC" "$eps"; then
  ready_eps=$(kubectl -n "$PI_NS" get endpointslice -l "kubernetes.io/service-name=$PI_SVC" \
              -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[*]}' 2>/dev/null)
  check "$([[ -n "${ready_eps// /}" ]] && echo 0 || echo 1)" \
        "at least one READY endpoint ($PI_SVC) — empty means cluster DNS is down"
  note "addresses: $eps  ready: ${ready_eps:-<none>}"
fi

section "resolution through $PI_CLUSTERIP"
# Only a Pi-hole signature counts as an answer: dig prints ";; no servers could be
# reached" on stdout, so a bare +short that is merely NON-EMPTY proves nothing (an
# earlier revision of this gate false-PASSed against a ClusterIP with no service).
dnsfilter() { grep -vE '^;' | grep -E "$1" | tail -1; }
canary=$(dig +short +time=3 +tries=1 @"$PI_CLUSTERIP" "$PI_CANARY" A 2>/dev/null | dnsfilter '^[0-9.]+$')
case "$canary" in
  0.0.0.0) check 0 "canary $PI_CANARY blocked (0.0.0.0) — answers are coming from Pi-hole" ;;
  "")      check 1 "canary $PI_CANARY got NO answer from $PI_CLUSTERIP — cluster DNS is dead" ;;
  *)       check 1 "canary $PI_CANARY resolved to $canary (not 0.0.0.0) — not Pi-hole answering, or blocklists empty" ;;
esac

ans=$(dig +short +time=3 +tries=1 @"$PI_CLUSTERIP" "$PI_PROBE" A 2>/dev/null | dnsfilter '^[0-9]{1,3}(\.[0-9]{1,3}){3}$')
check "$([[ -n "$ans" ]] && echo 0 || echo 1)" "dig @$PI_CLUSTERIP $PI_PROBE A -> '${ans:-<no answer>}'"
note "reproduce: dig +short @$PI_CLUSTERIP $PI_CANARY / @$PI_CLUSTERIP $PI_PROBE"

finish
