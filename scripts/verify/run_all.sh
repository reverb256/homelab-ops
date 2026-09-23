#!/usr/bin/env bash
# scripts/verify/run_all.sh — run every verification script in order and summarise.
#
# One line per script; the exit code is the worst outcome seen
# (0 = all OK, 1 = at least one FAIL, 2 = at least one INCONCLUSIVE).
#
# HOST: nexus (kubectl + ~/Work/trading). cwd: anywhere.
# READ-ONLY: it only runs the scripts under this directory, which do not mutate state.
#            (See README.md; autonomy_audit.sh delegates to the trading repo's own gate
#             script, which is pytest-based, with pytest caching disabled.)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"

SCRIPTS=(
  cluster_snapshot.sh
  cluster_shadow_freshness.sh
  tracking_surfaces.sh
  lab_probe.py
  rotation_exposure_check.py
  wallet_custody_inventory.sh
  autonomy_audit.sh
)

echo "verify/run_all.sh  host=$(hostname)  $(date '+%Y-%m-%d %H:%M:%S%z')"
echo "running ${#SCRIPTS[@]} verification scripts (read-only)"
_hr

WORST=0
LABELS=()
CODES=()
SECONDS_LIST=()
for script in "${SCRIPTS[@]}"; do
  path="$HERE/$script"
  if [ ! -f "$path" ]; then
    LABELS+=("$script")
    CODES+=("MISSING")
    SECONDS_LIST+=("0")
    bump_rc 2
    continue
  fi
  start=$(date +%s)
  case "$script" in
    *.py) interpreter="$PY" ;;
    *)    interpreter="bash" ;;
  esac
  echo
  "$interpreter" "$path" 2>&1 | sed 's/^/  | /'
  rc=${PIPESTATUS[0]}
  end=$(date +%s)
  LABELS+=("$script")
  CODES+=("$rc")
  SECONDS_LIST+=("$((end - start))")
  bump_rc "$rc"
  printf '  ==> %s rc=%d (%ss)\n' "$script" "$rc" "$((end - start))"
done

echo
_hr
printf '%-34s %-8s %s\n' "SCRIPT" "RC" "SECONDS"
for i in "${!LABELS[@]}"; do
  printf '%-34s %-8s %s\n' "${LABELS[$i]}" "${CODES[$i]}" "${SECONDS_LIST[$i]}"
done
note "rc 0 = OK, 1 = FAIL, 2 = INCONCLUSIVE (empty input / schema drift)"

finish
