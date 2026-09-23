#!/usr/bin/env bash
# scripts/verify/_lib.sh — shared helpers for scripts/verify/*.sh
#
# Sourced, never executed. It exists to enforce the two rules that keep a
# verification script from lying:
#   * assert_nonempty — an extractor that returned nothing is INCONCLUSIVE, never "clean"
#   * finish          — exit code 0/1/2 so a caller (or ssh) can branch on the outcome
#
# The scripts under scripts/verify/ are verification tools, not fixers. Nothing in
# this file (or the scripts that source it) writes to disk or to any service.

VERIFY_LIB=1

: "${PY:=/usr/bin/python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python3

# Status accumulator: 2 (inconclusive) outranks 1 (fail) outranks 0 (ok).
V_RC=0

section() { echo; echo "== $* =="; }
_hr() { printf '%.0s-' {1..64}; echo; }
note() { printf '   %s\n' "$*"; }

bump_rc() {
  if [ "${1:-0}" -gt "$V_RC" ]; then V_RC="${1:-0}"; fi
  return 0
}

# assert_nonempty <label> <value...>
# 0 when non-empty; prints [INCONCLUSIVE] and returns 1 when empty/whitespace-only.
assert_nonempty() {
  local label="$1"; shift
  local joined="$*"
  if [ -z "${joined//[[:space:]]/}" ]; then
    printf '   [INCONCLUSIVE] %s: nothing returned — a "clean" result here would be meaningless\n' "$label"
    bump_rc 2
    return 1
  fi
  return 0
}

# check <rc> <description> — for a yes/no assertion already evaluated (0 = held).
check() {
  if [ "${1:-1}" -eq 0 ]; then
    printf '  [PASS] %s\n' "$2"
  else
    printf '  [FAIL] %s\n' "$2"
    bump_rc 1
  fi
  return 0
}

# inconclusive <description> — for a check that could not be evaluated at all.
inconclusive() {
  printf '  [INCONCLUSIVE] %s\n' "$1"
  bump_rc 2
  return 0
}

finish() {
  _hr
  case "$V_RC" in
    0) printf 'RESULT: OK (every section evaluated and held)\n' ;;
    1) printf 'RESULT: FAIL (see [FAIL] lines above)\n' ;;
    *) printf 'RESULT: INCONCLUSIVE (see [INCONCLUSIVE] lines above — empty input or schema drift)\n' ;;
  esac
  exit "$V_RC"
}
