# Fast tier: make the EVO 500 GB SSD do its stated job

**Goal:** Move the container-runtime working set onto `/data/fast` (`/dev/sdb`, Samsung 860 EVO 500 GB, currently **1 % used**) so k3s and Docker stop competing with the OS on the dm-crypt'd root NVMe — which is what `data-fast.mount` says the tier exists for — while leaving etcd on the NVMe.

**Architecture:** bind mounts for containerd's store and kubelet's pod dir (the fleet's established pattern — 14 config binds already run this way); Docker's own `data-root`; the local-path provisioner ConfigMap for new PVs with per-app migration for existing ones. No subvolumes on the tier: snapshotting container storage doubles its size for no recovery value.

**Tech stack:** k3s (embedded containerd), dockerd, local-path-provisioner, systemd mount units under `homelab-ops/omarchy/nexus`, btrfs on the EVO.

---

## Measured context (2026-09-23 13:45 CDT — the premise, confirmed by counter)

| Counter | `nvme0n1` (LUKS root) | `dm-0` (crypt) | `sdb` (EVO) | `sda`/`bcache0` (4 TB) |
|---|---|---|---|---|
| read | 102.8 MB/s | 102.8 | **0.00** | 1.02 |
| write | 22.6 MB/s | 22.6 | **0.04** | 1.23 |
| `%util` | 33–43 % | 36 % | **0.1 %** | **99.4 %** |
| `r/s` | 3253 | 3333 | 0 | 67.6 |
| `w_await` | 7.3 ms | **24.7 ms** | — | — |
| `aqu-sz` | 10.8 | 36.7 | 0 | 1.17 |

- The crypt layer **triples write latency at identical traffic** (7.3 → 24.7 ms). `data-fast.mount`'s stated premise is correct.
- The tier is doing **nothing**: 0 reads/s, 0 writes/s, 0.1 % busy.
- Container churn is thousands of small reads/s (`r_await` 0.62 ms, `q 68 KiB` average) — exactly the DRAM-less-SSD-behind-crypt workload the tier was bought for.

**What sits on the root that should not:**

| Path | Size | Move? |
|---|---|---|
| `/var/lib/rancher/k3s/agent` (containerd: snapshotter 65 G + content 20 G) | **85 G** | yes — phase 2 |
| `/var/lib/kubelet` (all in `pods/`) | 5.7 G | yes — phase 3 |
| `/var/lib/rancher/k3s/storage` (6 local-path PVs) | 4.8 G | yes — phase 4 |
| `/var/lib/docker` (buildkit 927 M + volumes 528 M) | 1.5 G | yes — phase 3 |
| `/var/lib/longhorn` | 705 M | optional |
| `/var/lib/rancher/k3s/server` (**etcd**) | 765 M | **NO — stays on NVMe** |

**EVO health:** 860 EVO, power-on 69,328 h (~7.9 y), 31.3 TB written, `Reallocated_Sector_Ct 0`, `discard=async` enabled. Old but not worn out (~10 % of endurance); its write load will rise with container churn.

**One live consumer today:** `gamarr` (PID 1739841) holds `/data/fast/gamarr/gamarr.db`, `-wal`, `-shm` open. Whatever else changes, that path must keep working.

**Not in scope, stated plainly:** `sda`/`bcache0` is at **99.4 % busy** serving 1 MB/s. That is the damaged 4 TB media volume and its load — this plan does not fix it, and no cache device would.

---

## Phase 0 — Pre-flight (read-only, no mutation)

**Task 0.1: Confirm the window and the quorum math.**
- Confirm `forge` and `sentry-agent` are `Ready` — nexus stopping k3s takes etcd from 3 voters to 2.
- Run: `sudo k3s kubectl get nodes` → expect all four `Ready`.
- Record `/healthz/etcd` before touching anything: `curl -sk https://127.0.0.1:6443/healthz/etcd`.

**Task 0.2: Capture baselines to the repo.**
- `df -hT / /data/fast`; `du -sh -x` of each path above; `sudo k3s crictl images | wc -l` (expect 119).
- `iostat -x 5 3` → keep the `dm-0` `w_await` and `%util` lines as the before-picture.
- Store under `homelab-ops/runbooks/nexus-storage-20260923/baseline-<date>.txt`.

**Task 0.3: Inventory what would be lost if the tier died tomorrow.**
- List each local-path PV and decide: *re-creatable* (metrics, caches) vs **must be backed up** (postgres, quill-api, haven-data). Anything in the second group gets a backup **before** it is moved, not after.

---

## Phase 1 — Layout on the tier

**Task 1.1: Create the target layout (directories, top-level subvol).**
```
sudo mkdir -p /data/fast/{k3s/containerd,kubelet,docker,pvs}
sudo chown -R root:root /data/fast/k3s /data/fast/kubelet /data/fast/docker /data/fast/pvs
```
Expected: `df -h /data/fast` still shows ~460 G free.

**Task 1.2: Prove the tier is fast enough to be worth it (fio or dd).**
```
sudo fio --name=t --filename=/data/fast/fio.test --size=2G --bs=4k --iodepth=16 --rw=randwrite --runtime=20 --time_based
```
Expected: 4 k random write far above the root's; record the number as the tier's claim. Delete `fio.test` after.

---

## Phase 2 — Containerd store (85 G, the reason this plan exists)

**Task 2.1: Write the bind mount unit (declarative, in-repo first).**
- Create `homelab-ops/omarchy/nexus/systemd/var-lib-rancher-k3s-agent-containerd.mount`:
```ini
[Unit]
Description=Containerd store on the fast tier
Documentation=https://github.com/reverb256/homelab-ops
DefaultDependencies=no
After=data-fast.mount
RequiresMountsFor=/data/fast
Before=k3s.service

[Mount]
What=/data/fast/k3s/containerd
Where=/var/lib/rancher/k3s/agent/containerd
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
```

**Task 2.2: Stop k3s, copy, mount, start.**
```
sudo systemctl stop k3s
sudo rsync -aHx --info=progress2 /var/lib/rancher/k3s/agent/containerd/ /data/fast/k3s/containerd/
sudo mv /var/lib/rancher/k3s/agent/containerd /var/lib/rancher/k3s/agent/containerd.pre-tier
sudo mkdir /var/lib/rancher/k3s/agent/containerd
sudo cp .../var-lib-rancher-k3s-agent-containerd.mount /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl start var-lib-rancher-k3s-agent-containerd.mount
sudo systemctl start k3s
```
Expected: mount shows in `findmnt /var/lib/rancher/k3s/agent/containerd`; `crictl images` still lists 119; all four nodes `Ready` within ~90 s.

**Task 2.3: Verify the IO actually moved.**
- `iostat -x 5 3` → `sdb` `w/s` and `%util` now non-zero; `dm-0` `w_await` materially below 24.7 ms.
- `du -sh -x /data/fast/k3s/containerd` ≈ 85 G.
- Do **not** delete `containerd.pre-tier` until Phase 6 acceptance.

---

## Phase 3 — kubelet pod dir and Docker root

**Task 3.1:** Same bind pattern for `/var/lib/kubelet` → `/data/fast/kubelet` (5.7 G); unit `var-lib-kubelet.mount`, `Before=k3s.service`.

**Task 3.2:** Docker: add `/etc/docker/daemon.json` → `{"data-root": "/data/fast/docker"}`, then `systemctl stop docker && rsync -aHx /var/lib/docker/ /data/fast/docker/ && systemctl start docker`.
- Verify: `docker info --format '{{.DockerRootDir}}'` → `/data/fast/docker`; containers still listed.
- Declarative: the `daemon.json` goes into `homelab-ops/omarchy/nexus/`.

---

## Phase 4 — local-path PVs (new → tier, existing → migrated per app)

**Task 4.1: New PVs.** Patch the provisioner ConfigMap `kube-system/local-path-config`:
```json
{"nodePathMap":[{"node":"DEFAULT_PATH_FOR_NON_LISTED_NODES","paths":["/data/fast/pvs"]}]}
```
If ArgoCD owns that manifest, change it in `trading-k8s`/`sites-k8s` git, not live.

**Task 4.2: Migrate the write-heavy existing PVs first** — `monitoring/vmsingle` (20 Gi, constant ingestion) and `monitoring/vlsingle` (10 Gi):
```
kubectl -n monitoring scale statefulset <vm> --replicas=0
rsync -aHx /var/lib/rancher/k3s/storage/<pvc-dir>/ /data/fast/pvs/<pvc-dir>/
kubectl patch pv <pv> -p '{"spec":{"hostPath":{"path":"/data/fast/pvs/<pvc-dir>"}}}'
kubectl -n monitoring scale statefulset <vm> --replicas=1
```
Expected: PVC stays `Bound`, target pods `Running`, series count continues (no data gap beyond the restart).

**Task 4.3:** Repeat per app for `activepieces` (postgres + redis), `maplespike/quill-api-data`, `haven/haven-data` — **one app per commit**, with a byte-count comparison before/after.

---

## Phase 5 — Optional: the write-heavy bits of `/data/nvme1`

Jellyfin transcode and `qbt-cache` are ephemeral and write-heavy — good tier candidates. Do not move `media-config` (binds) or `stampede-data` without checking its latency needs.

---

## Phase 6 — Acceptance, rollback rehearsal, record

**Acceptance (all must hold):**
1. `sdb` shows sustained non-zero write IO; `dm-0` `w_await` materially below the 24.7 ms baseline.
2. 4/4 nodes `Ready`; ArgoCD all apps `Synced`; 0 pods not `Running`/`Completed`.
3. All local-path PVCs `Bound`; each migrated app's data size matches its pre-move size.
4. `du -sh -x /data/fast/*` ≈ 97 G total; root free space grew by roughly the same.
5. `gamarr` still has its DB open and healthy (`lsof | grep gamarr`).

**Rollback (rehearse on Phase 3 before touching Phase 2):**
```
sudo systemctl stop k3s
sudo systemctl stop var-lib-rancher-k3s-agent-containerd.mount
sudo rmdir /var/lib/rancher/k3s/agent/containerd
sudo mv /var/lib/rancher/k3s/agent/containerd.pre-tier /var/lib/rancher/k3s/agent/containerd
sudo systemctl start k3s
```
Also delete the unit from `/etc/systemd/system` and remove it from the repo in the same commit.

**Record:** update `runbooks/nexus-storage-20260923/OWNERSHIP.md` with the layout, the numbers, and the fact that **the EVO's whole 466 G is the k3s/Docker tier** — which supersedes the other lane's 96 GiB-tier + 350 GiB-bcache-cache plan. Update `data-fast.mount`'s comment (it still describes sdb as bcache0's cache).

---

## Risks, tradeoffs, open questions

1. **nexus is a voting etcd member.** Stopping k3s drops etcd to 2/3 — survivable, but a second failure in that window loses quorum. Do it when forge and sentry are healthy; watch `/healthz/etcd` throughout.
2. **The window is a real nexus outage (~20–40 min)** for media, monitoring and trading pods. Trading is halted and the RHC mirror is fill-driven, so no fills occur during it — that makes this window unusually cheap, and it will not stay cheap once trading resumes.
3. **`kubectl drain` will block** on local-path pods pinned to nexus by nodeAffinity. Stop k3s directly instead; document why.
4. **The EVO is ~7.9 years old.** Its write load rises from here. Image data is re-creatable, but **PV data is not** — so PVs get a backup *before* the move (Phase 0.3), not a promise after.
5. **This fixes the root's contention, not the media HDD's 99.4 % busy.** That is the damaged volume; the decision there is replace vs accept, and it is a separate owner call.
6. **Alternative considered and rejected:** `--data-dir=/data/fast/k3s` would move everything in one flag, but it takes **etcd** with it, onto a SATA SSD older than the NVMe it would leave. Bind mounts keep etcd where its latency belongs.
7. **Open:** does anything else write heavily to root that this misses? Journald (605 M) is already isolated on the `@log` subvol; re-measure after Phase 2 rather than assume.


---

## RECONCILIATION (2026-09-23, added when this plan entered the repo)

**Two plans claim `/dev/sdb` (the EVO), and they cannot both have it.**

| Claimant | Allocation | Source |
|---|---|---|
| This plan | all 466 G = k3s + Docker working set (containerd 85 G, kubelet 5.7 G, docker 1.5 G, PVs) | `FAST-TIER-PLAN.md` |
| `bcache-cache-reattach-20260923` + `OWNERSHIP.md` P3 | ~350 G = write cache for `bcache0`, plus a ~96 GiB tier | `OWNERSHIP.md` P3 |

**Evidence bearing on the choice:**

1. `sdb` is **1.2 % used — 460 GiB idle today** while the crypt root sits at 71.7 % and pays
   **24.7 ms `w_await` vs 7.3 ms** at the crypt boundary for container churn (thousands of
   small reads/s). That cost is measured, present, and removable with idle capacity.
2. `sda`/`bcache0` is at **99.4 % busy serving 1.2 MB/s**, and the prune designed to relieve it is
   **blocked by hanging reads** — the stop condition in `OWNERSHIP.md` P1. A cache device in front
   of a volume whose failure mode is *hangs* does not fix hangs; it adds a second failure mode and
   can mask the first.
3. The 4 TB volume's SMART is clean but **both self-tests aborted at 90 %** — there is no completed
   baseline, so "it is fine, give it a cache" is not supported by evidence.

**Recommendation:** the EVO goes to the fast tier. The media volume's real decision is **replace vs
keep pruning**, which is an owner call about a device, not a cache-tuning exercise. P3 (cache
re-attach) stays gated on that decision rather than proceeding as if `sdb` were free.

**Ordering that does not conflict:** P1 (prune — relieves bcache0, needs no `sdb`) can proceed
independently. The fast tier needs a nexus k3s window (~20–40 min, etcd drops 3→2 voters; do it with
forge and sentry healthy and watch `/healthz/etcd`). The two are not mutually blocking.

**Ownership:** `OWNERSHIP.md` holds one owner per failure mode — this reconciliation is recorded
there too, so no future agent follows P3 into the collision.
