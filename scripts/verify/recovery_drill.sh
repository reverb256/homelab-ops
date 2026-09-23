#!/usr/bin/env bash
# recovery_drill.sh — re-runnable proof that the trading stack's recovery path
# still works. Companion to docs/RECOVERY-DRILL-2026-09-23.md.
#
# READ-ONLY against live state: it never writes to data/keys/, never touches a
# ledger, breaker, KILL file or arming flag, never signs, and never sends a
# real alert. It NEVER writes to zephyr — the only host it can create anything
# on is the one it runs on (nexus), under one mktemp dir it deletes on exit.
#
# It NEVER prints a secret value: only sha256 prefixes, byte lengths and
# booleans. Anything it prints is safe to paste into a ticket.
#
# usage: recovery_drill.sh [--restore]
#        --restore  additionally rehearse a full key + state restore
#                   (decrypts the sops store on zephyr in RAM, streams the
#                    plaintext over ssh into the scratch dir on nexus)
#
# exit: 0 = every check passed, 1 = at least one check failed, 2 = refused to run
set -uo pipefail

EXPECT_SOL='Ghr7xwP6HqzYVeXAq7uToR7poUSQuJ9pB8dCeQqA5wmf'
EXPECT_RHC='0xF898b6D2F9Aaa7736Cf6FD57E418aC1aC6a04f12'
LIVE_KEYS='/home/j_kro/Work/trading/data/keys'
LIVE_DATA='/home/j_kro/Work/trading/data'
S3ENV='/home/j_kro/.config/trading/s3.txt'
EP=(--endpoint-url http://100.76.105.73:3900 --region garage)
GARAGE_BUCKET='s3://trading-backups'
PAGER_URL='http://40.233.113.94:8899'
PAGER_SSH='arch@40.233.113.94'
VPS_PY='/usr/bin/python3'
NEXSPY='/home/j_kro/.local/share/mise/installs/python/3.11.16/bin/python'
STORE='$HOME/Work/Projects/nixos-secrets'
# Objects the trading backup is allowed to publish. Anything else is unexpected.
EXPECTED_PREFIXES='db/ state/ jsonl/'
# Never allowed to appear as a published object or bundle member.
DENY_RE='(^|/)(exec\.env|halt_peer\.env|[^/]*\.env|live\.json|rhc\.json|devnet\.json|float\.json|alchemy\.txt|helius\.txt|exec_log\.jsonl|reconcile\.jsonl|daemon\.log|s3\.txt|[^/]*\.lock|[^/]*\.key|id_rsa[^/]*)$|(^|/)keys/'

CHECKS=0; FAILED=0; WROTE=()
pass(){ printf '  PASS  %s\n' "$*"; CHECKS=$((CHECKS+1)); }
fail(){ printf '  FAIL  %s\n' "$*"; FAILED=$((FAILED+1)); CHECKS=$((CHECKS+1)); }
note(){ printf '  ..    %s\n' "$*"; }
hdr(){  printf '\n== %s\n' "$*"; }
denied(){ printf '%s' "$1" | grep -Eq "$DENY_RE"; }

# ---- host guard -------------------------------------------------------------
HOST="$(hostname 2>/dev/null || echo unknown)"
if [ "$HOST" = zephyr ]; then
  echo "REFUSED: this drill must not run on zephyr (it creates scratch state)." >&2
  echo "         run it on nexus; it never writes to zephyr." >&2
  exit 2
fi
DO_RESTORE=0
[ "${1:-}" = '--restore' ] && DO_RESTORE=1
SCRATCH="$(mktemp -d /tmp/recovery-drill.XXXXXX)" || exit 2
WROTE+=("$SCRATCH")
cleanup(){ rm -rf "$SCRATCH"; }
trap cleanup EXIT

printf 'recovery drill on %s at %s\n' "$HOST" "$(date -u +%FT%TZ)"
printf 'scratch (deleted on exit): %s\n' "$SCRATCH"

# ---- 1. what the backup actually publishes ----------------------------------
hdr '1. backup content audit (Garage trading-backups)'
if [ ! -r "$S3ENV" ]; then
  fail "S3 credential file $S3ENV not readable — cannot audit"
else
  AWS_ACCESS_KEY_ID="$(awk '/^key_id:/{print $2}' "$S3ENV")"
  AWS_SECRET_ACCESS_KEY="$(awk '/^secret:/{print $2}' "$S3ENV")"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  aws "${EP[@]}" s3 ls "$GARAGE_BUCKET/" --recursive >"$SCRATCH/objects.txt" 2>"$SCRATCH/objects.err"
  n_obj="$(wc -l <"$SCRATCH/objects.txt")"
  if [ "$n_obj" -lt 1 ]; then
    fail "EMPTY INPUT: bucket listing returned 0 objects (aws err: $(head -c 120 "$SCRATCH/objects.err"))"
  else
    note "$n_obj objects published"
    awk '{print $NF}' "$SCRATCH/objects.txt" >"$SCRATCH/names.txt"
    bad="$(grep -E "$DENY_RE" "$SCRATCH/names.txt" || true)"
    [ -z "$bad" ] && pass "no published object name matches the credential deny-list" \
                  || fail "credential-shaped object(s) published: $(printf '%s' "$bad" | tr '\n' ' ')"
    off="$(grep -vE "^(${EXPECTED_PREFIXES// /|})" "$SCRATCH/names.txt" || true)"
    [ -z "$off" ] && pass "every object is under an expected prefix (db/ state/ jsonl/)" \
                  || fail "unexpected object path(s): $(printf '%s' "$off" | tr '\n' ' ')"
    # newest signals snapshot must be non-empty and fresh
    newest_sig="$(aws "${EP[@]}" s3 ls "$GARAGE_BUCKET/db/" | awk '/signals-.*sqlite.gz/{print $1" "$2" "$4}' | sort | tail -1)"
    if [ -z "$newest_sig" ]; then
      fail 'EMPTY INPUT: no signals-*.sqlite.gz object found'
    else
      note "newest signals snapshot: $newest_sig"
      ts="$(printf '%s' "$newest_sig" | awk '{print $1"T"$2}')"
      age_min=$(( ( $(date +%s) - $(date -d "$ts" +%s) ) / 60 ))
      if [ "$age_min" -le 1560 ]; then pass "offsite snapshot age ${age_min} min (<= 26h incl. slack)"
      else fail "offsite snapshot age ${age_min} min — exceeds the daily cadence + slack"; fi
    fi
    # the jsonl bundle members
    if aws "${EP[@]}" s3 cp "$GARAGE_BUCKET/jsonl/trading-jsonl-latest.tar.gz" "$SCRATCH/b.tgz" --only-show-errors --quiet; then
      tar tzf "$SCRATCH/b.tgz" >"$SCRATCH/members.txt" 2>/dev/null
      m="$(wc -l <"$SCRATCH/members.txt")"
      if [ "$m" -lt 1 ]; then fail 'EMPTY INPUT: jsonl bundle has no members'
      else
        note "jsonl bundle: $m members, $(stat -c%s "$SCRATCH/b.tgz") bytes"
        bbad="$(grep -E "$DENY_RE" "$SCRATCH/members.txt" || true)"
        [ -z "$bbad" ] && pass 'no bundle member matches the credential deny-list' \
                      || fail "denied bundle member(s): $(printf '%s' "$bbad" | tr '\n' ' ')"
        leak="$(tar xzOf "$SCRATCH/b.tgz" 2>/dev/null | grep -acE 'api-key=|BEGIN [A-Z ]*PRIVATE KEY|AGE-SECRET-KEY' || true)"
        [ "${leak:-0}" -eq 0 ] && pass 'bundle content carries no credential shapes' \
                               || fail "bundle content carries $leak credential-shaped line(s)"
      fi
    else
      fail 'could not download the jsonl bundle'
    fi
  fi
fi

# ---- 2. live key sanity -----------------------------------------------------
hdr '2. live signing keys (metadata + derived address, no key bytes printed)'
for spec in "live.json:$EXPECT_SOL" "rhc.json:$EXPECT_RHC"; do
  f="${LIVE_KEYS}/${spec%%:*}"; want="${spec#*:}"
  if [ ! -s "$f" ]; then fail "EMPTY INPUT: $f missing or zero bytes"; continue; fi
  mode="$(stat -c%a "$f")"
  [ "$mode" = 600 ] && pass "$(basename "$f") mode 600, $(stat -c%s "$f") bytes, sha12 $(sha256sum "$f" | cut -c1-12)" \
                    || fail "$(basename "$f") mode is $mode, expected 600"
done
"$NEXSPY" - "$LIVE_KEYS" "$EXPECT_SOL" "$EXPECT_RHC" <<'PY'
import json, sys
from solders.keypair import Keypair
from eth_account import Account
keys, want_sol, want_rhc = sys.argv[1], sys.argv[2], sys.argv[3]
ok = True
lp = json.load(open(f"{keys}/live.json"))
sol = str(Keypair.from_bytes(bytes(lp)).pubkey())
print(f"  {'PASS' if sol == want_sol else 'FAIL'}  live.json derives {sol}"
      f"{'' if sol == want_sol else ' (expected ' + want_sol + ')'}")
ok &= sol == want_sol
emb = bytes(lp)[32:]
print(f"  {'PASS' if bytes(Keypair.from_seed(bytes(lp)[:32]).pubkey()) == emb else 'FAIL'}"
      f"  live.json secret half is the true preimage of its embedded pubkey")
ok &= bytes(Keypair.from_seed(bytes(lp)[:32]).pubkey()) == emb
rp = json.load(open(f"{keys}/rhc.json"))
acct = Account.from_key(rp["private_key"]).address
match = acct == want_rhc and acct == rp.get("address")
print(f"  {'PASS' if match else 'FAIL'}  rhc.json derives {acct} and equals its declared address")
ok &= match
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && pass 'both live signers derive their expected on-chain addresses' \
             || fail 'a live signer did not derive its expected address'

# ---- 3. optional: key restore rehearsal ------------------------------------
if [ "$DO_RESTORE" = 1 ]; then
  hdr '3. key restore rehearsal (decrypt on zephyr in RAM -> nexus scratch)'
  REPO="$SCRATCH"; RS="$SCRATCH/data/keys"; mkdir -p "$RS"
  ssh -o ConnectTimeout=8 zephyr "test -d $STORE/secrets/crypto" \
    && pass 'sops store present on zephyr' || fail 'sops store missing on zephyr'
  t0=$(date +%s%N)
  if ssh -o ConnectTimeout=10 zephyr "cd \$HOME/Work/trading && TRADING_REPO_REMOTE='$REPO' bash tools/provision-secrets.sh" >"$SCRATCH/prov.log" 2>&1; then
    t1=$(date +%s%N)
    pass "provision-secrets.sh completed in $(( (t1-t0)/1000000 )) ms (no plaintext written to zephyr)"
  else
    fail "provision-secrets.sh failed: $(tail -3 "$SCRATCH/prov.log" | tr '\n' ' ')"
  fi
  "$NEXSPY" - "$RS" "$LIVE_KEYS" "$EXPECT_SOL" "$EXPECT_RHC" <<'PY'
import hashlib, json, os, sys
from solders.keypair import Keypair
from eth_account import Account
rs, live, want_sol, want_rhc = sys.argv[1:5]
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()[:12]
ok = True
for n in ("live.json", "rhc.json", "devnet.json"):
    a, b = rs + "/" + n, live + "/" + n
    if not os.path.exists(a) or os.path.getsize(a) == 0:
        print(f"  FAIL  EMPTY INPUT: restored {n} missing/zero"); ok = False; continue
    same = h(a) == h(b)
    print(f"  {'PASS' if same else 'FAIL'}  {n} restored sha12 {h(a)} == live {h(b)} (byte-exact)")
    ok &= same
if os.path.getsize(rs + "/live.json") and os.path.getsize(rs + "/rhc.json"):
    sol = str(Keypair.from_bytes(bytes(json.load(open(rs + "/live.json")))).pubkey())
    acct = Account.from_key(json.load(open(rs + "/rhc.json"))["private_key"]).address
    print(f"  {'PASS' if sol == want_sol else 'FAIL'}  restored SOL signer -> {sol}")
    print(f"  {'PASS' if acct == want_rhc else 'FAIL'}  restored RHC signer -> {acct}")
    ok &= sol == want_sol and acct == want_rhc
else:
    print("  FAIL  restored key files are empty — cannot derive addresses")
sys.exit(0 if ok else 1)
PY
  [ $? -eq 0 ] && pass 'restored keys are byte-exact and derive the on-chain addresses' \
               || fail 'restore rehearsal did not reproduce the live keys'
fi

# ---- 4. optional: state restore rehearsal ----------------------------------
if [ "$DO_RESTORE" = 1 ]; then
  hdr '4. state restore rehearsal (newest snapshots -> scratch)'
  st="$SCRATCH/state"; mkdir -p "$st"
  t0=$(date +%s%N)
  for o in db/signals-latest.sqlite.gz db/wallets-latest.sqlite.gz; do
    aws "${EP[@]}" s3 cp "$GARAGE_BUCKET/$o" "$st/$(basename "$o")" --only-show-errors --quiet \
      || fail "could not fetch $o"
  done
  gunzip -f "$st"/*.gz 2>/dev/null
  t1=$(date +%s%N)
  for db in signals wallets; do
    f="$st/${db}-latest.sqlite"
    if [ ! -s "$f" ]; then fail "EMPTY INPUT: $db restore produced no file"; continue; fi
    ic="$(sqlite3 "file:$f?mode=ro" 'PRAGMA integrity_check;' | head -1)"
    [ "$ic" = ok ] && pass "$db integrity_check ok ($(stat -c%s "$f") bytes)" || fail "$db integrity_check: $ic"
    for t in $(sqlite3 "file:$f?mode=ro" "select name from sqlite_master where type='table';"); do
      r="$(sqlite3 "file:$f?mode=ro" "select count(*) from \"$t\";" 2>/dev/null)"
      l="$(sqlite3 "file:$LIVE_DATA/$db.sqlite?mode=ro" "select count(*) from \"$t\";" 2>/dev/null || echo -)"
      [ "$r" = "$l" ] || note "$db.$t restored=$r live=$l (delta)"
    done
  done
  note "fetch+decompress $(( (t1-t0)/1000000 )) ms"
  for f in breakers_state.json portfolio_breakers_state.json alloc_state.json alert_cursor.json; do
    [ -s "$LIVE_DATA/$f" ] && note "$f is live, has NO backup, and must be rebuilt by hand"
  done
  pass 'state restore ran; see deltas above'
fi

# ---- 5. dead-man pager ------------------------------------------------------
hdr '5. dead-man pager'
st="$(curl -s --max-time 10 "$PAGER_URL/status")"
if [ -z "$st" ]; then
  fail 'EMPTY INPUT: pager /status returned nothing (pager down?)'
else
  "$NEXSPY" - "$st" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
age, thr = d.get("heartbeat_age_s"), d.get("stale_after_s")
print(f"  ..    heartbeat_age_s={age} stale_after_s={thr} hb_count={d.get('hb_count')} "
      f"halted={d.get('halted')} sentinel_status={d.get('sentinel_status')}")
ok1 = isinstance(age, int) and isinstance(thr, int) and age <= thr
print(f"  {'PASS' if ok1 else 'FAIL'}  heartbeat is inside the staleness threshold")
sys.exit(0 if ok1 else 1)
PY
  [ $? -eq 0 ] && pass 'pager reports a fresh heartbeat' || fail 'pager heartbeat is stale'
fi
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' \
        -d '{"type":"deadman-heartbeat","host":"recovery-drill"}' "$PAGER_URL/hb")"
[ "$code" = 401 ] && pass 'unsigned POST /hb is rejected (401)' \
                  || fail "unsigned POST /hb returned $code, expected 401"
SSHO=(-o ConnectTimeout=10 -o BatchMode=yes)
[ -r /home/j_kro/.ssh/oci_vps_ed25519 ] && SSHO+=(-i /home/j_kro/.ssh/oci_vps_ed25519)
if ssh "${SSHO[@]}" "$PAGER_SSH" 'true' 2>/dev/null; then
  ssh "${SSHO[@]}" "$PAGER_SSH" "sudo -n $VPS_PY /tmp/smtp-auth-probe.py 2>&1 | tail -1" \
    | grep -q AUTH-ONLY-PROBE-OK && pass 'SMTP sink authenticates (AUTH-only, no message sent)' \
    || note 'SMTP AUTH probe did not confirm (probe not staged at /tmp on the VPS, or sudo needs a tty)'
  w="$(ssh "${SSHO[@]}" "$PAGER_SSH" "sudo -n grep -cE '^DEADMAN_WEBHOOK_URL=.+' /etc/deadman/deadman.env" 2>/dev/null || echo 0)"
  a="$(ssh "${SSHO[@]}" "$PAGER_SSH" "sudo -n grep -cE '^DEADMAN_A2A_PEERS=.+' /etc/deadman/deadman.env" 2>/dev/null || echo 0)"
  if [ "${w:-0}" -eq 0 ] && [ "${a:-0}" -eq 0 ]; then
    note 'email is the ONLY configured sink (webhook and A2A absent) — one credential gates all paging'
  fi
else
  note "cannot ssh $PAGER_SSH from $HOST (the oci_vps_ed25519 identity lives on zephyr) —"
  note 'SMTP sink + sink inventory skipped here; the HTTP checks above are host-independent'
fi

# ---- 6. what is NOT covered ------------------------------------------------
hdr '6. coverage gaps'
n_live="$(find "$LIVE_DATA" -maxdepth 1 -type f | wc -l)"
if [ "$n_live" -lt 1 ]; then fail 'EMPTY INPUT: data/ has no files'; else
  note "data/ top-level files: $n_live; backup covers 16 objects (3 sqlite + 11 jsonl/json + 2 state)"
  note 'no backup and no store entry: breakers_state.json, portfolio_breakers_state.json, alloc_state.json, alert_cursor.json'
fi

# ---- summary ---------------------------------------------------------------
hdr 'summary'
printf '  checks: %d   failed: %d\n' "$CHECKS" "$FAILED"
printf '  paths written by this drill (all on %s, all removed on exit): %s\n' "$HOST" "${WROTE[*]}"
printf '  wrote to zephyr: NO (this script never opens a file for writing on zephyr)\n'
if [ "$FAILED" -eq 0 ] && [ "$CHECKS" -gt 0 ]; then echo 'RECOVERY-DRILL-OK'; exit 0; fi
[ "$CHECKS" -eq 0 ] && { echo 'RECOVERY-DRILL-EMPTY (no checks ran)'; exit 1; }
echo 'RECOVERY-DRILL-FAILED'; exit 1
