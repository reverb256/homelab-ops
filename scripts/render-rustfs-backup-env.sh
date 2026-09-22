#!/usr/bin/env bash
# render-rustfs-backup-env.sh — materialize the RustFS backup credentials from
# the encrypted sops store onto the host that runs the RustFS backup script.
#
# Run from zephyr (the host that holds the age keys; nexus cannot decrypt the
# store). Idempotent. Prints fingerprints only, never values.
#
#   usage: render-rustfs-backup-env.sh
#   env:   RUSTFS_SECRETS_STORE (default ~/Work/Projects/nixos-secrets)
#          RUSTFS_SECRETS_HOST  (default nexus)
#          RUSTFS_ENV_FILE      (default /home/j_kro/.config/rustfs/backup.env)
#
# Store entries (nixos-secrets/secrets/storage/):
#   rustfs-backup-access-key-id.yaml     -> AWS_ACCESS_KEY_ID
#   rustfs-backup-secret-access-key.yaml -> AWS_SECRET_ACCESS_KEY
# Consumer: $HOST:/usr/local/bin/backup-to-rustfs.sh (sources the env file; the
# credentials are never inline in the script).
set -euo pipefail

STORE="${RUSTFS_SECRETS_STORE:-$HOME/Work/Projects/nixos-secrets}"
HOST="${RUSTFS_SECRETS_HOST:-nexus}"
TARGET="${RUSTFS_ENV_FILE:-/home/j_kro/.config/rustfs/backup.env}"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/cluster-age-key.txt}"

die() { echo "error: $*" >&2; exit 1; }
[ -d "$STORE/secrets/storage" ] || die "store not found at $STORE/secrets/storage"
command -v sops >/dev/null || die "sops not installed"

get() { sops -d --output-type json "$STORE/secrets/storage/$1.yaml" \
        | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["data"])'; }
fp()  { printf '%s' "$1" | sha256sum | cut -c1-12; }

AK="$(get rustfs-backup-access-key-id)"
SK="$(get rustfs-backup-secret-access-key)"
[ -n "$AK" ] || die "access key id empty in the store"
[ -n "$SK" ] || die "secret access key empty in the store"
echo "rustfs backup creds: access_key_id fp=$(fp "$AK")  secret fp=$(fp "$SK")"

DIR="$(dirname "$TARGET")"
ssh -n "$HOST" "mkdir -p $DIR && chmod 700 $DIR"
{
  printf 'export AWS_ACCESS_KEY_ID=%s\n' "$AK"
  printf 'export AWS_SECRET_ACCESS_KEY=%s\n' "$SK"
} | ssh "$HOST" "install -m600 /dev/stdin $TARGET"

echo "wrote $HOST:$TARGET (0600)"
echo "verify: ssh $HOST 'AWS_ACCESS_KEY_ID= AWS_SECRET_ACCESS_KEY= bash /usr/local/bin/backup-to-rustfs.sh' (or the aws s3 ls line)"
