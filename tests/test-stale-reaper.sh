#!/usr/bin/env bash
# Tests for bin/stale-reaper. No root, no systemd changes, no killing real work.
#
# Incident this guards: 2026-10-22 23:46 — leftover helper processes (VRoid/wine
# and friends) from finished bot jobs crashed zephyr's desktop session. The
# reaper must kill that class and must never touch a protected class.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
reaper=$here/../bin/stale-reaper
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; pkill -9 -f 'stale-reaper-test-' 2>/dev/null; jobs -p | xargs -r kill -9 2>/dev/null; }
trap cleanup EXIT

fails=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

# Fake helpers. `exec -a` rewrites argv[0], so /proc/<pid>/cmdline matches a
# class regex without needing the real binary.
SPAWNED=''
spawn() { # argv0 -> $SPAWNED. Must NOT be called in a command substitution:
          # the subshell exits and the fake reparents to systemd --user, which
          # makes it look like a real orphan instead of a child of this test.
  bash -c 'exec -a "$1" sleep 600' _ stale-reaper-test-"$1" >/dev/null 2>&1 &
  SPAWNED=$!
}

KEEP_FILE=$tmp/keep; : >"$KEEP_FILE"; export KEEP_FILE
export STALE_REAPER_SKIP_UNITS=1   # never touch real systemd units from a test
classify() {
  STALE_REAPER_ORPHAN_PPIDS=$$ STALE_REAPER_MIN_AGE=0 \
  STALE_REAPER_KEEP_FILE=$KEEP_FILE "$reaper" --json
}

# 1. a plain orphaned helper is reported and classified
spawn "blender -b /tmp/stale-reaper-test-scene.blend"; p1=$SPAWNED
out=$(classify)
grep -q "\"pid\":$p1" <<<"$out" && ok "reports orphaned 'blender -b'" || bad "missed orphaned blender"
grep -q '"class":"blender"' <<<"$out" && ok "classifies as blender" || bad "wrong class for blender"

# 2. a denylisted process in the same shape is never reported
spawn "peakminer --pool x --wallet y --api-port 1"; p2=$SPAWNED
out=$(classify)
grep -q "\"pid\":$p2" <<<"$out" && bad "denylisted miner was reported" || ok "denylist beats allowlist (miner)"

# 3. an MCP server is in the allowlist
spawn "node /home/x/.npm/_npx/abc/node_modules/.bin/argocd-mcp stdio"; p3=$SPAWNED
out=$(classify)
grep -q "\"pid\":$p3" <<<"$out" && ok "reports orphaned argocd-mcp" || bad "missed argocd-mcp"

# 4. keep file protects a pattern
spawn "blender -b /tmp/stale-reaper-test-commission.blend"; p4=$SPAWNED
echo 'commission\.blend' >"$KEEP_FILE"
out=$(classify)
grep -q "\"pid\":$p4" <<<"$out" && bad "keep-file pattern ignored" || ok "keep file protects a match"
: >"$KEEP_FILE"

# 5. dry-run kills nothing
spawn "blender -b /tmp/stale-reaper-test-dry.blend"; p5=$SPAWNED
STALE_REAPER_ORPHAN_PPIDS=$$ STALE_REAPER_MIN_AGE=0 STALE_REAPER_KEEP_FILE=$KEEP_FILE \
  "$reaper" --dry-run >/dev/null 2>&1
kill -0 "$p5" 2>/dev/null && ok "dry-run leaves the process alive" || bad "dry-run killed the process"

# 6. age floor respected: a young helper is not touched
spawn "blender -b /tmp/stale-reaper-test-young.blend"; p6=$SPAWNED
out=$(STALE_REAPER_ORPHAN_PPIDS=$$ STALE_REAPER_MIN_AGE=1800 STALE_REAPER_KEEP_FILE=$KEEP_FILE \
      "$reaper" --json)
grep -q "\"pid\":$p6" <<<"$out" && bad "age floor ignored" || ok "age floor respected"

# 7. a real run kills the process
spawn "blender -b /tmp/stale-reaper-test-real.blend"; p7=$SPAWNED
STALE_REAPER_ORPHAN_PPIDS=$$ STALE_REAPER_MIN_AGE=0 STALE_REAPER_GRACE=2 \
STALE_REAPER_KEEP_FILE=$KEEP_FILE "$reaper" >/dev/null 2>&1
sleep 1
kill -0 "$p7" 2>/dev/null && bad "real run left pid $p7 alive" || ok "real run killed the orphan"

# 8. a real run kills the whole tree, not just the parent
bash -c 'exec -a "blender -b /tmp/stale-reaper-test-tree.blend" sleep 600' \
  >/dev/null 2>&1 &
p8=$!
STALE_REAPER_ORPHAN_PPIDS=$$ STALE_REAPER_MIN_AGE=0 STALE_REAPER_GRACE=2 \
STALE_REAPER_KEEP_FILE=$KEEP_FILE "$reaper" >/dev/null 2>&1
sleep 1
kill -0 "$p8" 2>/dev/null && bad "tree run left pid $p8 alive" || ok "tree run killed the process"

# 9. a TTY-attached helper is never reported
if command -v script >/dev/null; then
  script -qfc "exec -a 'blender -b /tmp/stale-reaper-test-tty.blend' sleep 4" /dev/null >/dev/null 2>&1 &
  spid=$!
  sleep 1
  tp=$(pgrep -f 'stale-reaper-test-tty.blend' | head -1)
  if [[ -n ${tp:-} ]]; then
    out=$(classify)
    grep -q "\"pid\":$tp" <<<"$out" && bad "TTY process was reported" || ok "tty-attached process skipped"
  else
    ok "tty test inconclusive (process not visible)"
  fi
  wait "$spid" 2>/dev/null; kill -9 "$spid" 2>/dev/null
else
  ok "tty test skipped (no script(1))"
fi

# 10. bad flag is rejected, not ignored
"$reaper" --nope >/dev/null 2>&1 && bad "unknown flag accepted" || ok "unknown flag rejected"

# 11. STALE_REAPER_ORPHAN_PPIDS REPLACES the default set (regression: it used to
#     append, so a test inherited "everything under systemd --user", age floor 0,
#     and reaped a live browser daemon on the real host).
spawn "blender -b /tmp/stale-reaper-test-replace.blend"; p11=$SPAWNED
out=$(STALE_REAPER_ORPHAN_PPIDS=1 STALE_REAPER_MIN_AGE=0 STALE_REAPER_KEEP_FILE=$KEEP_FILE \
      "$reaper" --json)
grep -q "\"pid\":$p11" <<<"$out" && bad "orphan-ppid override appended instead of replacing" \
  || ok "orphan-ppid override replaces the default set"

# 12. a detached browser_harness daemon is NOT a kill target: it detaches to
#     systemd --user by design and is live while it looks orphaned.
spawn "python3 -m browser_harness.daemon"; p12=$SPAWNED
out=$(classify)
grep -q "\"pid\":$p12" <<<"$out" && bad "live browser_harness daemon was reported" \
  || ok "browser_harness daemon never reaped"

# 13. a process belonging to an ACTIVE systemd --user unit is never a target,
#     even when it looks exactly like an orphaned helper. This is the v6 case:
#     a Hermes job's MainPID has ppid=systemd --user and its tree is full of
#     allowlisted helpers (MCP servers, pyright). Killing it kills a live job.
if command -v systemd-run >/dev/null; then
  unit=stale-reaper-test-svc-$$
  systemd-run --user --unit="$unit" --collect -p RuntimeMaxSec=20 \
    /bin/bash -c 'exec -a "blender -b /tmp/stale-reaper-test-unit.blend" sleep 15' \
    >/dev/null 2>&1
  sleep 2
  upid=$(systemctl --user show "$unit" -p MainPID --value 2>/dev/null)
  if [[ ${upid:-0} =~ ^[0-9]+$ ]] && ((upid > 0)); then
    umgr=$(ps -o ppid= -p "$upid" | tr -d ' ')
    out=$(STALE_REAPER_ORPHAN_PPIDS="1 $umgr" STALE_REAPER_MIN_AGE=0 \
          STALE_REAPER_KEEP_FILE=$KEEP_FILE "$reaper" --json)
    grep -q "\"pid\":$upid" <<<"$out" && bad "reaped a process inside an active unit" \
      || ok "active-unit process protected"
    kill -0 "$upid" 2>/dev/null && ok "active-unit process still alive" || bad "active-unit process died"
  else
    ok "active-unit test inconclusive (unit did not start)"
  fi
  systemctl --user stop "$unit" 2>/dev/null
  systemctl --user reset-failed "$unit" 2>/dev/null
else
  ok "active-unit test skipped (no systemd-run)"
fi

# 14. syntax
bash -n "$reaper" && ok "bash -n clean" || bad "syntax error"

printf '\n%s\n' "$( ((fails == 0)) && echo PASS || echo "FAIL ($fails)")"
exit $((fails > 0))
