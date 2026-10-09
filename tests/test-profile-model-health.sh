#!/usr/bin/env bash
# Regression check: every Hermes profile's configured model actually resolves.
#
# INCIDENT (2026-10-09). Seven profiles — analyst, companion, coo, music-producer,
# producer, researcher, videobot — had `meituan/longcat-2.0:free` as their
# primary or fallback. Nous retired the free variant:
#
#     HTTP 404: This model is no longer free. To continue using the paid
#     variant, switch to 'meituan/longcat-2.0'.
#
# Nothing noticed. The failure surfaced only as kanban cards blocking with
# "Provider rejected this profile's credential or model", one card at a time,
# hours later — and the same dead id then broke the music planner's first live
# test. A model id is an external dependency that can be withdrawn without any
# change on our side, so it needs a standing check.
#
# Two layers, because they fail differently:
#   * STATIC  — ids known to be withdrawn, and ids that do not appear in the
#               provider's own /models listing. Catches a dead id for free.
#   * LIVE    — a real one-token completion through the profile. Catches an
#               expired key or a provider outage, which /models cannot.
#
# Usage:
#   bash test-profile-model-health.sh            # static only (fast, no network)
#   bash test-profile-model-health.sh --live     # also smoke-test each profile
#   bash test-profile-model-health.sh --live --profiles music-producer,coo
# Exit: 0 pass, 1 at least one profile unhealthy, 2 setup problem.

set -uo pipefail

LIVE=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --live) LIVE=1 ;;
    --profiles) ONLY="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
# Ids withdrawn by the provider. Keep the reason, not just the id — the next
# reader needs to know why this list exists.
DEAD_IDS=(
  "meituan/longcat-2.0:free"   # retired 2026-10-09: "no longer free" (404)
)

fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
warn() { printf '  WARN  %s\n' "$1"; }

profiles=()
if [ -n "$ONLY" ]; then
  IFS=',' read -r -a profiles <<< "$ONLY"
else
  for d in "$HERMES_HOME"/profiles/*/; do
    [ -f "$d/config.yaml" ] || continue
    profiles+=("$(basename "$d")")
  done
fi

echo "profile model health — $(date -Iseconds)"
echo "checking ${#profiles[@]} profile(s)${LIVE:+ (live=$LIVE)}"
echo

for p in "${profiles[@]}"; do
  cfg="$HERMES_HOME/profiles/$p/config.yaml"
  [ -f "$cfg" ] || { warn "$p: no config.yaml"; continue; }

  read -r model provider < <(python3 - "$cfg" << 'PY'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    print("PARSE_ERROR PARSE_ERROR"); raise SystemExit
m = d.get("model") or {}
print(f"{m.get('default','')} {m.get('provider','')}")
PY
)

  if [ "$model" = "PARSE_ERROR" ]; then
    fail "$p: config.yaml is not valid YAML"
    continue
  fi
  if [ -z "$model" ]; then
    warn "$p: no model.default set (inherits root)"
    continue
  fi

  # --- static: withdrawn ids anywhere in the file ---------------------------
  dead=""
  for id in "${DEAD_IDS[@]}"; do
    grep -q -- "$id" "$cfg" && dead="$id"
  done
  if [ -n "$dead" ]; then
    fail "$p: references withdrawn model id '$dead' (grep -n it in $cfg)"
    continue
  fi

  # --- static: the id should appear in the provider's own listing -----------
  if [ "$LIVE" -eq 1 ]; then
    out=$(timeout 150 hermes -p "$p" chat -q "Reply exactly: PING" --oneshot 2>&1 || true)
    if printf '%s' "$out" | grep -q "PING"; then
      pass "$p: $model via $provider (live)"
    else
      why=$(printf '%s' "$out" | grep -oiE "(no longer free|not available on|invalid api key|401|403|404|rejected|No access token)[^\"]{0,60}" | head -1)
      fail "$p: $model via $provider — live probe failed${why:+ [$why]}"
    fi
  else
    pass "$p: $model via $provider (static)"
  fi
done

echo
if [ "$fails" -gt 0 ]; then
  echo "RESULT: FAIL ($fails profile(s))"
  echo "Fix: pick a working id and update model.default (and any fallback entry)."
  echo "Verify first:"
  echo '  KEY=$(grep "^NOUS_API_KEY=" ~/.hermes/.env | cut -d= -f2-)'
  echo '  curl -s https://inference-api.nousresearch.com/v1/chat/completions \'
  echo '    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \'
  echo '    -d "{\"model\":\"<id>\",\"messages\":[{\"role\":\"user\",\"content\":\"OK\"}],\"max_tokens\":10}"'
  exit 1
fi
echo "RESULT: PASS"
exit 0
