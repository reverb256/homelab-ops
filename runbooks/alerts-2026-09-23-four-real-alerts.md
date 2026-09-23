# Four real alerts: root causes and dispositions (2026-09-23)

`Watchdog` is the by-design heartbeat and is out of scope. The other four were
measured from vmsingle (`http://10.43.33.250:8428`) and from the hosts
themselves. No alert rule was silenced, disabled, or deleted. One recording rule
was corrected (see D).

| alert | instance | verdict |
|---|---|---|
| `NodeDiskIOSaturation` | nexus `dm-0` | true positive; steady-state, structural cause, fix identified but not applied |
| `DiskSpaceLow` | nexus `/dev/bcache0` 87% | true positive; corrected reclaim path committed, awaiting approval |
| `SmartWearHigh` | nexus `nvme1n1` | true positive; device must be pulled, not hidden |
| `RecordingRulesNoData` | `192.168.115.219:8080` vmalert | false positive on a conditional rule; rule corrected |

---

## A. `NodeDiskIOSaturation` on nexus `dm-0`

**Identity.** `dm-0` = `/dev/mapper/root` (253:0), the LUKS2 container over
`nvme0n1p2`, formatted btrfs. It is not a data volume: it carries `/`,
`/var/log`, `/home`, `/data/nvme1` (the arr configs and stampede after the
09-22 storage move), every kubelet local PV, and containerd's image store and
container logs. `/data/media` and the other pools are on `bcache0`/`sdb` and do
not sit behind `dm-0`.

**Rule.** `rate(node_disk_io_time_weighted_seconds_total{device="dm-0"}[5m]) > 10`
for 15 m (severity warning).

**Measurement.** The metric is real, not an exporter artifact: node_exporter
reports 3,844,970 s for the counter while `/proc/diskstats` field 14 reads
3,845,203,155 ms local - the same number. Over six hours, sampled every 10 min,
the 5-minute rate ran **9.2 to 511 s/s and was above the threshold in all but 3
of 36 samples**. A local 60 s window measured 4,342 ms/s (avg queue depth 4.3),
matching `iostat`'s `aqu-sz 5.8` - so the counter is consistent with the device,
and the threshold is simply below this device's steady state.

**What writes hot.** `iostat -x 10s` on `dm-0`: 30% util, `aqu-sz` 5.8, and a
burst to 12,900 read IOPS at 221 MB/s with only 17 KB per request. `pidstat -d`
and `iotop -b` over the same window rank the writers:

| writer | rate |
|---|---|
| `k3s-server` | ~1.7 MB/s write |
| `containerd-shim` | ~0.7 MB/s write |
| victoria-metrics (`vmsingle` + `vlsingle` pods) | 1.6 + 1.5 MB/s write |
| `trading-lab` CronJob pods (2 concurrent) | ~1.5 MB/s each |
| `trading-daemon` | ~1.3 MB/s |
| `python -m stampede serve` | 0.5-1.4 MB/s |
| `systemd-journald` | ~0.2 MB/s |

There is **no single rogue writer**. The load is aggregate write-back from
containerd image unpack, journald, the VictoriaMetrics TSDB, the trading
CronJob fleet, and stampede, all landing on one LUKS device. The 09-22 incident
runbook already measured the churn source: 52 CronJobs, ~5,000 short-lived pods
a day, 187 pod starts in 19 minutes.

**Why it was not "fixed" by the 09-22 pass.** That pass moved the *threshold
pressure* off forge's etcd (slow-disk timeouts, journald cap, plocate IO class)
and left this alert live on nexus on purpose. On nexus the alert is accurate: the
device is genuinely that busy.

**Durable fix (identified, not applied).** `/data/fast` - `sdb`, a 466 GB
Samsung 860 EVO, btrfs, **1% used** - is an idle local SSD. Pointing containerd's
root (or k3s's `data-dir`) at it removes image unpack and container logs from the
LUKS root. Not done here because it restarts every pod on the node, which is an
operator decision, not a maintenance-window side effect.

**Non-content reclaim applied, with proof.** On the same device:

| action | before | after |
|---|---|---|
| `journalctl --vacuum-size=300M` | 995.8 MB journal | 264.6 MB (freed 731.2 MB) |
| remove dangling (`<none>:<none>`) container images | 121 images, 8 dangling | 118 images, **0 dangling** |
| `df -h /` | 620G used, 306G avail | **619G used, 307G avail** |

That is ~1 GiB on `dm-0`. It does **not** touch `bcache0`, so it does not clear
`DiskSpaceLow` - the two alerts are on different devices, which is worth stating
plainly because it is easy to conflate them.

---

## B. `DiskSpaceLow` on `/dev/bcache0` (nexus)

**Cause.** The pool is genuinely 87% full: 4,000,787,021,824 B total,
3,444,991,520,768 B used, 547,005,337,600 B (510 GiB) free. The consumers are
`@media` 1.74 TB, `@games` 979 GB, `@shared` 359 GB, `@backups` 272 GB and
`@home` 94 GB. The alert is correct.

**Corrected measurement of the reclaimable set.** The first manifest used
`st_size` (apparent size). btrfs reflinks and shared extents make that
misleading: a season pack reporting 70.9 GB occupies 14 GB, another reporting
67.9 GB occupies 1 GB. The manifest now records `st_blocks * 512` (`du -x`) as
`bytes`, with apparent size as a secondary column. Corrected figures:

- eligible: **94 items, 633.9 GB allocated** (1,008.0 GB apparent)
- `games` excluded: 117.1 GB allocated, hardlinked into the library
- 633.9 + 117.1 = **751.0 GB = `du -s -x /data/media/downloads`** - the
  accounting closes against the filesystem
- after deleting the eligible set: used 3.2 TiB -> **2.6 TiB**, used 87% -> **70%**

`DiskSpaceLow` clears at the 85% line, but nothing is deleted: the apply step is
dry-run by default and awaits j_kro's word. See
`scripts/media/README.md` for the proofs, the ownership boundary against
`cleanuparr`, and the failure cost.

**Refill prevention (committed).** `minimumFreeSpaceWhenImporting` was 100 MB
(the app default) on both sonarr and radarr - no protection at all on a 3.7 TB
pool. It is now declared as 51200 MB (50 GiB) in the media-configurator chart, so
imports stop before the volume can silently refill.

---

## C. `SmartWearHigh` on nexus `nvme1n1` (Kingston)

`smartctl -a /dev/nvme1n1`:

| field | value |
|---|---|
| model | KINGSTON SA1000M8240G |
| serial | 50026B728211ADC2 |
| firmware | E8FK11.R |
| overall health | **PASSED** (critical warning 0x00) |
| **percentage used** | **96%** |
| data units written | 155,795,752 (~79.7 TB) |
| data units read | 97,007,165 (~49.6 TB) |
| power-on hours | **32,465** |
| unsafe shutdowns | 403 |
| temperature | 32 C (warning 90 C / critical 94 C) |

**Verdict: a true positive, not noise.** The device is still installed and still
mounted - `ro` at `/mnt/old-nvme1`, subvolume `/`, holding the frozen pre-move
copy (97 GB used of 224 GB). "Idle" is not the same as "absent": the SMART wear
counter reads 96% because the hardware really is 96% worn, and a mount that
exists can be remounted read-write by anything. Silencing the alert would hide a
device that is one bad block away from losing its remaining contents.

**Recommendation, in order:**

1. Confirm nothing on `/mnt/old-nvme1` is the only copy of anything. The live
   arr configs and stampede moved to `/data/nvme1` (`@nvme1` on the root
   subvolume) on 09-22; this is the frozen source of that move.
2. If nothing is unique, unmount and **physically pull** the drive.
3. The alert clears by itself once the device is gone. Do not edit
   `node_smartmon_wear_percentage` thresholds or exclude the device - four
   403-unsafe-shutdowns and 79.7 TB on a consumer drive is exactly what the rule
   exists to catch.

---

## D. `RecordingRulesNoData` on vmalert

**Which rule, which target.** The firing alert's labels name the rule exactly:
`recording="count:up0"`, `group="kube-prometheus-general.rules"`,
`file="/etc/vmalert/rules-out/rules-src-0/rules.yaml"`, target
`192.168.115.219:8080` (the `vmalert-vmstack-victoria-metrics-k8s-stack` pod,
job `vmalert-vmstack-victoria-metrics-k8s-stack`).

**Why no data.** The chart ships
`count:up0 = count(up == 0) without(instance,pod,node)`. When every scrape target
is up, that selector matches nothing, so the rule emits **zero samples by
design** - which is the healthy state. Verified live: `count(up == 0)` returns
an empty vector while `count(up)` returns 52. vmalert's own check keys on
`sum(vmalert_recording_rules_last_evaluation_samples) without(id) < 1`, so it
cannot distinguish "correctly empty" from "broken", and fired permanently for
this one rule. Its sibling `count:up1` produced 39 samples and never alerted.

**Correction (committed, nothing removed).** The upstream expression is disabled
under `defaultRules.groups.kube-prometheus-general.rules.rules.count:up0`, and
the identical record is re-owned in `extraRules` as
`count(up == 0) without(instance, pod, node) or vector(0)` (group
`homelab-count-up0`). Consumers of `count:up0` still get the metric - now
reporting 0 instead of being absent - the failure mode still has an owner, and
every other rule keeps the no-data check in full. `helm template` confirms the
override renders as intended.

---

## E. Adjacent findings from this pass

**profilarr red streak - a detector fault, not a dead stack.** CronIncidents for
job `5f534c9b54e4` (`media-mcp-health`) show `FAIL profilarr -> 000` from
07:02 to 10:39 (`error_sig b407b280f14b`) and a five-service failure from 12:12
to **12:43** (`d331d27700b5`) - both auto-closed at 13:44. Root cause: the probe
targeted retired bare-nexus host ports (`100.76.105.73:<hostport>`) after the
stack moved to k3s ClusterIPs, so every target returned `000` and the check was
red for reasons unrelated to the services. The script now resolves ClusterIPs at
run time; a direct run is clean (profilarr -> HTTP 303, exit 0).

**qBittorrent "stale credential" - also a detector fault.** The reclaim dry-run
reported `login rejected` while the credential was valid. qBittorrent 5.x
answers **HTTP 204 with an empty body** on a successful login (older builds
return `Ok.`), and the client code tested the body. Both sonarr and radarr hold
the same username and a 5-character password, and the qBittorrent log shows
successful WebUI logins from their node every minute. No media-stack auth defect.

**quill ingest - green runs that persist nothing.** The `quill-api` ingest ledger
reports `failures=0` for five modules while `records=0`:
`committees` (3 runs), `corporate`, `gazette`, `influence`, `oversight`. Job logs
name three distinct causes:

- `gazette`: `HTTP 404` on both feed URLs
  (`gazette.gc.ca/rp-pr/p1/index.rss`, `p2/index.rss`) - the feed paths moved,
  `recordsFound=0`.
- `oversight`: `lobbycanada.gc.ca 403` (non-transient), and OAG reports
  `reportsFound=156, reportsIngested=0, errors=[]` - found everything, stored
  nothing, and reported no error. This is the exact silent-failure shape.
- `committees`: `meetingsFound=41, meetingsIngested=0` with per-meeting errors
  such as `Could not find XML export link in evidence HTM...` - the scrape
  selector drifted.

Smallest next actions: (1) fix the `gazette` feed URLs; (2) update the
`committees` XML-export selector; (3) treat `lobbycanada.gc.ca` 403 as a
non-transient source failure rather than a silent zero; and (4) in the quill
ingest ledger, count `recordsFound > 0 and recordsIngested == 0` as a **failure**
rather than a success - that single change converts all three cases from
invisible to alerting.

**homelab-ops drift - a new detection path (`scripts/verify/drift-check.sh`).**
No ArgoCD Application owns host state: `omarchy/<host>/` is delivered by each
host's own `apply.sh`. The new check hashes every committed file against its
installed counterpart and is **detection only - it has no apply mode**. First
run: **63 files checked, 13 drifted, 2 missing, 1 host unreachable**
(`oracle-vps`). Examples:

- missing on nexus: `/usr/local/bin/alertmanager-mcp.sh`,
  `/etc/ssh/sshd_config.d/10-hardening.conf`
- drifted on nexus: `btrfs-scrub.service`, `haven-backup.service`,
  `garage.service.d/override.conf`, `99-agent-tmp-guard.conf`, and the
  `data-{backups,hermes,media,models,oldhome,pi,shared}.mount` units
- drifted on sentry: `/usr/local/bin/oracle-idle-watch`

An unreachable host reports FINDING, never OK - unknown is not "in sync". The
check is wired into the sweep as section D9.
