#!/usr/bin/env bash
# Apply nexus's Omarchy system config: bcache assembly, /data mounts, garage.
#
# Idempotent. Re-run to reconcile drift. Run from zephyr or on nexus itself.
#
#   ./apply.sh --check     dry run, show what would change, touch nothing
#   ./apply.sh             apply
#
# Requires root on nexus (sudo). Nothing here is destructive to the storage
# pool: no mkfs, no bcache format, no deletion of garage data. The one
# state-changing action on existing data is starting garage 2.3.0 against
# metadata written by 1.3.1, which is a ONE-WAY migration — the script
# snapshots the metadata directory first and refuses to proceed without it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

BTRFS_UUID="08cbb21c-adb0-4e3c-928f-7b6d1fa2d236"
BACKING_UUID="070ecd62-0692-4e61-bd3a-9595e44da808"
CACHE_UUID="74f809c5-32ff-48f8-b3f1-09eeba1a6cac"
SECRET_DIR="/etc/garage-secrets"
GARAGE_DATA="/data/shared/garage"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
act()  { if (( CHECK )); then printf '  would: %s\n' "$*"; else eval "$*"; fi; }

[[ "$(hostname)" == "nexus" ]] || die "run this on nexus (current host: $(hostname))"

# ── 0. preflight ──────────────────────────────────────────────────────────
log "Preflight"

if (( ! CHECK )) && [[ $EUID -ne 0 ]]; then
  sudo -n true 2>/dev/null || die "need root. Passwordless sudo is not configured on nexus — run: sudo $0 ${*:-}"
fi
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

for dev_uuid in "$BACKING_UUID" "$CACHE_UUID"; do
  [[ -e "/dev/disk/by-uuid/$dev_uuid" ]] \
    || die "bcache member $dev_uuid is missing — do NOT continue, the pool is incomplete"
done
log "  both bcache members present"

command -v garage >/dev/null 2>&1 || warn "garage not installed yet (will install)"

# ── 1. bcache: module + udev rules ────────────────────────────────────────
log "bcache assembly"

# Tracks whether any managed file actually changed on this run. Declared
# BEFORE install_file is ever called — it was previously initialised to 0 on
# the line AFTER the function definition, which meant the first call's
# CHANGED=1 was immediately clobbered and the flag was always 0.
CHANGED=0

install_file() {
  local src="$1" dst="$2" mode="${3:-0644}"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    printf '  ok: %s (unchanged)\n' "$dst"
    return 0
  fi
  act "$SUDO install -Dm$mode '$src' '$dst'"
  printf '  set: %s\n' "$dst"
  CHANGED=1
}
install_file "$REPO_DIR/modules-load.d/bcache.conf" /etc/modules-load.d/bcache.conf
install_file "$REPO_DIR/udev/69-bcache.rules"       /etc/udev/rules.d/69-bcache.rules

if [[ ! -e /dev/bcache0 ]]; then
  log "  /dev/bcache0 absent — registering members now"
  act "$SUDO modprobe bcache"
  # Cache device first, then backing: registering the backing device first
  # leaves bcache0 in a degraded 'no cache' state until the cache appears.
  act "$SUDO sh -c 'echo /dev/disk/by-uuid/$CACHE_UUID   > /sys/fs/bcache/register_quiet'"
  act "$SUDO sh -c 'echo /dev/disk/by-uuid/$BACKING_UUID > /sys/fs/bcache/register_quiet'"
  if (( ! CHECK )); then
    for _ in $(seq 20); do [[ -e /dev/bcache0 ]] && break; sleep 0.5; done
    [[ -e /dev/bcache0 ]] || die "/dev/bcache0 did not appear after registering members"
  fi
fi
(( CHECK )) || log "  /dev/bcache0 present"

# ── 2. mount units ────────────────────────────────────────────────────────
log "Mount units"

# A stale read-only investigation mount shadows the real thing; drop it.
if mountpoint -q /mnt/nexus-storage 2>/dev/null; then
  log "  unmounting stale /mnt/nexus-storage"
  act "$SUDO umount /mnt/nexus-storage"
fi

for unit in "$REPO_DIR"/systemd/*.mount; do
  install_file "$unit" "/etc/systemd/system/$(basename "$unit")"
done
install_file "$REPO_DIR/systemd/garage.service.d/override.conf" \
             /etc/systemd/system/garage.service.d/override.conf

act "$SUDO systemctl daemon-reload"

for unit in "$REPO_DIR"/systemd/*.mount; do
  name="$(basename "$unit")"
  act "$SUDO systemctl enable --now '$name'"
done

# ── 2b. btrfs scrub timer (pool integrity monitoring) ──────────────────────
# The pool is Data,single: file data has no replica, so a scrub can DETECT
# corruption but never repair it. A manual scrub on 2026-09-08 reported
# csum=2324 with Corrected=0, and nothing monitored the pool afterwards.
#
# This section also closes a gap: apply.sh installed only systemd/*.mount, so
# the bin/ scripts and .timer/.service units staged in this component were
# never covered by it.
log "Component scripts and units"

# Install the WHOLE component tree, never named units. apply.sh previously
# installed only systemd/*.mount, so every bin/ script and .service/.timer
# staged here was committed to git but never deployed — the btrfs scrub timer
# sat unapplied until someone noticed, and media-config-backup would have done
# the same. Adding a component to git must be enough to deploy it.
for s in "$REPO_DIR"/bin/*; do
  [[ -f "$s" ]] || continue
  install_file "$s" "/usr/local/bin/$(basename "$s")" 0755
done

for u in "$REPO_DIR"/systemd/*.service "$REPO_DIR"/systemd/*.timer; do
  [[ -f "$u" ]] || continue
  install_file "$u" "/etc/systemd/system/$(basename "$u")"
done

install_file "$REPO_DIR/garage-buckets.tsv" /etc/garage-buckets.tsv

act "$SUDO systemctl daemon-reload"

# Enable every timer in the component. Enabling is idempotent, so re-runs no-op.
for u in "$REPO_DIR"/systemd/*.timer; do
  [[ -f "$u" ]] || continue
  act "$SUDO systemctl enable --now $(basename "$u")"
done

# memlawb-server is the one long-running daemon in this component; every other
# .service is Type=oneshot driven by its .timer.
act "$SUDO systemctl enable memlawb-server.service"

if (( ! CHECK )); then
  for unit in "$REPO_DIR"/systemd/*.mount; do
    name="$(basename "$unit")"
    systemctl is-active --quiet "$name" || die "$name failed to mount — check: systemctl status $name"
  done
  log "  all mounts active"
  # The pool must actually contain the object store, not an empty tree.
  # Test as ROOT: /data/shared/garage is mode 0750 owned by uid 980 (the old
  # NixOS garage user, which does not exist on Arch), so an unprivileged
  # `[[ -d ]]` cannot traverse it and returns false even when the metadata is
  # present. That produced a false "WRONG SUBVOL" abort on the first real run.
  $SUDO test -d "$GARAGE_DATA/meta" \
    || die "$GARAGE_DATA/meta missing after mount — WRONG SUBVOL, stop and investigate"
  log "  verified: $GARAGE_DATA/meta present"
  $SUDO test -f "$GARAGE_DATA/meta/cluster_layout" \
    || warn "no cluster_layout in metadata — this may be an uninitialized garage"
fi

# ── 3. sshd hardening ─────────────────────────────────────────────────────
log "sshd hardening"

install_file "$REPO_DIR/ssh/10-hardening.conf" /etc/ssh/sshd_config.d/10-hardening.conf

if (( ! CHECK )); then
  # Validate BEFORE reloading — a bad sshd_config that gets reloaded can lock
  # us out of a host whose only ingress is SSH.
  if $SUDO sshd -t 2>/dev/null; then
    $SUDO systemctl reload sshd
    log "  sshd config valid, reloaded"
    # sshd -T echoes keywords in their canonical CAPITALIZED form
    # ("PasswordAuthentication no"), not lowercase — grep case-insensitively or
    # this check reports a false failure while the setting is actually applied.
    if $SUDO sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'; then
      log "  verified: password auth disabled"
    else
      warn "password auth still enabled — check drop-in ordering"
    fi
  else
    warn "sshd -t FAILED; not reloading. Offending config left in place:"
    $SUDO sshd -t 2>&1 | head -5 >&2 || true
    die "refusing to reload a broken sshd config"
  fi
fi

# ── 4. garage user + package ──────────────────────────────────────────────
log "Garage user and package"

# The existing data is owned by uid 980/gid 974 from the NixOS host, where
# those ids belonged to the garage user. On Arch both are already taken
# (rfkill / systemd-resolve), so reusing them is not an option. Create a
# normal system user and chown the data to it — the data is ~274G but chown
# only rewrites inode metadata, not the blocks.
#
# NOTE: the Arch garage package ships a systemd-sysusers hook that ALSO
# creates a garage user (uid 959 observed 2026-08-23). Whichever runs first
# wins; both branches below are no-ops if the account already exists, so the
# script converges either way. Never hardcode the uid.
if ! getent group garage >/dev/null; then
  act "$SUDO groupadd --system garage"
fi
if ! getent passwd garage >/dev/null; then
  act "$SUDO useradd --system --gid garage --no-create-home \
       --home-dir /var/empty --shell /usr/bin/nologin \
       --comment 'Garage S3 storage service' garage"
fi

if ! pacman -Qi garage >/dev/null 2>&1; then
  act "$SUDO pacman -S --needed --noconfirm garage"
fi

# Re-check after install: the package's sysusers hook may have just created
# the account, and later steps (chgrp of /etc/garage.toml) depend on it.
if (( ! CHECK )); then
  getent passwd garage >/dev/null \
    || die "garage user still missing after package install — cannot continue"
  log "  garage user: $(id -u garage):$(id -g garage)"
fi

if (( ! CHECK )); then
  installed="$(pacman -Qi garage 2>/dev/null | awk '/^Version/{print $3}')"
  log "  garage $installed installed"
fi

# ── 4. secrets ────────────────────────────────────────────────────────────
log "Secrets"

# No sops-nix on Omarchy yet. These must be placed by hand for now; see
# README.md "Open problems". Decrypt from ~/Projects/nixos-secrets on zephyr.
missing=0
for s in garage-rpc-secret garage-metrics-token; do
  if [[ ! -s "$SECRET_DIR/$s" ]]; then
    warn "missing secret: $SECRET_DIR/$s"
    missing=1
  fi
done
if (( missing )); then
  cat >&2 <<'EOF'

  Garage cannot start without its RPC secret. Provision them from zephyr:

    cd ~/Projects/nixos-secrets
    for s in garage-rpc-secret garage-metrics-token; do
      cat "secrets/storage/$s.yaml" \
        | ssh sentry "cat > /tmp/$s.yaml && sudo env SOPS_AGE_KEY_FILE=/etc/nixos/.age/key.txt \
            sops -d --extract '[\"data\"]' /tmp/$s.yaml; rm -f /tmp/$s.yaml" \
        | ssh nexus "sudo install -Dm600 -o root -g root /dev/stdin /etc/garage-secrets/$s"
    done

  Decrypt on SENTRY, not zephyr: the zephyr nvme wipe destroyed both plaintext
  age keys. sentry's /etc/nixos/.age/key.txt is the surviving cluster_age
  recipient (forge holds a different key that is NOT a recipient here).

  Then re-run this script.
EOF
  (( CHECK )) || die "secrets missing — nothing further applied"
fi

# ── 5. metadata snapshot (one-way migration guard) ────────────────────────
# IMPORTANT: /data/shared/garage is a plain DIRECTORY, not a btrfs subvolume
# (verified 2026-08-23 — `btrfs subvolume list` shows only home/shared/backups/
# media/containers/hermes/pi/models, and shared/cache). So
# `btrfs subvolume snapshot /data/shared/garage` fails outright. Snapshot the
# enclosing `shared` subvolume instead, which contains garage/ inside it.
#
# This snapshot is the ONLY rollback path for a one-way metadata migration, so
# the script must not proceed if it fails.
SNAP="/data/shared/.snapshots/premigration-garage-$(date +%Y%m%d-%H%M%S)"
MARKER="$GARAGE_DATA/.migrated-2x"

# Check the marker as ROOT — $GARAGE_DATA is 0750 garage:garage and j_kro
# cannot traverse it, so an unprivileged [[ -f ]] always reports "absent" and
# every re-run cut another redundant snapshot of a 274G subvolume.
if (( CHECK )); then
  if $SUDO test -f "$MARKER" 2>/dev/null; then
    printf '  already migrated to 2.x (marker present) — would skip snapshot\n'
  else
    printf '  would: read-only btrfs snapshot of /data/shared -> %s\n' "$SNAP"
    printf '         (garage metadata is inside it at garage/meta)\n'
  fi
elif $SUDO test -f "$MARKER"; then
  log "Metadata snapshot: already migrated to 2.x (marker present) — skipping"
  SNAP=""   # nothing new taken; keep error messages honest
else
  log "Metadata snapshot before 1.3.1 -> 2.3.0 migration"
  $SUDO mkdir -p /data/shared/.snapshots
  $SUDO btrfs subvolume snapshot -r /data/shared "$SNAP" \
    || die "snapshot failed — refusing to start garage 2.x against 1.x metadata"
  log "  snapshot: $SNAP"
  log "  rollback: garage metadata is at $SNAP/garage/meta"
  # Marker is written only AFTER garage 2.x starts cleanly (step 7), so a
  # failed migration still re-snapshots on the next run.
fi

# ── 6. render config ──────────────────────────────────────────────────────
log "Rendering /etc/garage.toml"

if (( CHECK )); then
  printf '  would: render %s -> /etc/garage.toml (secrets injected)\n' "$REPO_DIR/garage.toml.template"
else
  # Ensure the garage user/group exist before we chgrp the config to them.
  # (Step 3 creates them; the Arch package also creates a garage user via its
  # sysusers hook, so the uid/gid may differ from what step 3 would have made.)
  tmp="$($SUDO mktemp)"
  $SUDO sh -c "sed \
    -e \"s|@RPC_SECRET@|\$(cat $SECRET_DIR/garage-rpc-secret)|g\" \
    -e \"s|@METRICS_TOKEN@|\$(cat $SECRET_DIR/garage-metrics-token)|g\" \
    '$REPO_DIR/garage.toml.template' > '$tmp'"
  # 0640 root:garage — NOT 0600 root:root. garage.service runs as User=garage,
  # so a root-only config makes garage exit 1 with a bare
  # "IO error: Permission denied (os error 13)" immediately after logging
  # "Loading configuration from /etc/garage.toml" — the message names the file
  # but not the reason, so this looks like a data-dir permission problem.
  # Hit on the first real apply (2026-08-23). Group-readable is required; the
  # file still holds rpc_secret so it must not be world-readable.
  $SUDO install -Dm640 -o root -g garage "$tmp" /etc/garage.toml
  $SUDO rm -f "$tmp"
  log "  wrote /etc/garage.toml (0640 root:garage)"
fi

# ── 7. ownership + start ──────────────────────────────────────────────────
log "Garage service"

if (( ! CHECK )); then
  cur_owner="$(stat -c '%U' "$GARAGE_DATA")"
  if [[ "$cur_owner" != "garage" ]]; then
    log "  chown $GARAGE_DATA (was uid $(stat -c '%u' "$GARAGE_DATA")) -> garage:garage"
    $SUDO chown -R garage:garage "$GARAGE_DATA"
  fi
fi

act "$SUDO systemctl enable garage.service"

# Only restart when something actually changed, or when garage isn't running.
# An unconditional restart made every idempotent re-run bounce a healthy
# service serving 718k objects.
if (( CHECK )); then
  printf '  would: restart garage.service if changed or inactive\n'
elif (( CHANGED )) || ! systemctl is-active --quiet garage.service; then
  log "  restarting garage.service (config changed or service inactive)"
  $SUDO systemctl restart garage.service
else
  log "  garage.service already running and nothing changed — no restart"
fi

if (( ! CHECK )); then
  sleep 5
  if ! systemctl is-active --quiet garage.service; then
    warn "garage did not come up. Recent log:"
    $SUDO journalctl -u garage.service -n 30 --no-pager >&2 || true
    die "garage.service failed — rollback snapshot: ${SNAP:-<none taken>}"
  fi
  log "  garage.service active"
  # Only now is the 2.x migration known-good. Writing the marker here (not at
  # snapshot time) means a failed migration re-snapshots on the next run
  # instead of silently skipping the guard.
  $SUDO touch "$MARKER"
  # Run status via sudo: /etc/garage.toml is 0640 root:garage, so an
  # unprivileged `garage status` fails with a confusing "Unable to read
  # configuration file" + "Permission denied" that looks like a service fault.
  $SUDO garage -c /etc/garage.toml status 2>&1 | head -20 \
    || warn "garage status did not respond yet (may still be opening the db)"
fi

# ── 8. garage buckets + keys ──────────────────────────────────────────────
# Buckets and keys are service state, so they cannot be deployed by copying a
# file. Reconcile them from the manifest installed above. Runs HERE, after
# garage is confirmed active, because on a fresh host the S3 API does not exist
# until step 7 completes. Without this, a restored garage metadata directory
# would leave every backup timer failing with a 403 that reads like a bad
# credential rather than missing state.
log "Garage buckets and keys"
act "$SUDO /usr/local/bin/garage-buckets-reconcile"

log "Done$( (( CHECK )) && printf ' (check mode — nothing changed)' )"
