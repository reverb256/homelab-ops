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
| `bin/tmp-quota-watch` | `/usr/local/bin/tmp-quota-watch` | watch for tmpfs quota pressure (EDQUOT precursor) |
| `systemd/tmp-quota-watch.{service,timer}` | `/etc/systemd/system/` | per-user tmpfs quota watchdog (every 15m) |
| `apply.sh` | — | idempotent installer |