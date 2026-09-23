# Downloads leftover reclamation - proof-ranked, DRY-RUN BY DEFAULT

Status: **AWAITING j_kro'S WORD.** Nothing here deletes anything unless it is
called with `--apply --i-mean-it`. No timer, no CronJob, no automatic path.

Audit 2026-09-22. Root `/data/media/downloads` on `/dev/bcache0` (device `0:67`).

## Sizes are allocated bytes, not apparent bytes

btrfs reflinks and shared extents make apparent size a lie about reclaim. The
manifest records **`st_blocks * 512` (what `du -x` reports)** as `bytes` and
apparent size as `apparent_bytes`. Measured per-item deltas: a season pack that
looks like 70.9 GB occupies 14 GB; another that looks like 67.9 GB occupies
1 GB. Use `bytes`, never `stat` size.

Cross-check: eligible allocated (633.9 GB) + `games`
(1 item, hardlinked, excluded) =
751.0 GB = `du -s -x /data/media/downloads`. The accounting closes.

## What the 94 items are

Completed **release** copies left behind after the *arr stack imported the
payload. The library holds the same content as a *different file* - the item
here is the untouched release (a `BDMV/` tree, a scene folder, a season pack),
while the library holds the remux or the re-named episode. The two are
genuinely separate files, so nothing in the library points at these bytes.

Worked example: `Akira.1988.JAPANESE.2160p.BluRay.HEVC.TrueHD.5.1-TAiCHi` versus
the library remux `Akira (1988) Remux-2160p.mkv` (84,585,013,282 B) and its
payload `BDMV/STREAM/00003.m2ts` (96,062,312,448 B). Both links=1, no shared inode.

## What qualifies an item (all four, fail-closed)

| proof | meaning |
|---|---|
| **P1 device** | every path is on the *same* block device as the root, checked per path with `os.lstat().st_dev`. This is the `-x` guarantee. |
| **P2 nlink** | every regular file has `st_nlink == 1`. A hardlinked file is still referenced by the library, so it is **not** a leftover. |
| **P3 library** | no file is a library inode, and no library path (sonarr, radarr, jellyfin) sits inside the item. |
| **P4 client** | no qBittorrent torrent owns the bytes. |

An unreadable proof source marks the item `UNPROVEN` and it is **not** eligible.

## Audit result

| metric | allocated | apparent |
|---|---|---|
| eligible (94 items) | **633.9 GB** | 1,008.0 GB |
| still active in download client | 0 items | - |
| hardlinked into library (excluded) | 1 item | - |
| library-referenced | 0 items | - |
| genuinely unknown | 0 items | - |

Proof sources: ok (+2153 paths); ok (+104 paths);
ok (+7587 paths); ok (70 torrents; 57 complete, 6 error/metaDL states).

Largest eligible items (allocated / apparent):

| # | item | allocated | apparent |
|---|---|---|---|
| 1 | `Akira.1988.JAPANESE.2160p.BluRay.HEVC.TrueHD.5.1-TAiCHi` | 97.5 GB | 97.5 GB |
| 2 | `In.The.Grey.2026.2160p.UHD.BluRay.REMUX.HDR.MULTi.TrueHD.Atmos.H265-BTM` | 62.1 GB | 62.1 GB |
| 3 | `[FLE] Re ZERO Starting Life in Another World - S01 (BD 1080p HEVC FLAC) [Dual Audio]` | 54.3 GB | 54.3 GB |
| 4 | `Attack.on.Titan.The.Last.Attack.2024.4K.HDR.DV.2160p.BDRemux Jap Eng Sub Ita x265-NAHOM` | 44.4 GB | 76.4 GB |
| 5 | `Fullmetal.Alchemist.Brotherhood.S01.MULTi.1080p.10bits.BluRay.x265.AAC-FRiTCHi571` | 42.0 GB | 42.0 GB |
| 6 | `3.Days.To.Kill.2014.1080p.BluRay.AVC.DTS-HD.MA.5.1-PublicHD` | 30.7 GB | 38.4 GB |
| 7 | `DS9 S04 AI_Upscale_1080p+` | 25.3 GB | 25.3 GB |
| 8 | `DS9 S03 AI_Upscale_1080p+` | 17.4 GB | 17.4 GB |
| 9 | `Seinfeld.S09.2160p.NF.WEB-DL.x265.10bit.HDR.DDP5.1-ABBiE[rartv]` | 13.7 GB | 70.9 GB |
| 10 | `www.UIndex.org    -    Seinfeld S05E10 The Cigar Store Indian UHD BluRay 2160p DTS-HD MA 5 1 HEVC REMUX-FraMeSToR` | 11.1 GB | 11.1 GB |
| 11 | `Boss Level (2021) (2160p BluRay x265 HEVC 10bit HDR AAC 5.1 Tigole)` | 9.9 GB | 9.9 GB |
| 12 | `[DragsterPS] Fate Zero S02 [1080p] [Multi-Audio] [Multi-Subs]` | 9.9 GB | 9.9 GB |
| 13 | `Re.ZERO.Starting.Life.in.Another.World.S02.MULTi.1080p.WEBRiP.x265-T3KASHi` | 9.8 GB | 9.8 GB |
| 14 | `Seinfeld.1989.S03.1080p.BluRay.DDP.5.1.x265-edge2020` | 9.2 GB | 22.2 GB |
| 15 | `Fate Zero (2011) S01 [1080p x265 HEVC 10bit BluRay Dual Audio AAC] [Prof]` | 8.7 GB | 8.7 GB |

## Exact before / after df on bcache0

| | total | used | avail | used % |
|---|---|---|---|---|
| now | 3.6 TiB | 3.14 TiB | 507 GiB | 87% |
| after | 3.6 TiB | 2.56 TiB | 1097 GiB | 70 % |

That clears the 85 % line `DiskSpaceLow` keys on. Verify with
`df -h /data/media` immediately before and after; btrfs accounting can lag a
snapshot delete, and other writers are active during the window.

## Ownership: this is NOT a second download cleaner

`cleanuparr` already runs in the `media` namespace with `/data/media/downloads`
mounted, and its `downloadCleaner` is enabled (daily 00:00) alongside
`queueCleaner` (stalled > 60 min -> remove) and `deadTorrent`. It acts on
torrents it can see in the **download client**.

This tool owns a disjoint class: items with **no torrent row at all**. That is
precisely why they accumulated - qBittorrent's save path is `/krash2/downloads`,
so nothing in the client ever tracked the local pool's leftovers, and cleanuparr
therefore cannot see them either. Only the library-reference proof can tell a
torrent-less release copy apart from media.

One owner per class, so they cannot both act on the same bytes:

| class | owner | why |
|---|---|---|
| torrent-backed download, stalled/failed/complete | cleanuparr | it has a client row; delete stays inside the client |
| torrent-less leftover release in the pool | this tool | invisible to the client and to cleanuparr |

An item that *does* have an owning torrent is classified
`still-active-in-download-client` and is **not eligible** - this tool never
competes with cleanuparr for it. The `--apply` API path exists only for the race
where a torrent appears between audit and apply; it deletes through
qBittorrent with `deleteFiles=true` so the client cannot be left with a row
pointing at files that no longer exist, and records
`via=qbittorrent-api(deleteFiles)`.

## Apply path

```
scripts/media/apply-leftovers.sh --apply --i-mean-it
```

`--apply` refuses to run without a working download-client session. Every item's
`via` (`qbittorrent-api(deleteFiles)`, `filesystem`) goes to
`leftover-manifest.json.applied.json`. In this audit all 94 items are
torrent-less, so all take the filesystem path - the client path is a guard, not
the normal route.

## Filesystem scoping

7 network mounts live inside `/data/media`: `archive` (nfs4), `krash2-smb` and
`krash3-smb` (cifs), `krash2-media`, `krash3-media`, plus their autofs parents.
Since 2026-09-23 all four cifs mounts carry `noexec` — see "No execution from
the media mounts" below for the recipe and for what it does *not* cover.
Every size and delete operation is filesystem-scoped: a walk that crosses a
device boundary fails the item closed, and a delete re-checks `st_dev`
immediately before the unlink.

**Do not traverse `/data`.** Reads hang on bcache0 dead extents (a `find` across
`/data` timed out). Use targeted paths with timeouts; the tool wraps each item's
walk in `RECLAIM_WALK_TIMEOUT` (default 600 s) and marks timed-out items
ineligible.

## Re-auditing

```
scripts/verify/leftover-occupancy.sh          # detection only, never deletes
scripts/media/apply-leftovers.sh --json scripts/media/leftover-manifest.json
```

## No execution from the media mounts (`noexec`, 2026-09-23)

A live cryptominer and a trojan disguised as an episode file were found on the
Windows download boxes (krash2 / krash3) on 2026-09-23 and the Windows side was
hardened. The Linux half of the same risk is that the k3s nodes mounted those
SMB shares **executable**, so anything dropped into the media tree could be run
from the mount. All four CIFS mounts on **nexus** and **forge** now carry
`noexec`. This is the recipe, how it was applied, and what it does not cover.

The four `/etc/fstab` lines (only the `credentials=` path differs between
nodes; the option list is identical):

```
//10.1.1.79/krash2-storage  /data/media/krash2-smb    cifs credentials=/root/.creds/krash2-smb,uid=j_kro,gid=users,file_mode=0775,dir_mode=0775,noperm,noexec,vers=3.0,_netdev,x-systemd.automount,x-systemd.mount-timeout=30 0 0
//10.1.1.150/krash3-storage /data/media/krash3-smb    cifs credentials=/root/.creds/krash3-smb,uid=j_kro,gid=users,file_mode=0775,dir_mode=0775,noperm,noexec,vers=3.0,_netdev,x-systemd.automount,x-systemd.mount-timeout=30 0 0
//10.1.1.79/Media           /data/media/krash2-media  cifs credentials=/root/.creds/krash2-smb,uid=j_kro,gid=users,file_mode=0775,dir_mode=0775,noperm,noexec,vers=3.1.1,_netdev,x-systemd.automount,x-systemd.mount-timeout=30 0 0
//10.1.1.150/media          /data/media/krash3-media  cifs credentials=/root/.creds/krash3-smb,uid=j_kro,gid=users,file_mode=0775,dir_mode=0775,noperm,noexec,vers=3.1.1,_netdev,x-systemd.automount,x-systemd.mount-timeout=30 0 0
```

Idempotent, fail-closed scripts (run from zephyr; they back `/etc/fstab` up to
`/etc/fstab.bak-<UTC stamp>-noexec` first):

```
ssh nexus "bash -s" < scripts/media/apply-noexec-cifs-mounts.sh
ssh forge "bash -s" < scripts/media/apply-noexec-cifs-mounts.sh
ssh nexus "bash -s" < scripts/media/verify-noexec-cifs-mounts.sh
```

Three things that will bite you:

- **Editing fstab changes nothing on a running host.** All four are
  `x-systemd.automount` with `timeout=0`, so they never idle out and the live
  superblock keeps the options it was mounted with. `systemctl daemon-reload`
  regenerates the unit only (`systemctl cat` on
  `data-media-krash2\x2dmedia.mount` then reads `Options=…,noexec,…`). The live
  flag has to be put there with `mount -o remount,noexec <mountpoint>` — on cifs
  that preserves every other option (credentials, vers, cache) and needs no
  unmount, so no pod is disturbed. `mount | grep` is the only proof of the live
  state.
- **`systemctl show -p Options <unit>` is not that proof.** For an *active*
  unit it returns systemd's cached copy of `/proc/self/mountinfo`, which lags a
  hand remount by seconds: the same read showed `noexec` present on two units
  and "missing" on the other two immediately after an identical remount of all
  four, and all four were correct a minute later. Read the generator output or
  the kernel, not that property.
- **The containers that mount these paths still execute from them.** sonarr,
  radarr, jellyfin and qbittorrent take them as `hostPath` volumes, and a bind
  mount inherits per-mount flags from the mount it was cloned from *at clone
  time*. Their pods were created before the remount, so inside them `/krash2`
  still reads `rw,relatime` and runs a script dropped on the share — measured
  with a probe, not assumed. Recreating those pods is what closes it; nothing in
  the media stack executes from the mount (`/proc/*/exe` under
  `/data/media/krash*` is empty and the *arr / Jellyfin contract is read/write
  only), so a recreate is safe.

Verified on both nodes 2026-09-23T20:35Z: `mount | grep` shows `noexec` 4/4 on
each; a `#!/bin/sh` probe on each of the four mounts fails with
`Permission denied` (rc=126) while `cat` of the same file succeeds, a copy of
`/bin/true` is refused, and the same probe runs normally on `/tmp`; `df` on all
four still reports; `findmnt --verify` exits 0 (its two warnings — `/swap/swapfile`
and a credential-file permission probe — are pre-existing and unrelated);
`kubectl -n media get pods` is all Running/Ready.
