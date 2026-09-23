# Rename k3s node `sentry-agent` → `sentry` — plan, blockers, window

**Status: PREPARED, NOT EXECUTED** (2026-09-23). Nothing in this runbook has been applied.

## Why it is a maintenance window, not an operation

The rename itself is mechanical: delete the Node object, stop/start k3s with a new
`--node-name`, let it re-register and re-create the etcd member. What makes it a window is
what is pinned to the old name. Verified live on 2026-09-23:

| Blocker | Count | Why it breaks the rename |
|---|---|---|
| `ArgoCD app cluster-nodes` manages `Node/sentry-agent` | 1 | `selfHeal: true` (prune false) — deleting the node while the Helm value still says `sentry-agent` makes Argo recreate it |
| Pods pinned by `spec.nodeName=sentry-agent` (non-DaemonSet) | **37** | with the node gone their nodeName matches nothing: they cannot be scheduled at all |
| local-path PVs whose `nodeAffinity` is `sentry-agent` | 2 | `MutablePVNodeAffinity` is **disabled** (`stage=ALPHA`, value 0) → the affinity cannot be edited; the PVs can never follow |

The 37 pinned pods are not edge cases — they are **coredns, pihole, cloudflared,
local-path-provisioner, metrics-server, calico-kube-controllers, calico-typha, metallb
controller, vmalert/vmauth/kube-state-metrics, longhorn's CSI controllers + ui,
nginx-rp, content-site, sites-static, tigera-operator, the tailscale operator + 3
`ts-*` StatefulSets, and the activepieces stack**. DaemonSet pods (9 more) are exempt:
they follow the node via their controller.

The 2 PVs are `activepieces-postgres-data` (8Gi) and `activepieces-redis-data` (1Gi) —
**live data**, host-local by construction. They cannot migrate; the stack has to be
re-created on the renamed node and restored.

## Related defect found while preparing (fix it in the same window)

`/etc/rancher/k3s/config.yaml` carries `etcd-arg: [heartbeat-interval=250,
election-timeout=2500]`, documented with measurements as the remedy for slow-fsync
leadership loss — **and k3s does not apply it**:

```
k3s etcd-snapshot save ...  level=warning msg="Unknown flag --etcd-arg found in config.yaml, skipping"
forge: "starting an etcd server" ... "heartbeat-interval":"500ms","election-timeout":"5s"   <- etcd defaults
```

So on forge — the host with the documented slow-fsync NotReady history — etcd has been
running defaults the whole time. Doing the rename on top of untuned etcd is the wrong
order: fix the tuning first, verify the intervals in the startup log, then rename.
The reliable mechanism is the `--etcd-arg=` flag on the unit's ExecStart, not the config key.

## Also undeclared

Sentry's `/etc/systemd/system/k3s.service` is **not in this repo** (hand-managed, with five
sibling copies: `.backup`, `.bak`, `.bak-contfix`, `.bak-monitoring-20260917`) and a
`.d/20-restart-always.conf` drop-in. The rename changes `--node-name` in it, so it must be
declared here first, with the flag in exactly one place.

## Sequence (one window, quiet, nexus+forge healthy)

1. **Pre-flight**: 3 nodes Ready; `/readyz?verbose` OK; etcd has a leader; no slow-fsync
   warnings in the last 30 min; `k3s etcd-snapshot save --name pre-rename-sentry` (rehearsed
   — works).
2. **Declare + apply the etcd tuning** via `--etcd-arg` on each unit; roll **one host at a
   time**, verifying quorum and `/healthz/etcd` between hosts; confirm the intervals in the
   etcd startup log.
3. **Repo changes, then sync**: `homelab-ops/omarchy/sentry` unit → `--node-name=sentry`;
   `media-k8s/helm/values/cluster-nodes.yaml:44` → `name: sentry`; the 37 pinned workloads'
   `nodeName` → `sentry`. Commit, push, let Argo apply (an orphan `Node/sentry` object before
   the kubelet owns it is cosmetic; `prune: false` means `sentry-agent` is not deleted for us).
4. **Re-create activepieces' state**: fresh local-path PVs on the renamed node; restore
   postgres + redis from the nightly backup (`activepieces-backup`, 04:35).
5. **The rename**: stop k3s on sentry; `kubectl delete node sentry-agent` (the managed-etcd
   controller removes member `sentry-agent-9cebaac4`); edit the unit; move
   `server/db` aside (keep `server/token`); start k3s; confirm it rejoins as `sentry`.
6. **Verify**: `kubectl get nodes` shows `sentry`; the node-name annotation carries the new
   uuid; `EtcdIsVoter=True`; 3 members; the 37 pods are Running on `sentry`; coredns, pihole,
   cloudflared and the CSI controllers are healthy; activepieces serves.

## Risk and rollback

- **Quorum 2/2 during step 5** — zero fault tolerance, and forge has a slow-fsync history.
  This is why the tuning (step 2) comes first.
- Rollback: revert `--node-name` and restart — it rejoins as a **fresh** member; restoring the
  old `server/db` is **not** valid once the member was removed. Quorum loss → `k3s server
  --cluster-reset --cluster-reset-restore-path=<zip>`, then wipe+rejoin the others.
- Node stuck Terminating: fix etcd first; stripping the wrangler finalizers while the member
  still exists orphans a voter.
- No reboot is required at any step, so no console passphrase is involved.

## Do not start this window if

forge or nexus is flaky, a backup/scrub is running on the same host, or the activepieces
backup from the previous night did not verify.
