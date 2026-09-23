#!/usr/bin/env bash
# Sync the Hermes-consumed keys from the secretspec manifest into ~/.hermes/.env.
# Source of truth: the secretspec contract + ~/Work/Projects/nixos-secrets (sops values).
#
# `--check` resolves every route and reports drift WITHOUT writing anything.
# Exit 1 on drift or an unresolved route, so a timer can watch it.
set -u

export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
MANIFEST="$HOME/.config/secretspec/secretspec-zephyr.toml"
ENVF="$HOME/.hermes/.env"
SECRETSPEC="${SECRETSPEC:-$HOME/.local/bin/secretspec}"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

[ -x "$SECRETSPEC" ] || { echo "FAIL: secretspec not executable at $SECRETSPEC" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "FAIL: $MANIFEST missing - run secretspec-manifest-sync.sh" >&2; exit 1; }
[ -d "$(dirname "$ENVF")" ] || { echo "FAIL: $(dirname "$ENVF") missing" >&2; exit 1; }
touch "$ENVF"

WORK=$(mktemp) || exit 1
trap 'rm -f "$WORK" "$WORK.f"' EXIT
chmod 600 "$WORK"
cp "$ENVF" "$WORK"

# route name | env var to write. One line per key. Names only - never values.
ROUTES="
OPENROUTER_API_KEY:OPENROUTER_API_KEY
NVIDIA_API_KEY:NVIDIA_API_KEY
OPENCODE_ZEN_API_KEY:OPENCODE_ZEN_API_KEY
OPENCODE_ZEN_API_KEY:OPENCODE_API_KEY
OPENCODE_GO_API_KEY:OPENCODE_GO_API_KEY
EXA_API_KEY:EXA_API_KEY
PARALLEL_API_KEY:PARALLEL_API_KEY
GITHUB_TOKEN:GITHUB_TOKEN
KILO_API_KEY:KILOCODE_API_KEY
N8N_API_KEY:N8N_API_KEY
"

synced=0; failed=0; drift=0; failed_vars=""; drift_vars=""

current_value() { # read the current value of a var from a dotenv file
  sed -n "s/^$1=//p" "$2" | head -1
}

for entry in $ROUTES; do
  route="${entry%%:*}"; var="${entry##*:}"
  val=$("$SECRETSPEC" get "$route" --file "$MANIFEST" -P production 2>/dev/null | tr -d '\r\n')
  if [ -z "$val" ]; then
    echo "WARN: $var: route '$route' unresolved, left .env untouched" >&2
    failed=$((failed+1)); failed_vars="$failed_vars $var"
    continue
  fi
  if [ "$CHECK" -eq 1 ]; then
    have=$(current_value "$var" "$ENVF")
    if [ "$have" != "$val" ]; then
      state="ABSENT"; [ -n "$have" ] && state="DIFFERS"
      echo "DRIFT: $var $state vs the store (route $route)"
      drift=$((drift+1)); drift_vars="$drift_vars $var"
    else
      synced=$((synced+1))
    fi
    continue
  fi
  grep -v "^${var}=" "$WORK" > "$WORK.f" || true
  printf '%s=%s\n' "$var" "$val" >> "$WORK.f"
  mv "$WORK.f" "$WORK"
  synced=$((synced+1))
done

if [ "$CHECK" -eq 1 ]; then
  echo "check: $synced in sync, $drift drifted, $failed unresolved"
  [ "$drift" -eq 0 ] && [ "$failed" -eq 0 ] || { echo "FAIL:${drift_vars}$failed_vars" >&2; exit 1; }
  echo "OK: .env matches the manifest on every routed key"
  exit 0
fi

if ! cmp -s "$ENVF" "$WORK"; then
  mv "$WORK" "$ENVF"
  chmod 600 "$ENVF"
  echo "updated $synced key(s) in $ENVF"
else
  echo "no changes (.env already matches manifest)"
fi

if [ "$failed" -gt 0 ]; then
  echo "FAIL: $failed key(s) not synced:$failed_vars" >&2
  exit 1
fi
echo "OK: $synced keys in sync with secretspec manifest"
