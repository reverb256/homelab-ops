# GitOps coverage map — k3s fleet

_Snapshot: 2026-10-05 09:00 UTC · kanban `t_b10e4fb3` · k3s v1.37.0+k3s1 (nexus, forge, sentry-agent = control-plane; zephyr = cordoned agent)_

This is a point-in-time inventory: **every workload in the cluster vs every ArgoCD
Application**, and the disposition of everything that is not app-owned. Re-derive it
from live state before trusting it after a topology change — the commands are in
[Method](#method).

## Headline

| | |
|---|---|
| ArgoCD Applications | **112** — all `Synced`; 110 `Healthy`, 1 `Degraded`, 1 `Progressing` |
| GitOps source repos | 8 first-party + 3 upstream chart repos |
| Workloads (Deploy/StatefulSet/DaemonSet) | **125** — live check: 125 owned, 0 unowned |
| Sweep snapshot incl. CronJobs and live Jobs | **225**, of which **13** have no direct ArgoCD owner |
| Workloads with **no** direct owner | **13** — all accounted for below |
| Residual, genuinely hand-managed | **1** (`tigera-operator`, documented exception) |

The two stragglers that were a real risk — the kube-system device DaemonSets — were
adopted into GitOps on 2026-10-05 (see [Residual gaps](#residual-gaps)).

## Applications by source repo

| Applications | Repo |
|---|---|
| 51 | `reverb256/trading-k8s` |
| 33 | `reverb256/media-k8s` |
| 17 | `reverb256/mining-k8s` |
| 4 | `reverb256/sites-k8s` |
| 1 | `reverb256/activepieces-k8s` |
| 1 | `reverb256/astral-key` |
| 1 | `reverb256/helm-media-servarr` (chart source) |
| 1 | `maplespike/quill` |
| 3 | upstream charts — `charts.external-secrets.io`, `charts.longhorn.io`, `charts.jetstack.io` |

Two Applications are not `Healthy`: `site-agency-pipeline` (Degraded) and `sites-static`
(Progressing). Both are `Synced` — an app that is Synced but not Healthy is a manifest
ArgoCD applied that the cluster rejected. That is the failure mode to read first.

## The 13 workloads with no direct owner

| Count | What | Disposition |
|---|---|---|
| 2 | `kube-system/nvidia-device-plugin-daemonset`, `kube-system/generic-device-plugin` | **Adopted** 2026-10-05 (Application `device-plugins`) |
| 2 | `kube-system/coredns`, `kube-system/local-path-provisioner` | Accepted: k3s re-renders these from `/var/lib/rancher/k3s/server/manifests` on every start (`objectset.rio.cattle.io/*` addon labels) |
| 5 | `longhorn-system/` `longhorn-csi-plugin`, `csi-attacher`, `csi-provisioner`, `csi-resizer`, `csi-snapshotter` | Accepted: created at runtime by `longhorn-driver-deployer` (itself ArgoCD-managed via the `longhorn` app) |
| 3 | `tailscale/ts-activepieces-*`, `ts-jellyfin-*`, `ts-seerr-*` | Accepted: created at runtime by the Tailscale operator (`tailscale-operator` app) |
| 1 | `tigera-operator/tigera-operator` | Accepted, documented exception — see `helm/apps/calico-tigera.yaml` |

> **Adoption note.** `generic-device-plugin` was applied on 2026-10-05 by a concurrent
> card (`t_d89cdac0`, sentry VAAPI hardening) — work in flight, not an abandoned
> straggler. It still lived in **no repository**, so a node recreate would have lost it.
> It was captured verbatim (zero `kubectl diff`), so adoption changed nothing on the
> wire. Any further change to either DaemonSet must now go through
> `media-k8s/cluster/addons/device-plugins/`: the `device-plugins` app runs
> `selfHeal: true` and will revert a live-only edit.

Operator-created objects that **are** covered because ArgoCD owns their parent:
calico-system (5, from the `Installation` CR), monitoring vmstack (7, from the
VictoriaMetrics operator), longhorn `engine-image-*` + 2 CronJobs (3). Ephemeral Jobs
are owned too — each one is parented to a CronJob or a Helm release
(`activepieces-postgres-backup`, `daily-snapshot`, `quill-ingest-*`, the `trading-*`
CronJobs, ...); a spot check of 49 live Jobs found **zero** without an owner — and
ReplicaSets belong to their Deployments.

## The named stragglers — status

| Named in the sweep brief | Status |
|---|---|
| **quill** | Managed. App `quill` → `maplespike/quill` `charts/quill`, ns `maplespike` (api, mcp, portal, redis + ingest CronJobs, 27 resources) |
| **trading** | Managed. 51 Applications → `reverb256/trading-k8s`, ns `trading` |
| **MCP servers** | Managed. `arr-mcp`, `arrstack-mcp`, `jellyfin-mcp`, `qbittorrent-mcp` → app `media-stack`; `mcp-victoriametrics-victoria-metrics-mcp` → app `mcp-victoriametrics`; `trading-mcp` → app `trading-mcp`; `quill-mcp` → app `quill`; `voice-models` → app `voice-models` |
| **chatterbox** | Nothing to migrate. Namespace exists (17 d) with **0 workloads** and only `kube-root-ca.crt`. Leftover namespace. |
| **memlawb** | Nothing to migrate. **No k8s footprint at all** — no namespace, no workload matches fleet-wide. It is not a cluster workload. |
| **haven** | Not deployed to this cluster. `Work/Projects/haven-k8s` exists, but there is no `haven` namespace and no `haven` Application. The Cloudflare tunnel config still names `haven.reverb256.dev`; verify-fleet 9j guards that its target is a live ClusterIP. |

## Residual gaps

| Gap | Risk | Status |
|---|---|---|
| `tigera-operator` Deployment + Calico CRDs and RBAC | CNI bootstrap. Re-declaring from a partial manifest risks dropping fields the upstream install set. Only the `Installation` CR is GitOps-managed. | **Accepted** — documented at length in `helm/apps/calico-tigera.yaml`; the incident it was written for (krash3 placement) is gone since krash3 was removed from the cluster |
| k3s-bundled `coredns`, `local-path-provisioner` | None — k3s owns them | Accepted, out of scope by design |
| longhorn CSI components, Tailscale `ts-*` | None while their operators run | Accepted — operator-created at runtime |

There are no remaining hand-applied *application* workloads in a workload namespace.

## Guards (so this cannot silently regress)

The class of defect here — a workload no Application owns — was invisible to
verify-fleet 9h, which only asks whether every Application is Synced+Healthy.

- **Repository half** — `media-k8s` `tests/test_gitops_coverage.py`: fails when a
  directory under `cluster/addons/` has no Application applying it, when an Application
  points at a missing addon path, or when the `device-plugins` app stops owning both
  device DaemonSets.
- **Live half** — `media-k8s` `cluster/checks/gitops_coverage.py`, run from
  `verify-fleet.sh` §9y. Classifies every Deployment/StatefulSet/DaemonSet as owned
  (ArgoCD tracking id, `app.kubernetes.io/instance`, `ownerReferences`, k3s addon label,
  or an operator namespace) and fails on anything else. Fails closed. Unit-tested off
  synthetic fixtures in `tests/test_gitops_coverage_check.py`.

Measured live at the time of this snapshot: `total=125 owned=125 unowned=0`, rc 0.

## Method

```bash
K=/home/j_kro/.kube/config            # never export KUBECONFIG= — the shell scanner blocks it

# Applications, with source repo/path and sync/health
kubectl --kubeconfig=$K get applications.argoproj.io -A -o custom-columns=\
'NAME:.metadata.name,NS:.metadata.namespace,SYNC:.status.sync.status,HEALTH:.status.health.status,PATH:.spec.source.path,REPO:.spec.source.repoURL'

# Every workload, then resolve ownership: tracking-id annotation -> instance label ->
# app status.resources -> ownerReferences (walked up), and skip k3s addon / operator namespaces
kubectl --kubeconfig=$K get deployment,statefulset,daemonset,cronjob,job -A -o json
```

Note: ArgoCD in this cluster tracks resources with the
`argocd.argoproj.io/tracking-id` **annotation** (not the more common
`app.kubernetes.io/instance` label), and Apps whose `status.resources` list is
authoritative must still be consulted — an ownership check that only looks for the
instance label reports false gaps.
