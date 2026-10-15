# Pi-hole DNS failover — the LAN's DNS contract (2026-10-15)

Incident: 2026-10-14 14:15-14:55 CDT, kanban t_d47a5575. The LAN's DNS at
10.1.1.53 served nothing for 40 minutes. Root causes (two independent, both
fixed):

1. A lifecycle-only render diff made ArgoCD flip the pihole Deployment
   between two ReplicaSets; each flip was a Recreate rollout dragging one
   shared RWO Longhorn PVC across nodes (FailedAttachVolume = minutes per
   flip). Fixed in media-k8s PR #33: 2-replica StatefulSet, per-pod PVCs,
   RollingUpdate, required pod anti-affinity, PDB minAvailable 1. The
   postStart hook's presence is now checked by verify-fleet 9ad (Argo is
   blind to it — ignoreDifferences on the lifecycle field is what stops the
   flip-flop).
2. Every host pointed at Pi-hole with `FallbackDNS` for failover — but
   systemd-resolved NEVER uses FallbackDNS while any primary DNS= is set.
   A dead Pi-hole stalled every lookup. Fixed fleet-wide: the primaries
   themselves are now the failover.

## The contract

Every host resolves through, in order:

  10.1.1.53   pihole (MetalLB VIP on svc pihole-dns, filtering)
  10.1.1.100  unbound keepalived VIP (sentry/nexus unbound pair)
  10.1.1.120  nexus unbound direct
  -> then FallbackDNS 1.1.1.1 8.8.8.8 (public, true last resort)

A Pi-hole outage degrades the LAN to UNFILTERED DNS, never to no DNS.
Pods resolve via the kubelet resolv.conf -> pihole ClusterIP (see
scripts/apply-k3s-resolv-conf.sh for that layer).

## Where it lives (per host class)

| host    | main resolved.conf DNS= | 50-pihole drop-in              | NM per-link DNS |
|---------|-------------------------|--------------------------------|-----------------|
| forge   | (empty)                 | DNS triad + Fallback + ~.      | (none set)      |
| nexus   | (stripped; Domains=lan, DoTLS opportunistic kept) | same drop-in | (none set) |
| sentry  | triad (omarchy dns Custom) | Domains=~. + Fallback only | triad (omarchy-dns set_connection_dns) |
| zephyr  | triad (omarchy dns Custom) | Domains=~. + Fallback only | triad (omarchy-dns set_connection_dns) |

zephyr and sentry are Omarchy desktops: /usr/sbin/omarchy-dns owns the
resolved main file AND all NetworkManager DNS layers and rewrites them. Never
hand-edit /etc/systemd/resolved.conf or NM profiles there — run
`omarchy dns Custom` with `10.1.1.53 10.1.1.100 10.1.1.120`, then apply the
drop-in. A DNS= list in a drop-in fights the tool (main-file entries
accumulate AHEAD of drop-ins — measured).

## The MagicDNS trim (nexus + sentry)

tailscaled with CorpDNS=true registers tailscale0 with routing domains
"tigris-ule.ts.net lan ~." — the `~.` spreads ordinary queries across all
default-route links, so a fraction of lookups went to MagicDNS and BYPASSED
Pi-hole (canary flapped 0.0.0.0 / real-IP). The trim keeps ts.net + lan
(MagicDNS still answers tailnet names — unbound's public ts.net forwarder
NXDOMAINs them, so `accept-dns=false` would break tailnet resolution) and
drops the `~.` claim so the global triad owns default-route resolution.

Owned by `pihole-dns-trim.{service,timer}` (every 30s, idempotent, always
exit 0). A timer, not an ExecStartPost, because tailscaled re-asserts its
config on its own restart AND on every systemd-resolved restart.

## Apply

  scripts/apply-resolved-dropins.sh <host>   # idempotent, per host
  # zephyr/sentry main file + NM: `omarchy dns Custom` -> "10.1.1.53 10.1.1.100 10.1.1.120"

## Verify

  for h in forge nexus sentry zephyr; do
    ssh $h "resolvectl dns | head -1"            # Global: 10.1.1.53 10.1.1.100 10.1.1.120
    ssh $h "getent ahostsv4 doubleclick.net | head -1"   # 0.0.0.0 (filtered)
    ssh $h "getent ahostsv4 github.com | head -1"        # real IP
    ssh $h "resolvectl domain tailscale0"       # ts.net + lan, NO ~. (nexus/sentry)
  done
  drill @10.1.1.53 doubleclick.net               # 0.0.0.0 from anywhere on the LAN

## Measured recovery (2026-10-15, the drills in the task thread)

- Single pod delete (the realistic failure): ZERO failed probes in 180
  probes at 0.5s — the sibling kept serving, MetalLB moved the announce.
- BOTH pods deleted (full cold start): .53 dark from +3.6s; first answer
  ~8 min later (volume detach to a new node + Longhorn attach + the hook's
  120s circular-DNS wait + gravity rebuild on the 1.79M-domain DB). During
  that window hosts still resolved via unbound (E contract held). The
  kubelet/pod-DNS equivalent of the E contract (a secondary in the kubelet
  resolv.conf) is follow-up work — it needs per-host k3s restarts.
