# Coordination note — nexus storage, 2026-09-23 13:0x CDT
Written by the CoS session (trading/homelab owner lane), not by this runbook's owner.
Read-only observations. No writes were made to /data/fast, /data/media, or /dev/sdb.

## Why this note exists
Two plans are now aimed at the same 500 GB SSD and they do not fit together:

- **This runbook:** split `/dev/sdb` into a 96 GiB `/data/fast` tier + ~350 GiB bcache
  cache device, then re-attach it as a **writearound read cache** for `/dev/bcache0`.
- **The /data/nvme1 offload (interrupted):** `rsync -aH --delete /data/nvme1/ /data/fast/nvme1-migrate/`
  is **stalled at 75 G of 161 G**. Its destination is the same tier this runbook shrinks to 96 GiB.
  **161 G does not fit in 96 GiB.** One of the two has to change.

Do not repartition sdb while `nvme1-migrate` holds 75 G unless that partial copy is
deliberately abandoned — the source `/data/nvme1` is intact, so abandoning it loses no data.

## Device truth measured 2026-09-23 (read-only)
| Device | Role now | State |
|---|---|---|
| `sda` ST4000VN008 (4 TB HDD) | backing device for `bcache0` → `/data/media` + `/data/shared` | 3.7 T, **88 % used / 452 G free** |
| `sdb` Samsung 860 EVO 500 GB | `/data/fast` (btrfs, 27 G used, 6 %) | healthy. **No bcache superblock** (`sb.magic: bad magic`) — reformatted since |
| `nvme0n1` WDC SN550 1 TB | LUKS → `/` **and** `/data/nvme1` | 71 % used / 270 G free; 10 % wear, 0 media errors |
| `nvme1n1` Kingston 240 GB | **unmounted, idle** | **96 % wear**, 338,309 error-log entries — retire, do not reuse |

## Corrections to the working assumptions in this runbook's premises
1. **No cache set is registered.** `/sys/block/bcache0/bcache/state` = `no cache`; `/sys/fs/bcache/`
   holds no cache set; mode is `writethrough`. So `bcache0` is running **uncached on the HDD right now** —
   re-attaching sdb would be restoring cache that is fully absent, not repairing a degraded one.
2. **The 3,959 `corruption_errs` are historical, not proven ongoing.** A scrub started
   Tue 2026-09-22 09:57 ran **5 h 19 m** and ended `aborted` with **`Error summary: no errors found`**.
   At 16.54 MiB/s that covers roughly 10 % of the 3.19 TiB, so it is not conclusive — but there is
   currently **no evidence of active corruption**, and the framing "the device is failing right now"
   is not supported by this reading. A full scrub needs a quiet box; do not start one while other
   lanes are running.
3. `_fast-hold-20260923` under `/data/nvme1` is **85 G**. If that is this runbook's G2 hold tree for a
   `/data/fast` that holds **27 G**, it is ~3× the source. Verify before G2 asserts byte-for-byte parity,
   or the gate will pass against the wrong object.

## Gate G1 needs a window nobody has taken
G1 stops every media workload, requires no process holds the tier, and suspends ArgoCD self-heal.
That window has not been scheduled, and the Jellyfin/*arr stack plus `cleanuparr` currently mount
`/data/fast`. Do not start G1 opportunistically: suspension of self-heal must be announced, because
during it a manual drift will not be reverted and ArgoCD will not tell anyone.

## Owner decisions outstanding (not this runbook's to make)
1. Where the 161 G of `/data/nvme1` (`stampede-data` 71 G, hold tree 85 G, `media-config` 5 G) is meant
   to live, given the tier shrinks to 96 GiB.
2. Whether the media prune (~600–634 GB of genuinely reclaimable duplicate/leftover files under
   `/data/media/downloads`) is authorised — that, not the cache, is what relieves the 88 %.
3. When the disruptive maintenance window for G1–G6 is acceptable.

## Update 13:2x — the cancelled migration was relaunched, twice, by a non-CoS actor
The `/data/nvme1` -> `/data/fast` migration was relaunched at **13:11:22** (detached rsync, PPID 1) and
again at **13:11:45** via a transient `systemd-run` unit `nvme1-evac3.service`
("nvme1 -> EVO throttled resync"). Both were minutes after the owner cancelled the migration.

- The CoS prune lane did **not** start them: its live transcript has **zero** `nvme1` mentions.
- They were stopped as a unit, then the detached survivors SIGKILLed. **0 remain**, unit inactive, `Restart=no`.
- **Nothing was lost.** `/data/nvme1` is intact at 165 G / 145,650 files on `/dev/mapper/root`;
  the destination held 78 G / 51,482 files.

**The migration is cancelled by owner decision, and it is not protection:** the source is the WDC SN550
at **10 % wear with 0 media errors**, and the worn Kingston (`nexus-cache`, 96 % wear, 338,309 error-log
entries) is **unmounted**. There is no data at risk that this copy protects. Re-running it will be
stopped again and recorded as a conflict.

Owner decision: **prune first, cache second.** The bcache re-attach (this runbook's G1-G6) executes after
the prune, in a declared window with ArgoCD self-heal suspension announced and restored. Ownership of
that sequence now sits with the CoS storage ledger at
`runbooks/nexus-storage-20260923/OWNERSHIP.md`, which also documents the 161 G vs 96 GiB conflict below.
