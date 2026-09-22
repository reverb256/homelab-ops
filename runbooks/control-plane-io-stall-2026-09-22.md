# Control-plane I/O stall: forge etcd disk saturation (2026-09-22)

Status: mitigated 2026-09-22. Residual risk documented at the bottom.

## Symptom

`forge` went `Ready=Unknown` from **18:09Z to 18:15Z**. etcd logged
`slow fdatasync took 16.9s` and `timed out sending read state`. No evictions, no
new pod restarts after recovery, but `NodeDiskIOSaturation` (nexus), `DiskSpaceLow`
(bcache0 88%) and `BtrfsCorruptionGrowing` stayed live.

## Root cause, with numbers

forge's etcd WAL lives on `/dev/mapper/root` (LUKS on `sdb2`, a single 240 GB SSD)
and shares that device with containerd (24 GB) and `/var/log/journal` (2.1 GB).
nexus's member shares `nvme0n1p2` with all pod storage.

| time (UTC) | observation | source |
|---|---|---|
| 18:02 | `etcdHighCommitDurations` fires on forge (192.168.0.130:2381), p99 3.36 s | vmalert |
| 18:04 → 18:09 | forge `sdb` util 11% → **99.8%**, `io_time_weighted` spike **820** | node_exporter |
| 18:05 | nexus `nvme0n1` util 12% → 68%, `NodeDiskIOSaturation` active from 18:08 | node_exporter |
| 18:06 → 18:10 | forge `etcd_disk_wal_fsync_duration_seconds{quantile=0.99}` 2.20 → 3.18 → 3.60 → 4.71 → **7.52 s** (baseline 0.11–0.15 s) | kube-etcd |
| 18:07–18:09 | journal: repeated `slow fdatasync` 2.0–11.0 s, `waiting for ReadIndex response took too long` | k3s |
| 18:08:44 | k3s begins a clean shutdown (`graph_builder Stopping`) | journal |
| 18:09:00 | `k3s.service: Main process exited, code=exited, status=1/FAILURE` | systemd |
| 18:09:11 | `Restart=always` brings k3s back; bootstrap reconcile; 18:12:35 gRPC SERVING | journal |
| 18:09:26 | `Node forge status is now: NodeNotReady`; taint eviction cancelled at 18:13:25 | events |
| ~18:15 | node Ready again | kubectl |

**What generated the load:** a cluster-wide container-churn burst, not a single job.
Events since 18:00Z: **187 Pod Pulled/Created/Started, 146 Job SuccessfulCreate,
86 CronJob SuccessfulCreate** in 19 minutes, immediately after a Longhorn/CSI
rollout (longhorn-manager, instance-manager, csi-attacher/provisioner/resizer/
snapshotter replaced 17:50–18:02Z; all pods on forge ~18–30 min old). Each start
writes image layers and streams container logs through journald onto the node's
single root device. Pod-level `container_fs_writes_bytes_total` was only
~0.1–0.25 MB/s per pod, so the cost is the *start churn* (containerd unpack +
journald), which is host-level and not attributable to one pod.

**Secondary, ongoing:** nexus `sda`/`bcache0` (the 3.6 TB `@media/@shared/@backups`
pool) sits at **100% util all day** with r_await 16–21 ms for only ~2 MB/s of
16 KiB random reads — the signature of the pool's known dead extents hanging reads
(`btrfs_opendir` / `read_extent_buffer_pages` D-state finds, `du` on
`/data/games`, `/data/oldhome/j_kro`, `/data/backups` never returns,
`corruption_errs 3959` and growing). That pool is not etcd's device, so it did not
cause this outage, but it keeps `NodeDiskIOSaturation` live and makes any
filesystem-wide scan (`find /`, `du`, scrub, backup tar) a whole-host stall risk.

## Changes applied (declarative, in this repo)

| change | file | why |
|---|---|---|
| etcd slow-disk timeouts on all 3 members | `omarchy/*/etc/rancher/k3s/config.yaml` | `heartbeat-interval=250ms`, `election-timeout=2.5s` (was 100 ms/1 s). Defaults assume sub-100 ms fsync; forge's hit 7.5 s, costing the member its raft read-index and crashing k3s. Upstream etcd tuning for slow storage. |
| journald size + write-behaviour cap | `omarchy/*/etc/systemd/journald.conf.d/10-homelab-journal.conf` | `/var/log/journal` shared etcd's device: 2.1 GB → 952 MB after the cap. Fewer, larger flushes; bounded burst absorption. |
| journald / plocate I/O class | `omarchy/*/etc/systemd/system/{systemd-journald,plocate-updatedb}.service.d/10-homelab-io.conf` | Both are pure bookkeeping/index work on the etcd device. `IOSchedulingClass=idle`, low nice. |
| scrub is now backup-aware and cheaper | `omarchy/nexus/usr/local/bin/btrfs-scrub` | Rate cap 100M → **24M**; new guards (see below). |

### Scrub guards (bcache0)

The old wrapper set a 100M cap and started a scrub at 03:30 day 1–7. A 3.2 TiB scrub
at the measured 16.5 MiB/s runs for **days**, so "start before the 04:07 backup
window" cannot avoid overlap: memlawb 04:07, haven 04:22, activepieces 04:33,
media-config 04:36, stampede 04:47. The new wrapper therefore:

1. **Refuses to start** while any `*-backup.service` is active/activating, while
   `/proc/pressure/io` `full avg60` > 30%, or with < 5% free space.
2. **Pauses** the running scrub (`btrfs scrub pause`) whenever a backup unit becomes
   active and **resumes** it when the backup finishes — so the pool is never scrubbed
   and backed up at the same time.
3. `--check` prints the decision without touching the pool.

Verified:
```
# while a (transient) backup unit ran:
DECISION=skip reason=backup-running
# idle:
DECISION=start rate=24M psi_full_avg60=8.50 used=88%
```

## Verification after the change

- All three members boot with the new timings (etcd embed startup log):
  `"heartbeat-interval":"250ms","election-timeout":"2.5s"` — forge, nexus, sentry.
- Rolling restart (sentry → forge → nexus), `kubectl get --raw /healthz/etcd` = `ok`,
  all 4 nodes `Ready` after each step. `NRestarts=0`.
- forge fsync p99 back to 0.10–0.25 s; no `slow fdatasync` after restart.
- journald on each host: `IOSchedulingClass=3` (idle), journal 2.1 GB → ~1 GB.

## Residual risk / decisions (not executed)

1. **etcd and containerd still share one device on forge.** etcd's WAL is 602 MB
   next to 24 GB of container storage on the same LUKS SSD. The durable fix is to
   put containerd's root (or k3s's data-dir) on the second physical disk
   (`sda`, 223 GB, `/mnt/oldforge`) via a k3s containerd config template. Not done:
   it restarts every pod on the node.
2. **The churn source is the CronJob fleet.** ~10 pod starts/minute cluster-wide
   (trading-*, quill-ingest-*) plus Longhorn rollouts. Reducing that cadence is a
   business decision in `trading-k8s`.
3. **bcache0 at 88%.** Consumers (btrfs qgroup, referenced): `@media` 1.74 TB,
   `@games` 979 GB, `@shared` 359 GB, `@backups` 272 GB, `@home` 93.8 GB,
   `@containers` 28 GB. Free space cannot be restored without a destructive
   decision — see below. `DiskSpaceLow` therefore stays live and is *expected*.
4. **bcache0 dead extents / growing corruption (3959 csum errors).** Scrub can only
   detect (Data,single cannot repair). Until files are relocated off the damaged
   regions, whole-filesystem scans (including agent `find /`) will keep hanging
   reads and pinning the pool at 100% util.

### Decisions needing the operator (evidence attached, nothing deleted)

- `/data/media/movies/.trash-pool` — **27.7 GB**, 14 entries. Media already parked
  for deletion by the reclamation workflow. Deleting frees 27.7 GB (88% → ~87%);
  it does not clear `DiskSpaceLow`.
- `@shared/.snapshots/pre-garage-repair-20260920-191935` — **26.7 GB exclusive**
  (btrfs qgroup 0/278). Pre-repair recovery snapshot; delete only when no longer
  needed.
- `/data/shared/garage/data.old-20260920` + `meta.broken-20260920` /
  `meta.corrupt-20260920` — pre-repair Garage S3 data. Garage's live `data_dir` is
  `/data/shared/garage/data`. **This holds backup objects — do not delete without
  first proving the objects exist in the live dir** (`RECOVERY-NOTES-20260920.md`
  sits next to it).
- `/data/games` (979 GB) and `/data/oldhome` (93.8 GB) — largest remaining
  consumers; both are operator property decisions.
