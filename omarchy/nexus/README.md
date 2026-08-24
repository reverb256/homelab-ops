# nexus — Omarchy system config (source of truth)

**Status: APPLIED and verified 2026-08-23.** bcache pool assembles, all 7
mounts active and enabled, garage 2.3.0 running and healthy with 718k objects
readable over the S3 API.

nexus runs **Omarchy** (Arch) as of 2026-08-23. `nixos-config/hosts/nexus/`
is now historical reference only — it no longer deploys to this host.

This directory is the source of truth for nexus's **system-level** config.
Files here are version-controlled and applied by `apply.sh`. Never hand-edit
the live files on nexus: edit here, commit, re-apply. Same discipline as the
NixOS rule, different mechanism.

## Layout

| Path | Installs to | Purpose |
|------|-------------|---------|
| `modules-load.d/bcache.conf` | `/etc/modules-load.d/bcache.conf` | load the bcache module at boot |
| `udev/69-bcache.rules` | `/etc/udev/rules.d/69-bcache.rules` | register bcache members so `bcache0` assembles |
| `systemd/data-*.mount` | `/etc/systemd/system/` | btrfs subvol mounts off `bcache0` |
| `systemd/garage.service.d/override.conf` | `/etc/systemd/system/garage.service.d/` | point garage at the pool + order it after the mount |
| `garage.toml.template` | rendered to `/etc/garage.toml` | garage config; secrets injected at apply time |
| `ssh/10-hardening.conf` | `/etc/ssh/sshd_config.d/` | keys-only sshd (Arch defaults to password auth) |
| `systemd/memlawb-server.service` | `/etc/systemd/system/` | encrypted memory backend, store on the pool |
| `bin/memlawb-backup` | `/usr/local/bin/memlawb-backup` | sync the memory store to garage S3 |
| `systemd/memlawb-backup.{service,timer}` | `/etc/systemd/system/` | daily 04:00 backup, `Persistent=true` |
| `apply.sh` | — | idempotent installer |

## memlawb (encrypted memory)

Migrated from sentry 2026-08-24, because sentry is leaving NixOS. App at
`/data/hermes/memlawb`, store at `/data/hermes/memlawb-data` — both on the
bcache pool, so they survive a root reinstall.

Served on `:8080`, reachable **over the tailnet only** (`ufw allow in on
tailscale0 to any port 8080`). The zephyr client points at
`http://100.76.105.73:8080` via `hermes config set
mcp_servers.memlawb.env.MEMLAWB_URL` — never by editing `config.yaml`, which is
guard-blocked.

Verified after cutover: **114 entries in `user:j_kro`**, matching sentry exactly,
and the store tree hash was byte-identical
(`fab429680cc36fc2…`) before and after the copy.

### Two things that will bite you

1. **Never rotate the passphrase.** Key derivation is
   `scrypt(passphrase, sha256("memlawb:" + namespace))`. There is no re-encrypt
   tool, so changing the passphrase *or* the namespace derives a different
   AES-256-GCM key and every existing entry becomes unrecoverable.
2. **The passphrase must carry no trailing newline.** `~/.memlawb-passphrase.txt`
   is 65 bytes but the passphrase is 64 chars. Passing the raw file contents
   yields `error: Unsupported state or unable to authenticate data`, which looks
   exactly like data corruption. Always `tr -d '\n'`.

### Backup

The `memlawb` garage bucket had existed since 2026-08-19 with **0 objects** — the
store had no offsite copy at all. Now covered by `memlawb-backup.timer`
(daily 04:00): syncs to `s3://memlawb/current/` plus a dated
`s3://memlawb/snapshots/<stamp>/`, keeping 14 snapshots.

The script deliberately:
- uses **no `--delete`** on `current/`, so a local loss cannot propagate;
- **refuses to run on an empty source**, since an empty store is the signature of
  the service starting against an unmounted pool — syncing it would look
  successful and protect nothing;
- **verifies by object count**, not exit code;
- reads garage credentials from `garage key info --show-secret` at runtime, so no
  secret files sit on disk.

Verify a backup actually landed:

```bash
sudo garage -c /etc/garage.toml bucket info memlawb | grep -E 'Objects|Size'
```


## The storage pool

```
/dev/sda  3.6T  ST4000VN008      backing device ─┐
                                                 ├─> /dev/bcache0  btrfs "nexus-storage"
/dev/sdb  466G  Samsung 860 EVO  cache device  ─┘
```

UUIDs (stable, verified 2026-08-23):
- backing `070ecd62-0692-4e61-bd3a-9595e44da808`
- cache   `74f809c5-32ff-48f8-b3f1-09eeba1a6cac`
- btrfs   `08cbb21c-adb0-4e3c-928f-7b6d1fa2d236` (label `nexus-storage`)

The pool **survived** the nvme wipe. 912 GiB used, 2.74 TiB free.
Subvolumes: `home`, `shared`, `backups`, `media`, `containers`, `hermes`,
`pi`, `models`.

### Why udev rules are needed

Arch has no `bcache-tools` in the official repos (only `bcachefs-*`, which is
a different filesystem) and ships no bcache udev rules. Without them the
kernel never registers `/dev/sda` + `/dev/sdb` as bcache members, so
`/dev/bcache0` never appears and every mount fails.

`69-bcache.rules` writes each member to `/sys/fs/bcache/register_quiet`
directly — no `bcache-register` helper binary needed. `register_quiet` (not
`register`) is deliberate: it exits silently when a device is already
registered, which avoids udev error spam on `change` events. See
g2p/bcache-tools issue #36.

Mounts use `nofail` + `x-systemd.device-timeout=30s` so a pool problem
degrades to "garage is down" instead of "nexus won't boot".

## Garage

**Version: 2.3.0 (Arch `extra/garage`). Migrated from 1.3.1 on 2026-08-23.**

The metadata on disk was written by garage 1.3.1 (the nixpkgs pin). Arch ships
2.3.0. This was a supported but **one-way** 1.x → 2.x migration: 2.x rewrites
the metadata and 1.3.1 cannot read it afterward.

Verified compatible before migrating:
- `db_engine = "lmdb"` — still supported in 2.x (`db.lmdb/`, unchanged path).
  Arch's garage package depends on `lmdb`, so the engine is compiled in.
- `replication_factor` / `consistency_mode` — the 2.0 breaking change was the
  removal of `replication_mode`, which this config never used.
- `[admin] metrics_token` — still valid in 2.3.0.

What broke: the **admin HTTP API** moved from `/v1/` to `/v2/`. Nothing in this
homelab calls it (clients use the S3 API on :3900), but check before pointing
tooling at :3902. `garage json-api <Call>` is the 2.x CLI equivalent.

### Migration outcome (verified)

```
garage status  -> 1 node, git:v2.3.0, 931.3 GiB capacity, 2.7 TiB avail
GetClusterHealth -> status: healthy, 256/256 partitions OK
```

All data survived:

| Bucket | Objects | Size |
|--------|---------|------|
| backups | 718,529 | 391.3 GB |
| media, projects, logs, velero-backups, memlawb | 0 | 0 B |

5 access keys intact (`admin-key`, `kubernetes-s3-key`, `memlawb-key`,
`test-key`, `cluster-test-key`).

**End-to-end S3 read verified** — a SigV4-signed `ListObjectsV2` against
`http://127.0.0.1:3900/backups` with `admin-key` returned real objects
(`cluster-backup/20260814-091218/*.tar.gz`). Metadata surviving is not the
same as data being readable; this proves both.

### Rollback

One read-only pre-migration snapshot is retained:

```
/data/shared/.snapshots/premigration-garage-20260823-234001   (325G, shares extents)
```

Garage metadata inside it is at `garage/meta` (mtime 2026-03-18, untouched by
2.x). To roll back: stop garage, restore that `garage/` tree, reinstall a 1.3.1
binary (`https://garagehq.deuxfleurs.fr/_releases/v1.3.1/x86_64-unknown-linux-musl/garage`).

Two extra snapshots were cut during the failed first attempts and have been
deleted — only the genuine pre-migration one remains. `apply.sh` now writes a
`.migrated-2x` marker after a clean start, so re-runs no longer snapshot.

### Secrets

Four secrets live in `nixos-secrets` (sops-encrypted):
`garage-rpc-secret`, `garage-metrics-token`, `garage-s3-access-key-id`,
`garage-s3-secret-key`.

They are **not** managed declaratively on Omarchy — there is no sops-nix here.
`apply.sh` reads them from `/etc/garage-secrets/` (mode 0600, root-owned) and
renders `/etc/garage.toml` at apply time. Secrets never enter git.

**Decrypt from sentry, not zephyr.** The zephyr nvme wipe destroyed both
plaintext age keys (`~/.config/sops/age/keys.txt` and `/etc/nixos/.age/key.txt`).
The `cluster_age` recipient key survives on **sentry** at
`/etc/nixos/.age/key.txt` — verified 2026-08-23 by deriving its pubkey
(`age1567g6raae4adh97lrfhalc9wwhmtsulh89k9pkx24m5ezfh8a4xqndrt6l`, which is the
`cluster_age` recipient on all four garage secrets). forge holds a different
key (`age1p98yp8…`) that is **not** a recipient on these files.

Provision like this (verified working):

```bash
cd ~/Projects/nixos-secrets
for s in garage-rpc-secret garage-metrics-token; do
  cat "secrets/storage/$s.yaml" \
    | ssh sentry "cat > /tmp/$s.yaml && sudo env SOPS_AGE_KEY_FILE=/etc/nixos/.age/key.txt \
        sops -d --extract '[\"data\"]' /tmp/$s.yaml; rm -f /tmp/$s.yaml" \
    | ssh nexus "sudo install -Dm600 -o root -g root /dev/stdin /etc/garage-secrets/$s"
done
```

Two YubiKeys are also recipients and can decrypt without sentry — see the
`age-yubikey-decrypt` skill. That path needs `pcscd` and a physical touch.


## Applying

```bash
# from zephyr
cd ~/Projects/homelab-ops/omarchy/nexus
./apply.sh --check      # dry run: show what would change
./apply.sh              # apply (needs sudo on nexus)
```

`apply.sh` is idempotent — re-running it is safe and is the intended way to
reconcile drift. Verified: a second run takes no snapshot and does **not**
restart a healthy garage (`garage.service` uptime spans repeated applies).

## Pitfalls hit while building this (all cost real time)

1. **`/etc/garage.toml` must be `0640 root:garage`, not `0600 root:root`.**
   `garage.service` runs as `User=garage`. With a root-only config, garage logs
   `Loading configuration from /etc/garage.toml` and then dies with a bare
   `IO error: Permission denied (os error 13)`. The message names the file but
   not the reason, so it reads like a *data directory* permission fault. The
   file holds `rpc_secret`, so group-readable is the ceiling — never world.
2. **Check root-owned paths with `sudo test`, not `[[ -d ]]`.**
   `/data/shared/garage` is `0750 garage:garage`; `j_kro` cannot traverse it.
   An unprivileged existence test returns false and produced a false
   "WRONG SUBVOL, stop and investigate" abort on the first real apply, and made
   the snapshot guard re-snapshot a 274G subvolume on every run.
3. **`/data/shared/garage` is a plain directory, not a subvolume.**
   `btrfs subvolume snapshot` on it fails. Snapshot the enclosing `shared`
   subvolume; the metadata is inside at `garage/meta`.
4. **The Arch garage package creates its own `garage` user** via a
   systemd-sysusers hook (uid 959 here). Never hardcode the uid; the old NixOS
   data was uid 980, and 980/974 are already taken on Arch by
   `rfkill`/`systemd-resolve`.
5. **Mount unit filenames must match `Where=` exactly.** A hyphen in the path
   needs `\x2d` escaping, and systemd refuses the unit otherwise. `/data/nexus-home`
   was renamed to `/data/oldhome` to avoid a tracked file literally named
   `data-nexus\x2dhome.mount`. Validate with `systemd-analyze verify`.
6. **`garage status` needs sudo** now that the config is 0640 — an unprivileged
   call emits a confusing config-read error that looks like a service failure.

## Open problems

1. **Secret provisioning is manual and depends on sentry.** sops-nix was the
   NixOS answer; Arch has no equivalent here yet. Worse, the decrypt key now
   lives on exactly one host — when sentry migrates to Omarchy, that key must
   move first or the whole fleet loses access to its own secrets. A real
   replacement (age key on each host, or Hermes Vault) is needed before then.
2. **zephyr's Omarchy config is untracked drift.** Its two peakminer units in
   `/etc/systemd/system/` exist only on the live host — nothing in git
   references them. They should move into `omarchy/zephyr/` under this pattern.
3. **nexus is no longer a Nix builder.** It was the 46GB build host that kept
   zephyr (31GB) from OOMing. forge and sentry are the only NixOS hosts left,
   and they are 15GB and 31GB. Build capacity is an open question.


