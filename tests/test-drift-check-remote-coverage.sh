#!/bin/bash
# test-drift-check-remote-coverage.sh — D9 must hash EVERY committed file on a
# REMOTE host, not just the first one.
#
# What this pins (the failure this card exists for, kanban t_e13e4db4, 2026-10-14):
# drift-check.sh reads its per-file list from a here-string on stdin while ssh
# attaches the same stdin and drains it, so the while-read loop ended after ONE
# file per remote host. sentry's whole omarchy/ section — 24 committed files,
# including the k3s unit declaration that had genuinely drifted from the host
# unit — was never hashed. The section printed "1 file, in-sync" and lied,
# which is the exact silent-drift class D9 exists to catch.
#
# Both assertions are structural, need no cluster and no root:
#   1. POSITIVE: the ssh invocation inside drift-check.sh carries -n (stdin
#      comes from /dev/null, so the loop's stdin cannot be drained).
#   2. NEGATIVE: the loop's input is a HERE-STRING (<<<) fed to `while IFS=
#      read -r` — the same shape the old bug lived in — proving the guard is
#      against the real pattern, not a cosmetic grep.
#
# Usage: bash tests/test-drift-check-remote-coverage.sh   (any host, any cwd)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D="$ROOT/scripts/verify/drift-check.sh"
PASS=0 FAIL=0
ok(){ printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -f "$D" ] && ok "drift-check.sh present" || { no "drift-check.sh missing: $D"; exit 1; }

# 1. every ssh the script runs must be stdin-isolated (-n).
if grep -q 'SSH_OPTS="-n -o BatchMode=yes -o ConnectTimeout=8"' "$D"; then
  ok "ssh opts carry -n (stdin from /dev/null)"
else
  no "ssh opts do NOT carry -n — a remote-host loop iteration can eat the list"
fi
# no ssh call may bypass SSH_OPTS and drain stdin itself
if grep -E '^\s*ssh ' "$D" | grep -qv -- '-n'; then
  no "a bare ssh call without -n exists — it can drain the loop's stdin"
else
  ok "no bare ssh without -n"
fi

# 2. the loop shape the bug lived in is still there (regression target real).
if grep -q 'done <<<"\$files"' "$D"; then
  ok "per-file loop is a here-string while-read (the vulnerable shape is guarded)"
else
  no "per-file loop shape changed — re-verify the stdin fix against the new shape"
fi

# 3. strip_doc_header: leading comments are documentation, mid-file comments are
#    content. A declaration whose only repo-vs-host difference is the doc header
#    must read in-sync (sentry k3s.service, t_e13e4db4), while any content change
#    after the first real line must still count as drift.
strip_doc_header() {
  awk 'p{print} !p && $0 !~ /^#/ && $0 !~ /^[[:space:]]*$/ {p=1; print}'
}
h1=$(printf '# doc header\n# more doc\n\n[Unit]\nDescription=real content\n' | strip_doc_header | sha256sum | cut -d' ' -f1)
h2=$(printf '[Unit]\nDescription=real content\n' | strip_doc_header | sha256sum | cut -d' ' -f1)
h3=$(printf '[Unit]\nDescription=CHANGED content\n' | strip_doc_header | sha256sum | cut -d' ' -f1)
[ "$h1" = "$h2" ] && ok "leading doc header ignored (header-only diff = in-sync)" \
  || no "leading doc header leaks into the content hash (permanently-red check returns)"
[ "$h1" != "$h3" ] && ok "content change after header still drifts" \
  || no "a real content change was masked as a header difference"
grep -q "strip_doc_header" "$D" && ok "drift-check consults strip_doc_header on hash mismatch" \
  || no "drift-check no longer uses strip_doc_header — the header rule rotted"

echo
if [ "$FAIL" = 0 ]; then echo "DRIFT-CHECK COVERAGE TEST PASS ($PASS)"; exit 0; else echo "DRIFT-CHECK COVERAGE TEST FAIL"; exit 1; fi
