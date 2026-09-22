# zephyr — Omarchy system config (source of truth)

**Status: APPLIED and verified 2026-08-26.** modprobe overrides active, both
peakminer units enabled and running, drop-ins in place.

zephyr runs **Omarchy** (Arch) as of 2026-08-24. `nixos-config/hosts/zephyr/`
is now historical reference only — it no longer deploys to this host.

This directory is the source of truth for zephyr's **system-level** config.
Files here are version-controlled and applied by `apply.sh`. Never hand-edit
the live files on zephyr: edit here, commit, re-apply. Same discipline as the
NixOS rule, different mechanism.

## Layout

| Path | Installs to | Purpose |
|------|-------------|---------|
| `modprobe.d/blacklist-xpad.conf` | `/etc/modprobe.d/` | prevent xpad from claiming Xbox controllers (hid_xpadneo loaded) |
| `modprobe.d/hid_apple.conf` | `/etc/modprobe.d/` | `fnmode=2` — F-keys default on Apple keyboards |
| `modprobe.d/nvidia.conf` | `/etc/modprobe.d/` | `nvidia_drm modeset=1` — required for Niri/Wayland |
| `systemd/peakminer-3060ti.service` | `/etc/systemd/system/` | Pearl miner, GPU 0, 120W PL, API :21553 |
| `systemd/peakminer-3090.service` | `/etc/systemd/system/` | Pearl miner, GPU 1, 250W PL, API :21554 |
| `systemd/docker.service.d/no-block-boot.conf` | `/etc/systemd/system/docker.service.d/` | `DefaultDependencies=no` — don't block boot |
| `systemd/plocate-updatedb.service.d/ac-only.conf` | `/etc/systemd/system/plocate-updatedb.service.d/` | `ConditionACPower=true` — skip on battery |
| `systemd/user@.service.d/10-faster-shutdown.conf` | `/etc/systemd/system/user@.service.d/` | `TimeoutStopSec=5s` — faster user-session teardown |
| `apply.sh` | — | idempotent installer |

## Miners

Both units are revenue-critical. `ExecStartPre` sets the power limit before
the miner binary starts. `Restart=on-failure` with 10s backoff. Never disable
these to work around errors — fix the root cause.

## zephyr does NOT do backups

zephyr is a workstation. It must not run, schedule, or serve backups, and no
backup anywhere may depend on it. Enforced and verified 2026-09-22:

- No backup timers/services/units on this host. The only rclone units here are
  cloud MOUNTS (`rclone-outlook.com`, `omarchy-cloud-mount@`) — workstation use.
- No other host's backup script calls zephyr. The nexus and sentry scripts
  mention it only in comments.
- **The `garage` rclone remote was DELETED from `/home/j_kro/.config/rclone/`
  for exactly this reason.** It was dead since the 2026-09-20 Garage key
  rotation and was an invitation to point a backup at a workstation. The
  remaining remotes (dropbox, onedrive, mega, gdrive, oci-os) are the user's own
  cloud accounts for mounts and interactive work — do not remove those.

Backups belong on **nexus** (memlawb, haven, activepieces, media-config) and
**sentry** (gitlawb), pushing to Garage S3 on nexus. If you find yourself
reaching for zephyr to move backup data, the design is wrong.