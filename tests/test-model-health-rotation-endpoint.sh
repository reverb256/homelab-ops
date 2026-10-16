#!/usr/bin/env bash
# Regression: the model-health rotator must repair the fleet, not re-break it.
#
# The failure this reproduces (nexus, 2026-10-16, card t_7d75bafd). A fleet-wide
# re-point of Hermes profile primaries was undone TWICE inside ten minutes by this
# daemon, and the daemon reported itself healthy while doing it:
#
#   $ ls ~/.hermes/cron/output/292b321c453a/ | tail -2
#   2026-10-16_17-00-57.md -> "ROTATED profile reviewer -> opencode-go/deepseek-v4.1-flash"
#   2026-10-16_17-10-56.md -> "ROTATED profile reviewer -> opencode-go/deepseek-v4.1-flash"
#
# Three defects, each asserted here:
#   1. the pool offered opencode-go/deepseek-v4.1-flash as a rotation TARGET — the
#      one provider whose probe passes in this daemon (it sends the required
#      x-opencode-session header; the agent path does not) and whose real API
#      answer is HTTP 400 MissingSessionID;
#   2. the rotation rewrote model.provider + model.default and LEFT model.base_url
#      alone. Left behind live: provider opencode-go with base_url
#      https://inference-api.nousresearch.com/v1 — the OpenCode model name sent to
#      the Nous host, dead on every call and invisible to `fleet-route.py audit`;
#   3. the probe read only `reasoning` and capped max_tokens at 64, so a HEALTHY
#      reasoning model (nvidia NIM answers {"content": null,
#      "reasoning_content": "..."} at 64 tokens) was reported SATURATED and had
#      its profiles handed to the rotator.
# And one contract: a panel judge (spec `judge_family`) must never be moved to
# another model family — the music review panel needs three DISJOINT families
# (music/rubrics/README.md, asserted by music/scripts/check_panel_membership.py).
#
# No network, no real state: HOME is sandboxed via MODEL_HEALTH_HOME, the spec via
# MODEL_HEALTH_SPEC, and curl is shimmed via MODEL_HEALTH_CURL.
# Run: bash tests/test-model-health-rotation-endpoint.sh
set -uo pipefail

DAEMON="${1:-$(cd "$(dirname "$0")/.." && pwd)/scripts/model-health-daemon.sh}"
[ -f "$DAEMON" ] || { echo "FAIL: daemon not found at $DAEMON"; exit 2; }

PASS=0
FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- the curl stand-in ------------------------------------------------------
# Answers per URL. opencode-go answers the REAL live body (HTTP 400
# MissingSessionID); nvidia answers a reasoning-only reply, which is a healthy
# answer for a reasoning model.
cat > "$TMP/fake-curl" <<'SH'
#!/usr/bin/env bash
url=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) body="$2"; shift 2 ;;
    -H|-m) shift 2 ;;
    -s) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
model=$(printf '%s' "$body" | sed -n 's/.*"model": *"\([^"]*\)".*/\1/p')
case "$url" in
  *opencode.ai*)
    if [ "${FAKE_OPENCODE_ANSWERS:-0}" = "1" ]; then
      # The trap this case exists for: the daemon's probe sends
      # x-opencode-session, the agent path does not — so opencode-go answers HERE
      # and returns HTTP 400 MissingSessionID to every real session.
      echo "{\"model\":\"$model\",\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"
    else
      echo '{"type":"error","error":{"type":"MissingSessionID","message":"Request is missing x-opencode-session and cannot be routed efficiently."}}'
    fi ;;
  *api.kilo.ai*)
    echo "{\"model\":\"$model\",\"choices\":[{\"message\":{\"content\":\"ok\"}}]}" ;;
  *integrate.api.nvidia.com*)
    echo "{\"model\":\"$model\",\"choices\":[{\"message\":{\"content\":null,\"reasoning_content\":\"we need to reply ok\"}}]}" ;;
  *inference-api.nousresearch.com*)
    if [ "${FAKE_NOUS_DEAD:-0}" = "1" ]; then
      echo '{"error":{"type":"upstream_unavailable"}}'
    else
      echo "{\"model\":\"$model\",\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"
    fi ;;
  *)
    echo "{\"model\":\"$model\",\"choices\":[{\"message\":{\"content\":\"ok\"}}]}" ;;
esac
SH
chmod +x "$TMP/fake-curl"
export MODEL_HEALTH_CURL="$TMP/fake-curl"
export MODEL_HEALTH_SSH="$TMP/fake-curl"

# ---- sandbox builder --------------------------------------------------------
# new_sandbox <dir> <pool-json>
new_sandbox() {
  local root="$1" pool="$2"
  mkdir -p "$root/.hermes/logs" "$root/.hermes/state/model-health" \
           "$root/.hermes/profiles/reviewer" "$root/ai-content-pipeline/scripts"
  for v in OPENCODE_GO_API_KEY KILOCODE_API_KEY NOUS_API_KEY NVIDIA_API_KEY \
           OPENROUTER_API_KEY; do printf '%s=fake-key\n' "$v" >> "$root/.hermes/.env"; done
  touch "$root/.hermes/state/model-health/live"     # LIVE, not dry-run
  cat > "$root/ai-content-pipeline/scripts/fleet-routing.json" <<JSON
{
  "dead_providers": ["opencode-go", "opencode-zen"],
  "dead_slugs": ["meituan/longcat-2.0:free"],
  "providers": {
    "opencode-go": {"base_url": "https://opencode.ai/zen/go/v1", "api_key_env": "OPENCODE_GO_API_KEY", "model": "deepseek-v4.1-flash"},
    "kilo": {"base_url": "https://api.kilo.ai/api/gateway", "api_key_env": "KILOCODE_API_KEY", "model": "kilo-auto/free"},
    "nous": {"base_url": "https://inference-api.nousresearch.com/v1", "api_key_env": "NOUS_API_KEY", "model": "poolside/laguna-s-2.1:free"},
    "nvidia": {"base_url": "https://integrate.api.nvidia.com/v1", "api_key_env": "NVIDIA_API_KEY", "model": "nvidia/nemotron-3-super-120b-a12b"}
  },
  "rotation_pool": $pool,
  "profiles": {"reviewer": {"judge_family": "dots-studio"}}
}
JSON
  # the DEFAULT profile (root config) and one worker, both on the dead provider
  cat > "$root/.hermes/config.yaml" <<'YAML'
model:
  default: deepseek-v4.1-flash
  provider: opencode-go
  base_url: https://opencode.ai/zen/go/v1
  api_mode: chat_completions
YAML
  cat > "$root/.hermes/profiles/reviewer/config.yaml" <<'YAML'
model:
  default: poolside/laguna-s-2.1:free
  provider: nous
  base_url: https://inference-api.nousresearch.com/v1
  api_mode: chat_completions
YAML
}

run_daemon() { MODEL_HEALTH_SPEC="$1/ai-content-pipeline/scripts/fleet-routing.json" \
               MODEL_HEALTH_HOME="$1" bash "$DAEMON"; }

# Push `nous` into the daemon's probe path the way the live host does it: enough
# rate errors in the log window to cross the threshold (THRESH rate = 8).
seed_saturation() {
  local root="$1" prov="$2" n="${3:-8}" i=0
  while [ "$i" -lt "$n" ]; do
    echo "2026-10-16 18:0$i ERROR model_tools provider=$prov HTTP 429 rate limit" \
      >> "$root/.hermes/logs/agent.log"
    i=$((i + 1))
  done
}

# =============================================================================
echo "== case 1: consumers of a dead provider are rotated off it, endpoint FOLLOWS =="
S1="$TMP/c1"
new_sandbox "$S1" '[{"provider":"nous","model":"meituan/longcat-2.0:free"},
                    {"provider":"kilo","model":"kilo-auto/free"},
                    {"provider":"nvidia","model":"nvidia/nemotron-3-super-120b-a12b"}]'
OUT=$(run_daemon "$S1" 2>&1)
echo "$OUT" | sed 's/^/    | /'
grep -q "DEAD for API callers" <<<"$OUT" \
  && ok "a provider whose call cannot be served is reported DEAD without an error window" \
  || bad "no DEAD line for opencode-go (the daemon still waits for the error window)"
grep -q "ROTATED profile default -> kilo/kilo-auto/free" <<<"$OUT" \
  && ok "the DEFAULT profile is rotated onto the first LIVE pool target" \
  || bad "default profile not rotated onto kilo (pool order: dead slug, then kilo)"
grep -q "kilo-auto/free" <<<"$OUT" || bad "rotation did not reach the pool's live target"

# The pool's FIRST entry carries a slug the spec lists as dead -> it must be
# skipped even though its provider answers.
CFG1="$S1/.hermes/config.yaml"
grep -q "^  provider: kilo$" "$CFG1" \
  && ok "rotated config names the new provider" || bad "provider did not move: $(grep -m1 provider "$CFG1")"
grep -q "^  default: kilo-auto/free$" "$CFG1" \
  && ok "rotated config names the new model" || bad "model did not move: $(grep -m1 default "$CFG1")"
grep -q "^  base_url: https://api.kilo.ai/api/gateway$" "$CFG1" \
  && ok "model.base_url FOLLOWS the provider (the measured defect: it did not)" \
  || bad "base_url left stale: $(grep -m1 base_url "$CFG1")"
grep -q "longcat-2.0:free" "$CFG1" \
  && bad "rotated onto a DEAD SLUG" \
  || ok "no dead slug reached the config"

echo "== case 2: a reasoning-only reply is an ANSWER, not saturation =="
S2="$TMP/c2"
new_sandbox "$S2" '[{"provider":"nvidia","model":"nvidia/nemotron-3-super-120b-a12b"},
                    {"provider":"kilo","model":"kilo-auto/free"}]'
OUT2=$(run_daemon "$S2" 2>&1)
echo "$OUT2" | sed 's/^/    | /'
grep -q "nvidia.*SATURATED" <<<"$OUT2" \
  && bad "a reasoning-only reply (reasoning_content) still counts as saturation" \
  || ok "reasoning_content counts as an answer (nvidia NIM shape)"
grep -q "ROTATED profile default -> nvidia/nvidia/nemotron-3-super-120b-a12b" <<<"$OUT2" \
  && ok "the reasoning model is used as a target" \
  || bad "the first live target was not nvidia"

echo "== case 3: a panel judge never moves across model families =="
S3="$TMP/c3"
new_sandbox "$S3" '[{"provider":"kilo","model":"kilo-auto/free"},
                    {"provider":"nous","model":"poolside/laguna-s-2.1:free"}]'
seed_saturation "$S3" nous
OUT3=$(FAKE_NOUS_DEAD=1 run_daemon "$S3" 2>&1)
echo "$OUT3" | sed 's/^/    | /'
grep -q "same-family (dots-studio)" <<<"$OUT3" \
  && ok "a judge with no same-family target is left alone, loudly" \
  || bad "the judge's family contract was ignored (no same-family line)"
grep -q "^  provider: nous$" "$S3/.hermes/profiles/reviewer/config.yaml" \
  && ok "the judge's config was NOT changed to another family" \
  || bad "the judge was moved cross-family"

S4="$TMP/c4"
new_sandbox "$S4" '[{"provider":"kilo","model":"dots-studio/dots-3-note-preview:free"},
                    {"provider":"nous","model":"poolside/laguna-s-2.1:free"}]'
seed_saturation "$S4" nous
OUT4=$(FAKE_NOUS_DEAD=1 run_daemon "$S4" 2>&1)
echo "$OUT4" | sed 's/^/    | /'
grep -q "ROTATED profile reviewer -> kilo/dots-studio/dots-3-note-preview:free" <<<"$OUT4" \
  && ok "with a same-family target available the judge IS healed" \
  || bad "same-family target not used for the judge"
grep -q "^  base_url: https://api.kilo.ai/api/gateway$" "$S4/.hermes/profiles/reviewer/config.yaml" \
  && ok "the judge's endpoint followed its new provider too" \
  || bad "judge base_url did not follow the provider"

echo "== case 5: a spec-dead provider whose PROBE answers still gets consumers moved =="
# Measured 2026-10-16: opencode-go answers 200 to this daemon's probe (it sends the
# required x-opencode-session header) and HTTP 400 MissingSessionID to every real
# session. If the dead list were this probe's opinion, the rotator would keep the
# fleet ON it — which is exactly what v2 did.
S5="$TMP/c5"
new_sandbox "$S5" '[{"provider":"kilo","model":"kilo-auto/free"}]'
OUT5=$(FAKE_OPENCODE_ANSWERS=1 run_daemon "$S5" 2>&1)
echo "$OUT5" | sed 's/^/    | /'
grep -q "listed DEAD in the spec but this probe ANSWERS" <<<"$OUT5" \
  && ok "a green probe no longer overrules the spec's dead list" \
  || bad "the dead list was overruled by a green probe (or the line is missing)"
grep -q "ROTATED profile default -> kilo/kilo-auto/free" <<<"$OUT5" \
  && ok "consumers are still rotated off a spec-dead provider" \
  || bad "the consumer stayed on the dead provider"
grep -q "^  provider: opencode-go$" "$S5/.hermes/config.yaml" \
  && bad "the config still names the dead provider" \
  || ok "the config no longer names the dead provider"

echo
echo "rotation-endpoint regression: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
