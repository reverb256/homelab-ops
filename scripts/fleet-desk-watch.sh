#!/bin/bash
# fleet-desk-watch.sh — Infomarchy fleet desk watchdog.
# Runs the fleet verifier; emits output ONLY when a check fails (watchdog
# pattern: empty stdout = healthy = no delivery).
export HOME=/home/j_kro
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl:$HOME/.local/bin:$HOME/.local/share/mise/shims"
# Recover the live Wayland display from the running shell's environment so
# omarchy-shell IPC reaches the desk (cron sessions lack session env).
QS_PID=$(pgrep -x quickshell 2>/dev/null | head -1)
if [ -n "$QS_PID" ]; then
  export WAYLAND_DISPLAY=$(tr '\0' '\n' < "/proc/$QS_PID/environ" 2>/dev/null | grep '^WAYLAND_DISPLAY=' | cut -d= -f2-)
fi
[ -z "${WAYLAND_DISPLAY:-}" ] && export WAYLAND_DISPLAY=wayland-1

VERIFIER="$HOME/Work/Projects/homelab-ops/scripts/verify-infomarchy-fleet.sh"
if [ ! -x "$VERIFIER" ]; then
  echo "Infomarchy fleet desk WATCHDOG ERROR: verifier missing at $VERIFIER"
  exit 0
fi

out=$(bash "$VERIFIER" 2>&1)
summary=$(echo "$out" | grep -E 'RESULT|PASS=|FAIL=' | tail -3 | tr '\n' ' ')
fails=$(echo "$out" | grep -oE 'FAIL=[0-9]+' | head -1 | cut -d= -f2)
[ -z "$fails" ] && fails=1

if [ "$fails" -gt 0 ] || ! echo "$out" | grep -q 'ALL CHECKS PASSED'; then
  echo "⚠️  Infomarchy fleet desk check FAILED ($summary)"
  echo
  echo "$out" | grep -E '❌|FAIL' | head -20
else
  # Healthy — emit nothing (watchdog stays silent).
  :
fi
exit 0
