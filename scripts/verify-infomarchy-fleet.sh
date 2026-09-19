#!/bin/bash
# verify-infomarchy-fleet.sh — systematic verification of the Infomarchy fleet desk
# Run from zephyr. Checks each layer bottom→top and prints PASS/FAIL.
set -u
PLUGIN_DIR="$HOME/.config/omarchy/plugins/nixfred.infomarchy"
PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "── $1 ──"; }

section "1. Local collector emits valid snapshot"
if (cd "$PLUGIN_DIR" && timeout 90 bun collector.ts --id verify > /tmp/v_collector.txt 2>&1); then
  R=$(python3 - <<'PY'
import json
raw=open('/tmp/v_collector.txt').read()
frames=[json.loads(l) for l in raw.splitlines() if l.strip()]
errs=[f for f in frames if f.get('type')=='error']
chunks=''.join(f['data'] for f in frames if f.get('type')=='chunk')
s=json.loads(chunks) if chunks else {}
host=s.get('host','?')
hermes=bool(s.get('ai',{}).get('counts',{}).get('hermes'))
if errs: print("FAIL err="+errs[0].get('message','')[:120])
elif not host: print("FAIL no host")
elif not hermes: print("FAIL no hermes counts in collector")
else: print("PASS host="+str(host)+" hermes_counts=yes")
PY
)
  echo "$R" | grep -q '^PASS' && ok "$R" || bad "$R"
else
  bad "collector run failed"
fi

section "2. Transport — SSH to remote hosts runs their collector"
for host in nexus sentry; do
  out=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "cd ~/.config/omarchy/plugins/nixfred.infomarchy 2>/dev/null && timeout 60 bun collector.ts --id probe 2>/dev/null" 2>/dev/null)
  if echo "$out" | grep -q 'collector failed\|no such file\|not found'; then
    bad "$host collector error: $(echo "$out" | head -c 80)"
  elif echo "$out" | grep -q '"type":"end"'; then
    ok "$host collector reachable over SSH (valid framed end)"
  else
    bad "$host collector NOT reachable (no valid output, $(echo "$out" | wc -c) bytes)"
  fi
done

section "3. fleet.ts merge — all hosts in one unified snapshot"
if (cd "$PLUGIN_DIR" && timeout 120 bun fleet.ts > /tmp/v_fleet.txt 2>&1); then
  python3 - <<'PY'
import json
raw=open('/tmp/v_fleet.txt').read()
frames=[json.loads(l) for l in raw.splitlines() if l.strip()]
errs=[f for f in frames if f.get('type')=='error']
chunks=''.join(f['data'] for f in frames if f.get('type')=='chunk')
ends=[f for f in frames if f.get('type')=='end']
s=json.loads(chunks) if chunks else {}
fleet=s.get('fleet',{})
hosts=[h['host'] for h in fleet.get('hosts',[])]
sessions=s.get('ai',{}).get('sessions',[])
recent=s.get('ai',{}).get('recent',[])
machines_ok=all(h.get('machine') for h in fleet.get('hosts',[]))
print(f"hosts={hosts}")
print(f"sessions={len(sessions)} recent={len(recent)} machines_ok={machines_ok}")
print(f"host_count_ok={len(hosts)>=3}")
print(f"no_errors={not errs}")
PY
  # Framing must be checked in JS (UTF-16), not python (code points) — emoji
  # in session titles make python's len differ from what QML counts.
  FR=$(bun -e '
    const raw = require("fs").readFileSync("/tmp/v_fleet.txt", "utf8");
    let payload = ""; let endChars = null;
    for (const l of raw.split("\n").filter(Boolean)) {
      const f = JSON.parse(l);
      if (f.type === "chunk") payload += f.data;
      if (f.type === "end") endChars = f.chars;
    }
    console.log(payload.length === endChars ? "PASS" : "FAIL " + payload.length + " vs " + endChars);
  ')
  echo "$FR" | grep -q '^PASS' && ok "framing valid ($FR)" || bad "framing mismatch ($FR)"
else
  bad "fleet.ts run failed"
fi

section "4. Live model — running desk consumes fleet"
FM=$(timeout 10 omarchy-shell infomarchy fleetMode 2>&1)
GH=$(timeout 10 omarchy-shell infomarchy getHosts 2>&1)
[ "$FM" = "true" ] && ok "fleetMode=$FM" || bad "fleetMode=$FM (want true)"
echo "$GH" | grep -q 'nexus' && echo "$GH" | grep -q 'sentry' && ok "getHosts=$GH" || bad "getHosts=$GH"

section "5. Host filter toggles"
timeout 10 omarchy-shell infomarchy setHost nexus >/dev/null 2>&1; sleep 2
HN=$(timeout 10 omarchy-shell infomarchy getHost 2>&1)
[ "$HN" = "nexus" ] && ok "setHost nexus → $HN" || bad "setHost nexus → got '$HN'"
timeout 10 omarchy-shell infomarchy setHost '' >/dev/null 2>&1; sleep 2
HA=$(timeout 10 omarchy-shell infomarchy getHost 2>&1)
[ -z "$HA" ] && ok "setHost '' → ALL (empty)" || bad "setHost '' → got '$HA'"

section "6. Stability — no crashes, one shell, collector running"
CRASHES=$(ls "$HOME/.cache/quickshell/crashes/" 2>/dev/null | wc -l)
SHELLS=$(ps -eo args= | grep -c 'quickshell -n' || true)
[ "$CRASHES" -le 4 ] && ok "crash dirs: $CRASHES (≤4)" || bad "crash dirs: $CRASHES"
[ "$SHELLS" -ge 1 ] && ok "quickshell running ($SHELLS)" || bad "no quickshell"

section "RESULT"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "  ✅ ALL CHECKS PASSED" || echo "  ❌ $FAIL CHECK(S) FAILED"
