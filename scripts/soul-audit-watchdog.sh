#!/usr/bin/env bash
# soul-audit-watchdog — fleet SOUL/config drift detection for Hermes profiles.
# Modes: --scan (aggregate across hosts), --scan-local (one host, machine-readable),
#        --selftest (fixture negative control), --post (create guard card when drift found).
# Exit: 0 when clean/selftest-as-expected; 1 when drift found in --scan.
set -uo pipefail

HOSTS="${SOUL_WATCHDOG_HOSTS:-zephyr nexus sentry}"
LOG="$HOME/.hermes/logs/soul-audit-watchdog.log"
mkdir -p "$(dirname "$LOG")"

scan_root(){ # $1 = profiles root; prints: boilerplate style contract nested missing
  local root="$1" b s c n m t f d bb
  b=0; s=0; c=0; m=0; t=0
  b=$(for f in "$root"/*/SOUL.md; do [ -f "$f" ] || continue; case "$f" in */default/*) continue;; esac; grep -q "You are Hermes Agent, built by Nous Research" "$f" && echo x; done | wc -l)
  s=$(for f in "$root"/*/SOUL.md; do [ -f "$f" ] || continue; case "$f" in */default/*) continue;; esac; grep -q "Zinsser's four principles" "$f" || echo x; done | wc -l)
  c=$(for f in "$root"/*/SOUL.md; do [ -f "$f" ] || continue; case "$f" in */default/*) continue;; esac; grep -q "HARD-DATA CONTRACT" "$f" || echo x; done | wc -l)
  t=$(for f in "$root"/*/SOUL.md; do [ -f "$f" ] || continue; case "$f" in */default/*) continue;; esac; grep -q "FAILURE -> TEST" "$f" || echo x; done | wc -l)
  n=0; for d in "$root"/*/; do bb=$(basename "$d"); [ -d "$d$bb" ] && n=$((n+1)); done
  m=$(for d in "$root"/*/; do bb=$(basename "$d"); [ "$bb" = "default" ] && continue; [ -f "$d/SOUL.md" ] || [ -f "$d/config.yaml" ] || echo x; done | wc -l)
  echo "$b $s $c $n $m $t"
}

selftest(){
  local tmp b s c n m
  tmp=$(mktemp -d)
  mkdir -p "$tmp/fakebot"
  echo "You are Hermes Agent, built by Nous Research. Be direct." > "$tmp/fakebot/SOUL.md"
  read -r b s c n m <<< "$(scan_root "$tmp")"
  rm -rf "$tmp"
  if [ "$b" -ge 1 ]; then echo "SELFTEST OK detected=$b"; exit 0; else echo "SELFTEST FAIL detected=$b"; exit 1; fi
}

scan_local(){ scan_root "$HOME/.hermes/profiles"; }

scan(){
  local issues=0 report="" line host res
  for host in $HOSTS; do
    if [ "$host" = "$(hostname -s 2>/dev/null || echo unknown)" ]; then
      res=$(scan_local)
    else
      res=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" 'bash ~/.hermes/scripts/soul-audit-watchdog.sh --scan-local' 2>/dev/null) || { report="$report\n$host: UNREACHABLE"; issues=$((issues+1)); continue; }
    fi
    read -r b s c n m t <<< "$res"
    line="$host: boilerplate=$b style_missing=$s contract_missing=$c nested=$n orphan=$m failure_test_missing=$t"
    report="$report\n$line"
    issues=$((issues + b + s + c + n + t))
  done
  if [ "$issues" -eq 0 ]; then
    echo "SCAN OK 0 regressions"
    echo -e "$report" >> "$LOG" 2>/dev/null || true
    exit 0
  else
    echo "SCAN ISSUES=$issues"
    echo -e "SCAN ISSUES=$issues$report"
    echo -e "$report" >> "$LOG" 2>/dev/null || true
    exit 1
  fi
}

post(){
  local out rc
  out=$(scan 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "POST nothing-to-post"; exit 0; fi
  if hermes --board guards kanban list 2>/dev/null | grep -q "guard:souls"; then
    echo "POST card-already-open"; exit 0
  fi
  local body="Drift detected by soul-audit-watchdog on $(date -u +%FT%TZ).$out"
  hermes --board guards kanban create "[guard:souls] profile SOUL/config drift detected" --assignee nexus-core --body "$body" >/dev/null 2>&1 \
    && echo "POST card-created" || echo "POST card-create-failed"
  exit 0
}

case "${1:---scan}" in
  --scan) scan;;
  --scan-local) scan_local;;
  --selftest) selftest;;
  --post) post;;
  *) echo "usage: $0 [--scan|--scan-local|--selftest|--post]"; exit 2;;
esac
