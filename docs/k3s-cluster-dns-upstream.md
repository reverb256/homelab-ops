# k3s cluster DNS upstream — one managed resolv.conf for every node

Status: **applied to sentry-agent and zephyr 2026-10-04; nexus and forge pending**
(see §5). Incident: kanban `t_02f7d489`, parent `t_53727458`.

Every number below was read from the live cluster or a node on 2026-10-04/05 CDT.
Nothing here is inferred.

---

## 1. The defect: each node picked its own DNS upstream, and no listing shows it

`pihole-dns` is a LoadBalancer with `externalTrafficPolicy: Local` and a single
endpoint (the pihole pod on sentry-agent). kube-proxy therefore installs, on every
node with no local pihole pod, a filter rule that DROPs traffic to the LB IP:

```
-A KUBE-EXTERNAL-SERVICES -d 10.1.1.53/32 -p udp -m udp --dport 53 -j DROP   /* pihole/pihole-dns:dns-udp has no local endpoints */
```

The FORWARD jump catches pod traffic, so **pods on nexus/forge/zephyr cannot reach
10.1.1.53 at all** (silent UDP drop, no RST). Measured 2026-10-05:

| probe | result |
|---|---|
| pod on nexus → 10.1.1.53:53 | 0/5 |
| pod on forge → 10.1.1.53:53 | 0/5 |
| pod on nexus/forge → ClusterIP 10.43.77.126:53 | 5/5 |
| forge HOST → 10.1.1.53:53 | works (hosts route L2 to the announcer) |

The kubelet's upstream for pods comes from its `resolvConf`, which k3s sets from
`--resolv-conf` (default: probe `/etc/resolv.conf`, then
`/run/systemd/resolve/resolv.conf`; if both hold loopback/multicast/link-local
nameservers, generate a stub with `8.8.8.8` + `2001:4860:4860::8888`). With nothing
pinned, the four nodes disagreed — read from
`/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/00-k3s-defaults.conf` on each node:

| node | kubelet resolvConf | pods/CoreDNS upstream | consequence |
|---|---|---|---|
| nexus | `/var/lib/rancher/k3s/agent/etc/resolv.conf` | `8.8.8.8` (k3s stub) | Pi-hole bypassed |
| sentry-agent | `/var/lib/rancher/k3s/agent/etc/resolv.conf` | `8.8.8.8` (k3s stub) | Pi-hole bypassed |
| forge | `/run/systemd/resolve/resolv.conf` | `10.1.1.53` | **DROPPED for pods** → SERVFAIL flood |
| zephyr | `/etc/resolv.conf` | `1.1.1.1` | Pi-hole bypassed |

Consequence, measured: both live CoreDNS replicas answered the blocked canary
`doubleclick.net` with the real address (`142.251.32.14`) instead of `0.0.0.0`
— i.e. **cluster-wide ad/tracker filtering was silently defeated for pods**, and
any replica that landed on forge SERVFAIL-flooded every cache miss (1.7k–12k/h on
2026-10-03) because its upstream is unreachable from a pod.

## 2. Decision

Pin **one** upstream in a **managed file** on every node:

```
/etc/rancher/k3s/resolv.conf                      -> nameserver 10.43.77.126
/etc/rancher/k3s/config.yaml.d/10-resolv-conf.yaml -> resolv-conf: /etc/rancher/k3s/resolv.conf
```

- `10.43.77.126` is the **pihole-dns ClusterIP**: kube-proxy DNATs it to the pod, so
  it works from a pod on every node (measured 5/5 on nexus, forge, sentry) and keeps
  Pi-hole filtering for cluster lookups.
- k3s **skips its viability check for a manually specified file**
  (docs.k3s.io/advanced), so the content is used verbatim and cannot drift with the
  host's own resolver state.
- `10.1.1.53` stays as it is. `externalTrafficPolicy=Local` there preserves client
  IPs for LAN clients; flipping it to `Cluster` is a **j_kro decision**, not a side
  effect of this file.
- The path does not collide with anything k3s writes: k3s's generated stub lives at
  `$data-dir/agent/etc/resolv.conf`, and k3s edits only its own
  `00-k3s-defaults.conf` in the kubelet config dir.

## 3. Artifacts (this repo)

| path | role |
|---|---|
| `omarchy/<host>/etc/rancher/k3s/resolv.conf` | the managed upstream (source of truth) |
| `omarchy/<host>/etc/rancher/k3s/config.yaml.d/10-resolv-conf.yaml` | wires `resolv-conf:` |
| `scripts/apply-k3s-resolv-conf.sh <host>` | applies to one host: upload, validate, back up, install, restart, prove |
| `scripts/k3s-resolv-conf-node.sh` | the on-node half of the applier (root) |
| `scripts/verify/k3s-resolv-conf.sh` | fleet verification: file, live kubelet path, and per-replica behaviour |

## 4. Why a k3s restart, and why it does not disturb workloads

The kubelet reads `resolvConf` once, at startup; k3s writes it into
`00-k3s-defaults.conf` when k3s starts. There is no reload.

**A k3s service restart does not restart running containers** — measured, not
assumed: sentry-agent restarted k3s at 2026-09-25 04:00 with the host up 11d17h,
and on 2026-10-04 21:17 a fresh `systemctl restart k3s` there left **57 of 60 pods
running straight across the restart** with identical UIDs and container
`startedAt` (including calico-node, pihole, coredns and activepieces). The same
check on zephyr's `k3s-agent` restart left all 4 miner containers
(`peakminer-zephyr-{3060ti,3090}`, `llama-zephyr-3090` ×2) with identical UIDs and
`startedAt` values. Containerd shims own the containers; k3s restarting does not
kill them.

Quorum: only one etcd voter (nexus, forge, sentry) may be restarted at a time —
2 of 3 must remain. **While forge is down, do not restart nexus or sentry**: that
would leave a single voter and take the cluster API down.

## 5. Rollout state (2026-10-04 21:2x CDT)

| host | files | kubelet resolvConf | verified |
|---|---|---|---|
| sentry-agent | installed 21:17 | `/etc/rancher/k3s/resolv.conf` | yes |
| zephyr | installed 21:20 | `/etc/rancher/k3s/resolv.conf` | yes (miners untouched) |
| nexus | **pending** | still k3s stub (`8.8.8.8`) | — |
| forge | **pending** | still `10.1.1.53` | — |

nexus is pending only because forge is offline (see below); with one voter down,
restarting nexus would break etcd quorum.

forge went unreachable at ~21:14 CDT 2026-10-04 (100% packet loss on LAN and
tailnet, kubelet last heartbeat 21:14:08) — the **third** occurrence of the
single-SSD control-plane stall documented in
`runbooks/forge-memory-and-single-ssd-2026-10-01.md`, which requires a hard power
cycle by j_kro (the 2026-10-01 occurrence cost 2h36m of downtime). It is not
related to this change: no file had been uploaded to forge before it went down,
and the last forge-restarting action was none.

Remaining steps once forge is back:

```bash
# 1. forge, then nexus (one at a time; check nodes in between)
scripts/apply-k3s-resolv-conf.sh forge
kubectl --kubeconfig=/home/j_kro/.kube/config get nodes
scripts/apply-k3s-resolv-conf.sh nexus
# 2. recreate the coredns pods so both replicas regenerate their /etc/resolv.conf
kubectl --kubeconfig=/home/j_kro/.kube/config -n kube-system delete pod -l k8s-app=kube-dns
# 3. verify
bash scripts/verify/k3s-resolv-conf.sh
```

## 6. Rollback (per host)

```bash
rm -f /etc/rancher/k3s/config.yaml.d/10-resolv-conf.yaml     # drop-in
systemctl restart k3s                                        # zephyr: k3s-agent
kubectl -n kube-system delete pod -l k8s-app=kube-dns
```

The kubelet then goes back to probing `/etc/resolv.conf` and
`/run/systemd/resolve/resolv.conf` on its own. The managed `resolv.conf` file may
be left in place — nothing reads it once the key is gone. A timestamped
`.bak-<stamp>` copy of every replaced file is written by the applier.

## 7. FAILURE -> TEST

`media-k8s` commit `23181ad` — `cluster/checks/verify-fleet.sh` **§9s**: every
node must load the managed path with the Pi-hole ClusterIP as its only nameserver,
and **every READY CoreDNS replica must answer the blocked canary as `0.0.0.0`/`::`**
(only Pi-hole does that; a public resolver answers the real address, one on the
DROPPed LB answers nothing). §9p only sees the SERVFAIL flood this causes; §9s
catches the cause. Measured pre-fix with this check: 2 FAIL (nexus path + upstream,
both replicas answering publicly). This repo's `scripts/verify/k3s-resolv-conf.sh`
is the interactive twin of the same two assertions.
