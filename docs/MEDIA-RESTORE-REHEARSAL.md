# Media / library restore rehearsal — 2026-09-23 (nexus)

The trading stack got a full recovery drill on 2026-09-23 (keys restore in 1,254 ms,
archives proven credential-free — see `docs/RECOVERY-DRILL-2026-09-23.md`). The
largest data asset in the homelab had never had one. This is that drill: what is
actually protected, what a restore really costs (measured), what would be lost
forever, and how long a re-acquire takes.

Everything below was measured on **nexus** on 2026-09-23, read-only against live
data, with every traversal throttled (`ionice -c3 nice -n 19`), bounded (`timeout`)
and filesystem-scoped (`-x`/`-xdev`). The re-runnable form is
`scripts/verify/media_restore_drill.sh` — run it, do not trust this document.

## TL;DR

| Question | Answer |
| --- | --- |
| Is the library backed up? | **No.** Nothing, anywhere. 1.18 TiB (excl. `downloads/`) on `/dev/bcache0`. |
| Is the metadata backed up? | Yes, 5.0 GiB / 22,792 objects → garage bucket `media-config` — but the job has **never** passed its own verification, there are **no point-in-time snapshots**, and the blobs sit on **the same device as the library**. |
| Does that backup restore? | The objects do. The *procedure* as written does not: a verbatim restore yields 6+ unreadable databases until the stale `*.db-wal` sidecars are dropped (proven both ways below). |
| Measured restore of the metadata | **510 s** to fetch all 22,792 objects (4.96 GiB, 10.4 MB/s) + ~51 s to verify. Container redeploy and Jellyfin rescan not measured (not attempted — see §6). |
| Metered loss if the device dies today | `vault/` 7.2 GiB (permanent), `content-lan` 1.3 MiB (permanent), `roms/` 67 GiB, `movies/` 417 GiB + `tv/` 716 GiB (re-acquirable), plus all watch state / *arr history if the metadata backup is lost with it. |
| How long to re-acquire the library? | Bandwidth says ~34 h; **availability says weeks to months**, long tail never. Say months. |

## 1. What is actually protected

### 1.1 Metadata — the *arr + Jellyfin config tier

Source: `/data/nvme1/media-config` (the same tree appears at `/data/media/config/*`,
bind-mounted per app). This tier is **not** on the failing device: it is
`/dev/mapper/root[/@nvme1]`, the LUKS NVMe.

| Property | Measured value |
| --- | --- |
| Destination | `s3://media-config/current/` on nexus's self-hosted garage (`http://100.76.105.73:3900`, `--region garage`) |
| Size / objects | 5.3 GB (5.0 GiB) / 22,792 objects |
| Newest object | 2026-09-23 04:30:58 (8 h old at rehearsal time) |
| Cadence | daily 04:30 (`media-config-backup.timer`, `Persistent=true`, 15 min jitter) |
| **Last successful run** | **never.** `journalctl -u media-config-backup \| grep -c 'backup ok'` = **0**. Runs failed 2026-09-22 12:38 and 2026-09-23 05:15 (both after ~45 min and all 30 sync retries). |
| Point-in-time | **none.** `s3://media-config/snapshots/` is empty. Only an accumulating `current/` that is never pruned of stale keys. |
| Apps covered | sonarr 750, radarr 963, prowlarr 670, jellyfin 15083, seerr 4479, romm-db 287, bazarr 257, qbittorrent 207, lidarr 65, cleanuparr 29, romm-redis 1, romm 1 |
| Databases in the bucket | 19 `*.db` objects, dated 2026-09-23 04:30 — consistent `sqlite3 .backup` snapshots, not byte copies |
| Restore requires | garage credentials minted from the local admin socket (`garage key info media-config-backup --show-secret`) — no secret on disk; plus the procedure fix in §3.4 |

The job uploads the objects and then exits non-zero because its post-sync
verify/prune stage never runs. **A backup whose own verification has never
executed is not a verified backup** — the objects below are good, the job is not.

Second, older path: **RustFS** (`rustfs.service`, `http://localhost:9000`, data under
`/srv/rustfs` on the root NVMe — a healthy device). Bucket
`jellyfin-backups/configs/<app>/<stamp>.tar.gz`, driven by the manual
`/usr/local/bin/backup-to-rustfs.sh` (no timer). Two vintages exist:
`20260919-200121` and `20260922-133541`, for sonarr, radarr, bazarr, prowlarr,
lidarr, jellyfin, cleanuparr. It covers tarballs only, misses seerr/romm/qbittorrent,
is never scheduled, and is local-only — a fallback, not the plan.

**Not covered by either path — and the gap is wider than it looks.** The
media-config tier is not the whole config estate. `ls /data/media/config/` shows 30
directories; only 12 of them are the bind-mounted tier above (they resolve to
`/dev/mapper/root[/@nvme1/media-config/...]`). The other 18 are plain directories on
`/dev/bcache0[/@media]` — **on the same failing device as the library, and in no
backup at all**:

| Unbacked config/state on the failing device | Size |
| --- | --- |
| `_backups` | 300 MiB |
| `pilotarr-mysql` (a live MySQL database) | 235 MiB |
| `profilarr` | 66 MiB |
| `bazarr-backup-20260921` | 62 MiB |
| `jackett`, `gamarr`, `readarr`, `tubearchivist`, `tubearchivist-es`, `elasticsearch`, `arr-mcp`, `cloudflare-warp`, `jellyseerr.bak`, `mosaic-identity`, `redis`, `transmission` | ~13 MiB between them |
| **total** | **≈ 677 MiB** |

Tubearchivist's Elasticsearch index (`/data/nvme1/elasticsearch`, the YouTube-archive
metadata) and its config on `/data/media/config/tubearchivist*` are outside **both**
backup paths, and the Elasticsearch snapshot directory it writes lives on the same
device as the index — so it is not a backup either.

### 1.2 The library itself — nothing is backed up

Measured with `du -x` (filesystem-scoped: seven network mounts live inside
`/data/media`, so an unscoped traversal walks sentry and the krash boxes).
`downloads/` is excluded on purpose — it is churn, and another lane was pruning
measured leftovers there while this rehearsal ran.

| Directory | Size | Re-acquirable? |
| --- | --- | --- |
| `tv/` | 716.3 GiB | mostly yes (indexers), long tail no |
| `movies/` | 417.0 GiB | mostly yes, big remuxes are the risk |
| `roms/` | 67.4 GiB | in principle, provenance varies |
| `vault/` | 7.2 GiB | **no** — curated, filed by hand (`file-to-vault`) |
| `archive/` (nfs4 → sentry) | 0.4 GiB | remote; the sentry dirs are empty |
| `content-lan/` | 1.3 MiB | **no** |
| `music/`, `books/`, `youtube/`, `games/` | 0 | empty |
| **library total (excl. `downloads/`)** | **1.18 TiB** | |
| `downloads/` (churn, not library) | 608.6 GiB (was 699 GiB pre-prune) | yes |

Places that look like a copy of the library and are **not**:

- **sentry `/srv/media`** (nfs4, mounted at `/data/media/archive`): `books/`, `movies/`,
  `music/`, `tv/` all exist and are **all empty** (0 bytes each). The 932 G volume holds
  505 G of something else and `.rescue/*.tar.gz` config tarballs. There is no media copy there.
- **rustfs bucket `media-archive`**: empty.
- **krash2-media / krash3-media** (SMB shares mounted *into* `/data/media`): these hold
  real library content (`movies/`, `tv/`, `downloads/`, AI-upscaled DS9 seasons) — but
  they are library **sources** on other hosts, not a backup of this library. Their
  contents are not at risk from this device, which is the one useful thing about them.
- **`/data/backups`** (forge/sentry/zephyr archives): on **the same bcache0**, and holds
  no media.
- **btrfs snapshots of `@media`**: none. `btrfs subvolume list /data/media` shows only
  `@shared/.snapshots/pre-garage-repair-20260920`.
- The **ns `media` Helm/ArgoCD manifests** (`media-*` apps, all Synced+Healthy) restore
  the *applications*; they contain no media and no watch state.

### 1.3 The device, stated precisely

- `/data/media` is `/dev/bcache0[/@media]`; the backing device is `/dev/sda` — a 3.6 TB
  *spinning* disk (`ROTA=1`). `/sys/block/bcache0/bcache/state` = **`no cache`** and
  `/sys/fs/bcache/` holds no cache set: **no cache is attached**.
- Filling: 3.19 TiB used of 3.64 TiB, 452 GiB free (88 %); `Data,single` (ratio 1.00),
  `Metadata,DUP`. Single profile means btrfs can **detect** a bad block and has no copy
  to repair from.
- `btrfs device stats /data/media`: `corruption_errs 3959`, and `read_io_errs`,
  `write_io_errs`, `flush_io_errs`, `generation_errs` all **0**.
- The scrub started 2026-09-22 09:57 ran 5 h 19 m and was **aborted** — kernel:
  `scrub: not finished on devid 1 with status: -125`, `Error summary: no errors found`
  for the part that ran. That is roughly **10 % coverage**.
- Therefore the honest phrasing is: *the media volume is an uncached 4 TB HDD at 88 %
  full with historical corruption counters and a known tendency to hang on some reads;
  there is no current evidence of active corruption, and 90 % of the device has not
  been read since the counters were last reset.*

That is still a device nobody should be betting 1.18 TiB of unbacked data on — and
the backup does not cover the bet: garage's blobs live in `/data/shared/garage/data`,
which is `/dev/bcache0[/@shared]` — **the same physical device as the library**. A
device loss takes the library *and* its metadata backup together.

## 2. The rehearsal — measured, not assumed

Scratch: `/data/nvme1/restore-drill-20260923` and `.../restore-ab` (root NVMe, the
healthy device). Nothing was written to `/data/media`, to any live config, or to
zephyr. Both scratch trees were deleted at the end and the deletion was verified
(`[ -e ]` test + a sweep for leftovers). Live databases were opened `mode=ro`.

| Step | What it proves | Measured |
| --- | --- | --- |
| Full fetch of `s3://media-config/current/` → scratch | every object in the backup is readable, and what a real restore costs | **22,792 objects / 5,324,932,276 B (4.96 GiB) in 510 s = 10.4 MB/s, 44.7 objects/s, sync rc=0** |
| Bounded fetch (databases + key config only) | the cheap re-runnable path | 27 objects / 356 MB in 18 s (18.9 MB/s) |
| Verification pass over the restored 22.8k-file set (listing + 19 database integrity checks + row-count comparisons) | the restore is usable, not just present | **~51 s** |
| A/B test on the stale-WAL hazard | which step a restore must not skip | see §2.2 |
| Live-read baseline for comparison | the numbers restored are the numbers that matter | sonarr 66 series / 8880 episodes / 1183 episode files / 6130 history; radarr 142 movies / 92 movie files / 445 history; prowlarr 23 indexers / 215,980 history; jellyfin 7898 items / 252 UserData rows / 2 users; qbittorrent 73 `.fastresume` |

**Metadata restore time, end to end: ~10 minutes of I/O** (510 s fetch + ~51 s verify),
before any container is redeployed. Extrapolating to a *real* recovery, the dominant
unknown is not this step — it is the Jellyfin rescan of 1.18 TiB of library, which was
**not** measured (it would have required writing to live config and hammering the live
server; see §5). Plan hours for that, not minutes.

### 2.1 What a naive restore produces

Restoring the bucket verbatim (all 22,792 objects, exactly as they are stored) gives a
metadata set whose databases are **not usable**:

```
[FAIL] cleanuparr/events.db        integrity=*** in database main ***
[FAIL] jellyfin/data/data/jellyfin.db  integrity=*** in database main ***
[FAIL] lidarr/lidarr.db            integrity=*** in database main ***
[FAIL] lidarr/logs.db              integrity=Parse error ... database disk image is malformed (11)
[FAIL] prowlarr/prowlarr.db        integrity=Parse error ... database disk image is malformed (11)
[FAIL] radarr/radarr.db            integrity=*** in database main ***
[FAIL] sonarr/sonarr.db            integrity=*** in database main ***
[FAIL] 12 restored database(s) carry a *.db-wal OLDER than the database
```

`prowlarr Indexers` and `jellyfin BaseItems` come back **EMPTY** from that restore.

### 2.2 The cause, proven both ways

The bucket contains **25 `*.db-wal` / `*.db-shm` objects**. They are leftovers: the
uploader screens sidecars out of its staged copy and snapshots live databases with
`sqlite3 .backup`, and nothing ever deletes an old object (no `--delete`, no
snapshots). So the WAL files in the bucket belong to a **different generation** of
their database — e.g. `sonarr/sonarr.db-wal` is dated 2026-09-22 07:59 while
`sonarr.db` is 2026-09-23 04:30.

A/B on three databases, downloaded fresh from the bucket:

| State | `pragma integrity_check` | Row counts |
| --- | --- | --- |
| **A** — verbatim restore (db + its stale `-wal`) | sonarr `*** in database main ***`, radarr `*** in database main ***`, jellyfin `*** in database main ***` | sonarr Series 66, radarr Movies 142, jellyfin **unreadable** (`database disk image is malformed`) |
| **B** — same files after removing `*.db-wal` / `*.db-shm` | sonarr **ok**, radarr **ok**, jellyfin **ok** | 66 / 142 / 7897 (live: 66 / 142 / 7898) |

The bounded rehearsal — which never fetched a sidecar — restored **14 databases with
`integrity=ok` and row counts identical to live** (sonarr 66/8880, radarr 142, prowlarr
23, jellyfin 7898 items / 252 UserData, plus 96 Jellyfin XML config files).

**Verdict: the backup's objects are sound; the restore procedure was the broken part.**
A restore must drop every `*.db-wal` and `*.db-shm` that sits beside a `*.db`. Do that
and the metadata tier comes back verified-usable in ~10 minutes.

## 3. Permanent loss if the device dies today

| Asset | Size measured | Verdict |
| --- | --- | --- |
| `vault/` | 7.2 GiB | **permanently lost.** Curated, hand-filed (`web`, `Documentaries`, `Extras` via `file-to-vault`); not in any indexer, not in any *arr database, not backed up anywhere. |
| `content-lan/` | 1.3 MiB | **permanently lost** (LAN-local content, no source). |
| Jellyfin watch state | 252 UserData rows / 2 users | lost **if the metadata backup dies with the device** (it shares `/dev/bcache0`). Not reconstructible from the media files. |
| *arr history + configuration | sonarr 6130, radarr 445, prowlarr 215,980 history rows; 23 indexer configs; quality profiles, custom formats, seerr requests, cleanuparr rules | same: only in the metadata backup |
| qbittorrent resume state | 73 `.fastresume` torrents | same — losing it also loses the *map* of what to re-acquire |
| Unbacked app config/state on the failing device | ≈ 677 MiB | **lost.** `pilotarr-mysql` (MySQL), `profilarr`, `jackett`, `gamarr`, `readarr`, `tubearchivist`/`tubearchivist-es`, `elasticsearch`, `_backups` — on `/dev/bcache0`, in no backup, and not re-downloadable (see §1.1) |
| `roms/` | 67.4 GiB | re-acquirable in principle; some images are hand-collected |
| `movies/` + `tv/` | 1.13 TiB | re-acquirable in principle — availability is the question, not possibility |
| tubearchivist / Elasticsearch index | not backed up | YouTube-archive metadata; `youtube/` is empty so the index is the only artifact |

The sentence to remember: **if the media device dies tonight, the homelab loses 1.18 TiB
of library, 7.2 GiB of it forever, and — because the metadata backup lives on the same
device — the watch state and history that make the library *yours* rather than a pile
of files.**

## 4. The re-acquisition path (for the re-acquirable 1.13 TiB)

**Indexers** (read from the live Prowlarr database, names only): nyaasi, thepiratebay,
yts, limetorrents, torrentproject2, torrent9, torrentdownload, knaben, magnetdownload,
eztv, subsplease, mikan, dmhy, bangumi moe, tokyo toshokan, internet archive, bluroms,
bemaniso, ruTor, NoNaMe Club, the new retro, bigfangroup, shana project — 23 in total.

**Ratio reality: there is no ratio debt to repay.** Almost all of these are public
Cardigann definitions; nothing here obliges seeding. The binding constraints are
(a) availability and (b) time, not ratio. The private/semi-private entries (bemaniso,
ruTor, NoNaMe Club) are worthless without accounts — if the 4K remuxes matter, one
private tracker with real retention is the only thing that changes the answer.

**The restore does the planning for you.** The *arr databases are the map of what is
missing: restored Radarr knows all 142 movies and immediately reports which lack files
(92 files today), Sonarr knows 66 series / 8880 episodes against 1183 files, and
Prowlarr's 23 indexers come back configured. Re-acquiring is then a job the *arr apps
run unattended ("search all missing"), not manual archaeology. qbittorrent's 73
`.fastresume` entries preserve the torrent identity of what was already flowing.

**Estimate (assumptions stated, not measured):** the transfer is a pipelined,
availability-bound problem, not a bandwidth one.

| Assumption | Consequence |
| --- | --- |
| 1.13 TiB to move | = 1,184,829 MB |
| sustained 10 MB/s aggregate (optimistic: several concurrent grabs, healthy peers) | ≈ 33 h of pure transfer |
| sustained 5 MB/s (realistic for a home line on mostly-public trackers) | ≈ 66 h |
| + the long tail: 20–84 GB 4K remuxes (`Akira` 84 GB, `In the Grey` 62 GB, `Shelter` 59 GB) and 2026 releases with 0–2 seeders | peer count, not the line, sets the pace |
| + titles that will not come back at all (niche remuxes, specific sub groups, the AI-upscaled DS9 seasons) | permanent, and not predictable in advance |

**Honest answer: days of transfer, weeks to months to *mostly* whole, and a small set
that never comes back.** Anyone planning this should plan months. The actual aggregate
throughput of this connection was **not** measured (it needs qBittorrent WebUI auth;
see §5) — so treat the hours figures as arithmetic on an unmeasured rate, not a result.

## 5. What this rehearsal did NOT prove

Stated plainly, because a rehearsal that overclaims is worse than none:

1. **No application was started against the restored config.** The *data layer* is
   proven usable (integrity + row counts + XML config present); that the *arr and
   Jellyfin containers boot correctly on it was not tested — doing so means writing
   config into a live cluster and re-indexing 1.18 TiB on the failing device.
2. **Jellyfin rescan time over 1.18 TiB is unmeasured** — likely the single largest
   item in a real recovery (hours). Plan with a wide envelope.
3. **Only ~10 % of the library device has been read since the counters were last
   reset.** No per-file mapping of bad extents was attempted
   (`btrfs inspect-internal logical-resolve` needs a scrub's logical addresses); the
   3,959 corruption counters are historical.
4. **The daily `media-config-backup` failure was not diagnosed.** Its objects upload
   and then the unit exits non-zero after 30 sync retries; fixing that job is out of
   scope here and was not attempted.
5. **Aggregate re-acquire throughput was not measured** (needs qBittorrent WebUI
   credentials; deliberately not handled).
6. **Coverage of tubearchivist / pilotarr / Elasticsearch was only established
   negatively** ("not in the bucket"), not audited in depth.
7. **The 1.18 TiB figure excludes `downloads/`** — measured at 608.6 GiB while another
   lane was actively pruning it (699 GiB at first reading), so it is a moving number.

## 6. The re-runnable drill

`scripts/verify/media_restore_drill.sh` — read-only, re-runnable, documented in
`scripts/verify/README.md`.

```bash
ssh nexus 'bash ~/homelab-ops/scripts/verify/media_restore_drill.sh'          # inventory + bounded rehearsal (~30 s)
ssh nexus 'bash ~/homelab-ops/scripts/verify/media_restore_drill.sh --full'   # rehearse the whole 22.8k-object metadata set
```

It asserts, in order: tools/mounts/credentials (minting garage credentials at run time
and printing only a length); that the metadata tier and the library are different
devices **and that the backup is not stored on the library's device**; per-app object
counts and freshness in the bucket; whether the backup job has ever verified itself;
whether point-in-time snapshots exist; that stale `*.db-wal`/`*.db-shm` sidecars are
present (the restore hazard of §2.2); the live row counts against floors; a scratch
restore with per-database `integrity_check` and row-count comparison against live;
a measured restore time; the library's measured size per directory and the absence of
any backup for it; and finally that its scratch directory is deleted.

Exit codes follow `_lib.sh`: `0` held, `1` real finding, `2` could not evaluate.
**Today it exits 1 — that is the correct current state**, with five findings: the
backup shares the library's device; the job has never verified itself; there are no
snapshots; the bucket carries stale sidecars; the library is unbacked.

**Procedure a real restore must follow** (the parts that are not optional):

1. Mint credentials from garage's admin socket — never a static key in a config.
2. Restore into a fresh tree; **never** restore over a live config.
3. **Drop every `*.db-wal` / `*.db-shm` that sits beside a `*.db`** (§2.2 — this is the
   step that turns an unusable restore into a working one).
4. Verify before use: per-database `pragma integrity_check` + row counts against the
   numbers in §2.
5. Only then bring the *arr containers and Jellyfin up against it, and expect a full
   library rescan.

## 7. What to fix (recommendations, none of them done here)

Ordered by how cheap they are against how much they protect:

1. **Get the metadata backup off this device.** Today the only copy of the curated
   metadata lives in `/data/shared/garage/data` — the same physical disk as the library.
   It is 5.0 GiB: copying it nightly to RustFS (`/srv/rustfs`, root NVMe) *and* to
   sentry (932 G volume, 422 G free) is minutes of work and removes the single
   catastrophic correlation.
2. **Protect `vault/` (7.2 GiB, permanently lost if the device dies).** This is the one
   directory where "we can re-download it" is false. It fits on any host in the fleet.
3. **Make `media-config-backup` actually finish.** It has never logged its own success
   line; add `--delete` (or per-run dated prefixes with retention) so `current/` stops
   accumulating objects from different generations, and re-run until
   `journalctl -u media-config-backup | grep 'backup ok'` is non-empty. The drill's
   §2.2 check is the acceptance test.
4. **Bake the sidecar-drop step into the restore procedure** wherever it is written
   down — it is the difference between a verified restore and 12 malformed databases.
5. **Accept re-acquire for `movies/`+`tv/`**, but treat the *arr databases as the asset
   they are: with them, re-acquire is automatic; without them it is archaeology.
6. **Re-baseline the device counters and finish a rate-capped scrub** once the cache
   decision is settled, so "historical counters" can become "no errors, measured".
   That work belongs to the lane that owns `/dev/bcache0`, not here.

## 8. Evidence

- Drill script: `scripts/verify/media_restore_drill.sh` (this repo, `scripts/verify/`).
- Rehearsal transcripts on nexus: `/tmp/media-drill-bounded.log`,
  `/tmp/media-drill-full.log` (the drill's own output; safe to paste — no secret values).
- Scratch used and deleted: `/data/nvme1/restore-drill-20260923`,
  `/data/nvme1/restore-ab` (both proven gone; the drill makes the same proof every run).
- Read-only facts read for this document: `findmnt -T`, `btrfs device stats`,
  `btrfs filesystem usage`, `btrfs subvolume list /data/media`, `garage bucket info`,
  `garage bucket list`, `journalctl -u media-config-backup`, `sqlite3 -readonly` on the
  live *arr/Jellyfin databases, `du -x` per library directory, `ls` on sentry's exports.
