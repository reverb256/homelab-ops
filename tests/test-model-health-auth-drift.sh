#!/usr/bin/env bash
# Regression: the model-health rotator must SEE the class it was blind to.
#
# The failure this reproduces (nexus, 2026-09-22):
#   * the DEFAULT profile answered "HTTP 401: Upstream request failed: Invalid
#     credential" for provider opencode-go — it is the profile that answers inbound
#     A2A, i.e. the on-call responder for money halts;
#   * the daemon logged "opencode-go: threshold {'auth': 3, 'quota': 1} but probe OK
#     -> no action";
#   * two ticks later the line window had aged the breach out entirely
#     (14:10 auth:3 -> 14:20 absent) and the signal silently vanished.
#
# Two defects, both asserted here:
#   1. the probe uses the ROOT env key, so a green probe proves the store/root
#      credential works and says NOTHING about a profile-scoped stale copy — the
#      daemon cleared an auth signal on evidence that did not cover the consumer;
#   2. the rotation scope was `profiles/*/config.yaml`, which excludes the default
#      profile — the one that was actually failing.
#
# No network, no real state: HOME is sandboxed via MODEL_HEALTH_HOME and curl/ssh
# are shimmed. Run: bash tests/test-model-health-auth-drift.sh
set -uo pipefail

DAEMON="${1:-$(cd "$(dirname "$0")/.." && pwd)/scripts/model-health-daemon.sh}"
[ -f "$DAEMON" ] || { echo "FAIL: daemon not found at $DAEMON"; exit 2; }

PASS=0
FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.hermes/logs" "$TMP/.hermes/state/model-health" \
         "$TMP/homelab-ops/scripts" "$TMP/.local/bin"

# The root key EXISTS, so the probe is not skipped for "missing key" — a green
# root probe is the whole point of the reproduction.
printf 'OPENCODE_GO_API_KEY=fake-root-key-value\n' > "$TMP/.hermes/.env"

# The default profile is pinned to the failing provider.
cat > "$TMP/.hermes/config.yaml" <<'YAML'
model:
  default: deepseek-v4.1-flash
  provider: opencode-go
YAML

# Green probe regardless of the key presented (the daemon's own probe passes —
# that is the trap: it validates the root credential, not the consumer's).
cat > "$TMP/fake-curl" <<'SH'
#!/usr/bin/env bash
echo '{"choices":[{"message":{"content":"ok"}}]}'
SH

# ssh shim: run the delegated renderer command locally instead of on zephyr.
cat > "$TMP/fake-ssh" <<'SH'
#!/usr/bin/env bash
shift 3          # -o ConnectTimeout=8 <host>
exec bash -c "$*"
SH

# The store disagrees with this host's env -> the drift the lane repaired by hand.
# (Invoked as `/usr/bin/python3 <path>`, so it must be Python.)
cat > "$TMP/homelab-ops/scripts/provider-key-render.py" <<'PY'
print("  OPENCODE_GO_API_KEY: store len=51 fp=aaaa1111 host len=51 fp=bbbb2222 -> DRIFTED")
raise SystemExit(1)
PY
chmod +x "$TMP/fake-curl" "$TMP/fake-ssh" \
         "$TMP/homelab-ops/scripts/provider-key-render.py"

# The seams: without these the probe would hit the REAL provider (the script's
# PATH puts /usr/bin ahead of $HOME/.local/bin, so a PATH shim would be shadowed).
export MODEL_HEALTH_CURL="$TMP/fake-curl"
export MODEL_HEALTH_SSH="$TMP/fake-ssh"

# The live signal: three credential-invalid rows for that provider.
for i in 1 2 3; do
  echo "2026-09-22 12:58:0$i ERROR model_tools provider=opencode-go HTTP 401: Upstream request failed: Invalid credential" \
    >> "$TMP/.hermes/logs/agent.log"
done
touch "$TMP/.hermes/state/model-health/live"

echo "== case 1: auth breach + stale consumer credential + GREEN root probe =="
STATE_BEFORE=$(find "$TMP/.hermes/state/model-health" -type f | wc -l)
ENV_BEFORE=$(md5sum "$TMP/.hermes/.env" | cut -d' ' -f1)

set +e
OUT=$(MODEL_HEALTH_HOME="$TMP" bash "$DAEMON" --check 2>&1)
RC=$?
set -e

echo "$OUT" | sed 's/^/    | /'
echo "$OUT" | grep -q "AUTH-DRIFT opencode-go" \
  && ok "the auth signal is reported as AUTH-DRIFT (was: 'probe OK -> no action')" \
  || bad "no AUTH-DRIFT line for opencode-go"
echo "$OUT" | grep -q "probe OK -> no action" \
  && bad "still clearing the auth signal on a green root-key probe" \
  || ok "a green root probe no longer clears the auth signal"
echo "$OUT" | grep -q "WOULD re-render" \
  && ok "the repair direction is from the store (source of truth)" \
  || bad "no store re-render proposed"
[ "$RC" -eq 1 ] && ok "--check exits nonzero on an active credential-invalid signal" \
                || bad "--check exit code was $RC, expected 1"

STATE_AFTER=$(find "$TMP/.hermes/state/model-health" -type f | wc -l)
[ "$STATE_BEFORE" -eq "$STATE_AFTER" ] && ok "--check wrote no state" \
  || bad "--check changed the state dir ($STATE_BEFORE -> $STATE_AFTER)"
[ ! -f "$TMP/.hermes/state/model-health/history.jsonl" ] && ok "--check wrote no history row" \
  || bad "--check appended a history row"
[ "$ENV_BEFORE" = "$(md5sum "$TMP/.hermes/.env" | cut -d' ' -f1)" ] && ok "--check did not rewrite .env" \
  || bad "--check rewrote .env"

echo "== case 2: default profile is in the rotation scope =="
# Make the credential genuinely rejected (store in sync) -> the daemon must rotate
# consumers off the provider, and the default profile must be among them.
cat > "$TMP/homelab-ops/scripts/provider-key-render.py" <<'PY'
print("  OPENCODE_GO_API_KEY: in sync (len=51 fp=aaaa1111)")
raise SystemExit(0)
PY
chmod +x "$TMP/homelab-ops/scripts/provider-key-render.py"
set +e
OUT2=$(MODEL_HEALTH_HOME="$TMP" bash "$DAEMON" --check 2>&1)
set -e
echo "$OUT2" | sed 's/^/    | /'
echo "$OUT2" | grep -q "AUTH-SIGNAL opencode-go" \
  && ok "an in-sync credential is still reported as an active auth signal" \
  || bad "no AUTH-SIGNAL line when the credential itself is rejected"
echo "$OUT2" | grep -qE "WOULD ROTATE .*profile default" \
  && ok "the DEFAULT profile is in the rotation scope" \
  || bad "the default profile is still out of scope"

echo "== case 3: negative control (no auth rows) =="
: > "$TMP/.hermes/logs/agent.log"
rm -f "$TMP/.hermes/state/model-health"/auth-breach-* 2>/dev/null
set +e
OUT3=$(MODEL_HEALTH_HOME="$TMP" bash "$DAEMON" --check 2>&1)
RC3=$?
set -e
echo "$OUT3" | grep -q "AUTH-" && bad "flagged an auth signal with a clean log" \
                                || ok "no auth signal on a clean log"
[ "$RC3" -eq 0 ] && ok "--check exits 0 when there is nothing to flag" \
                 || bad "--check exit code was $RC3 on a clean log, expected 0"

echo
echo "auth-drift regression: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
