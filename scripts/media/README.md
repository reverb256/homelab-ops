# Downloads leftover reclamation - proof-ranked, DRY-RUN BY DEFAULT

Status: **AWAITING j_kro'S WORD.** Nothing here deletes anything unless it is
called with `--apply --i-mean-it`. No timer, no CronJob, no automatic path.

Audit date 2026-09-22. Root `/data/media/downloads` on `/dev/bcache0` (device `0:67`).

## What the 94 items are

Completed **release** copies left behind after the *arr stack imported the
payload. The library holds the same content as a *different file* - the item
here is the untouched release (a `BDMV/` tree, a scene folder, a season pack),
while the library holds the remux or the re-named episode file. The two are
genuinely separate files, so nothing in the library points at these bytes.

Worked example: `Akira.1988.JAPANESE.2160p.BluRay.HEVC.TrueHD.5.1-TAiCHi`
(97.47 GB) versus the library remux
`Akira (1988) Remux-2160p.mkv` (84,585,013,282 B) and its payload
`BDMV/STREAM/00003.m2ts` (96,062,312,448 B). Both links=1, no shared inode.

## What qualifies an item (all four, fail-closed)

| proof | meaning |
|---|---|
| **P1 device** | every path in the item is on the *same* block device as the root, checked per path with `os.lstat().st_dev`. This is the `-x` / `--one-file-system` guarantee. |
| **P2 nlink** | every regular file has `st_nlink == 1`. A hardlinked file is still referenced by the library, so it is **not** a leftover. |
| **P3 library** | no file is a library inode, and no library path (sonarr, radarr, jellyfin) sits inside the item. |
| **P4 client** | no qBittorrent torrent's content path sits inside the item. |

A proof source that cannot be read marks the item `UNPROVEN` and it is **not**
eligible. Every source is recorded in the manifest.

## Audit result

| metric | value |
|---|---|
| entries scanned | 95 |
| eligible | **94** |
| reclaimable | **1,008.0 GB** (1007984638149 B) |
| still active in download client | 0 |
| hardlinked into library (excluded) | 1 |
| library-referenced | 0 |
| genuinely unknown | 0 |

Proof sources: ok (+2153 paths); ok (+103 paths);
ok (+7569 paths); ok (69 torrents; 57 complete, 6 error/metaDL states).

Largest items:

| # | item | size |
|---|---|---|
| 1 | `Akira.1988.JAPANESE.2160p.BluRay.HEVC.TrueHD.5.1-TAiCHi` | 97.47 GB |
| 2 | `Attack.on.Titan.The.Last.Attack.2024.4K.HDR.DV.2160p.BDRemux Jap Eng Sub Ita x265-NAHOM` | 76.36 GB |
| 3 | `Seinfeld.S09.2160p.NF.WEB-DL.x265.10bit.HDR.DDP5.1-ABBiE[rartv]` | 70.91 GB |
| 4 | `The.Office.US.S05.1080p.BluRay.x264-decibeL[rartv]` | 67.86 GB |
| 5 | `In.The.Grey.2026.2160p.UHD.BluRay.REMUX.HDR.MULTi.TrueHD.Atmos.H265-BTM` | 62.10 GB |
| 6 | `[FLE] Re ZERO Starting Life in Another World - S01 (BD 1080p HEVC FLAC) [Dual Audio]` | 54.32 GB |
| 7 | `Fullmetal.Alchemist.Brotherhood.S01.MULTi.1080p.10bits.BluRay.x265.AAC-FRiTCHi571` | 41.97 GB |
| 8 | `3.Days.To.Kill.2014.1080p.BluRay.AVC.DTS-HD.MA.5.1-PublicHD` | 38.42 GB |
| 9 | `DS9 S04 AI_Upscale_1080p+` | 25.26 GB |
| 10 | `Seinfeld.1989.S03.1080p.BluRay.DDP.5.1.x265-edge2020` | 22.22 GB |
| 11 | `Seinfeld.1989.S04.1080p.BluRay.DDP.5.1.x265-edge2020` | 22.21 GB |
| 12 | `Seinfeld.1989.S08.1080p.BluRay.DDP.5.1.x265-edge2020` | 21.49 GB |
| 13 | `Seinfeld.1989.S09.1080p.BluRay.DDP.5.1.x265-edge2020` | 20.71 GB |
| 14 | `Seinfeld.1989.S06.1080p.BluRay.DDP.5.1.x265-edge2020` | 20.34 GB |
| 15 | `[Hako] Towa no Yuugure - S01 (WEB 1080p HEVC AAC)` | 18.13 GB |

## Exact before / after df on bcache0

| | total | used | avail | used % |
|---|---|---|---|---|
| now | 4.00 TB | 3.44 TB | 0.55 TB | 87% |
| after | 4.00 TB | 2.44 TB | 1.55 TB | 61 % |

That takes `DiskSpaceLow` for `0:67` out of its >85 % band and leaves roughly
61 % used. Verify with `df -h /data/media` immediately before and
after; btrfs accounting can lag a snapshot delete.

## What deletion costs

The bytes are gone from disk and only re-acquirable by re-download. The library
copy is a *different file*, so playback is unaffected - but a future re-import
of a better release, or a repack, would have to fetch the release again. Items
still present as torrents (none in this audit - see below) also lose ratio and
become unavailable to reseed.

## Apply path: client first, filesystem second

`apply-leftovers.sh --apply --i-mean-it` deletes **through qBittorrent** with
`deleteFiles=true` for any item a torrent actually owns, so the client registry
and the disk agree. Removing files with `rm` while leaving torrent rows behind
would put the client in a permanent `missing files` state - a surface reporting
something untrue, which is the same defect class this audit exists to avoid.

Falling back to a filesystem delete is only correct when no torrent owns the
bytes. **In this audit that is every item**: qBittorrent's save path is
`/krash2/downloads` (the krash2 SMB share), while these items sit on the local
pool, so 0 of 94 eligible items have an owning torrent row. A torrent
that merely *name*-matches an item is never used for deletion, because
`deleteFiles` would then destroy a different pool's data and leave the local
item in place. Each item's `via` (`qbittorrent-api(deleteFiles)` or
`filesystem`) is written to `leftover-manifest.json.applied.json`.

`--apply` refuses to run at all without a working download-client session, so
the client can never be left pointing at files that do not exist.

Note: 7 network mounts live inside `/data/media`: `archive` (nfs4), `krash2-smb` and
`krash3-smb` (cifs), `krash2-media`, `krash3-media`, plus their autofs parents. 
## Re-auditing

```
scripts/verify/leftover-occupancy.sh          # detection only, never deletes
scripts/media/apply-leftovers.sh --json scripts/media/leftover-manifest.json
```

The verify entry re-runs the same proof and reports it in the sweep's
`verdict | section | item | signal | expected` format, so occupancy is visible
in the same pass as every other silent-failure check.
