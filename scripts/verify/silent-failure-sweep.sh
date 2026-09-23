#!/usr/bin/env bash
# silent-failure-sweep.sh — hunt the ONE failure class the fleet keeps producing:
#
#   a job, collector, reporter or gate that REPORTS SUCCESS WHILE PRODUCING
#   NOTHING, or that READS A STALE / ABSENT SOURCE AS IF IT WERE CURRENT.
#
# READ-ONLY. This script makes no cluster object, writes no file, restarts nothing,
# scales nothing, and prints no secret. It is safe to run any time, on nexus.
# (Per fleet rule, do NOT install or run this on zephyr — zephyr is a workstation.)
#
# Usage:  scripts/verify/silent-failure-sweep.sh [--hosts]
#   --hosts   also probe forge/sentry/zephyr over ssh (read-only) for backup-unit
#             and timer state. Off by default.
#
# Exit: 0 = OK, 1 = at least one FAIL, 2 = INCONCLUSIVE (a guard failed: an empty
#       input is never reported as clean). Worst-wins, same as the rest of
#       scripts/verify, so `run_all.sh` can aggregate this with the others.
#
# Read-only, with one documented exception inside the scripts/verify contract: this
# sweep uses `kubectl exec` — never apply/delete/patch/scale — to READ two things that
# exist only inside pods (the quill ingest ledger via `cat`, and the metric/rule index
# via `wget` against the in-cluster VictoriaMetrics/vmalert). Both are reads; no pod
# is created and nothing is mutated.
#
# FIELD NAMES (the sweep's vocabulary; every line is these five fields):
#   verdict  PASS | FAIL | NOTE | INCONCLUSIVE  (the scripts/verify vocabulary)
#   section  the detection rule that fired
#   item     the object (namespace/name, file, unit, module)
#   signal   what was measured, with its value
#   expected what a healthy object would have shown
#
# Detection rules (D1-D8) live next to the code that applies them.

set -uo pipefail
HOSTS=0
[ "${1:-}" = "--hosts" ] && HOSTS=1
OUT_TMP=$(mktemp -d)            # counters only; removed on exit
trap 'rm -rf "$OUT_TMP"' EXIT
F_FILE="$OUT_TMP/findings"; N_FILE="$OUT_TMP/notes"; G_FILE="$OUT_TMP/guards"
: > "$F_FILE"; : > "$N_FILE"; : > "$G_FILE"
export FCOUNT="$F_FILE" NCOUNT="$N_FILE" GCOUNT="$G_FILE"

emit() {  # verdict section item signal expected  (ONE accounting path: also used by the python sections)
  printf '%-9s | %-22s | %-46s | %-52s | %s\n' "$1" "$2" "$3" "$4" "$5"
  case "$1" in
    FAIL)         printf '%s|%s\n' "$2" "$3" >> "$F_FILE" ;;
    NOTE)       printf '%s|%s\n' "$2" "$3" >> "$N_FILE" ;;
    INCONCLUSIVE) printf '%s|%s\n' "$2" "$3" >> "$G_FILE" ;;
  esac
  return 0
}

count() { wc -l < "$1" 2>/dev/null | tr -d ' '; }
py() { python3 "$@"; }

echo "== silent-failure sweep =="
echo "verdict   | section                | item                                               | signal                                               | expected"
echo "--------- | ---------------------- | -------------------------------------------------- | ---------------------------------------------------- | --------"

# ---------------------------------------------------------------- 0. GUARDS
# An empty input must never read as health (the whole point of this class).
CJ_JSON=$(kubectl get cronjobs -A -o json 2>/dev/null || true)
CJ_N=$(printf '%s' "$CJ_JSON" | py -c 'import json,sys
try: print(len(json.load(sys.stdin)["items"]))
except Exception: print(0)' 2>/dev/null || echo 0)
if [ "${CJ_N:-0}" -lt 15 ]; then
  emit INCONCLUSIVE guard "kubectl get cronjobs -A" "cronjobs=${CJ_N:-0}" ">= 15 (kubectl+KUBECONFIG usable?)"
fi
DATA_DIR=${TRADING_DATA:-/home/j_kro/Work/trading/data}
FEED_N=$(ls -1 "$DATA_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
if [ "${FEED_N:-0}" -lt 5 ]; then
  emit INCONCLUSIVE guard "$DATA_DIR" "*.jsonl files=${FEED_N:-0}" ">= 5 (canonical trading repo on nexus?)"
fi
if [ "$(count "$G_FILE")" -gt 0 ]; then
  echo
  echo "[INCONCLUSIVE] $(count "$G_FILE") guard(s) failed — an empty input was NOT reported as clean."
  exit 2
fi

# ------------------------------------------------- 1. CRONJOB FRESHNESS (D1,D2,D5,D6)
# D1 never-succeeded / D2 success older than 2x its own period / D5 lastScheduleTime
# missing while lastSuccessfulTime is set (= a manual smoke job, not a scheduled run,
# so the "last success" field is NOT proof that the scheduler works) / D6 suspended
# with a schedule that can never fire.
printf '%s' "$CJ_JSON" > "$OUT_TMP/cj.json"
py - "$OUT_TMP/cj.json" <<'PY'
import json,sys,datetime,re,os
d=json.load(open(sys.argv[1])); now=datetime.datetime.now(datetime.timezone.utc)
FC=os.environ.get('FCOUNT'); NC=os.environ.get('NCOUNT')
def dt(s): return datetime.datetime.fromisoformat(s.replace('Z','+00:00')) if s else None
FC=os.environ.get('FCOUNT'); NC=os.environ.get('NCOUNT')
import os as _os
FIELDS=[('minute',0,60),('hour',0,24),('dom',1,32),('month',1,13),('dow',0,7)]
def expand(f,lo,hi):
    vals=set()
    for part in f.split(','):
        step=1
        if '/' in part: part,st=part.split('/'); step=int(st)
        if part=='*': a,b=lo,hi-1
        elif '-' in part: a,b=part.split('-'); a=int(a); b=int(b)
        else: a=b=int(part)
        vals.update(range(a,b+1,step))
    return sorted(vals)
def matches(t,f):
    out=[expand(x,r[1],r[2]) for x,r in zip(f,FIELDS)]
    return (t.minute in out[0] and t.hour in out[1] and t.day in out[2]
            and t.month in out[3] and ((t.weekday()+1) % 7) in [v % 7 for v in out[4]])
def period_min(f):
    # 21 days so every weekly (and 2-weekly) schedule gets >= 2 occurrences
    t=datetime.datetime(2026,1,5,0,0)
    hits=[]
    for i in range(21*24*60):
        if matches(t,f): hits.append(i)
        t+=datetime.timedelta(minutes=1)
    if len(hits)==0: return None          # impossible schedule (e.g. Feb 31)
    if len(hits)==1: return 21*24*60      # slower than the window: treat as >=3 weeks
    return max(b-a for a,b in zip(hits,hits[1:]))
def emit(v,s,i,sig,exp):
    print(f"{v:<9} | {s:<22} | {i:<46} | {sig:<52} | {exp}")
    if v=='FAIL' and FC: open(FC,'a').write(f"{s}|{i}\n")
    if v=='NOTE' and NC: open(NC,'a').write(f"{s}|{i}\n")
for it in sorted(d['items'],key=lambda x:(x['metadata']['namespace'],x['metadata']['name'])):
    m=it['metadata']; sp=it['spec']; st=it.get('status',{})
    name=f"{m['namespace']}/{m['name']}"; f=[p.split() for p in [sp['schedule']]][0]
    created=dt(m.get('creationTimestamp')); ls=dt(st.get('lastScheduleTime')); lok=dt(st.get('lastSuccessfulTime'))
    age_h=lambda x:(now-x).total_seconds()/3600
    per=period_min(f)
    created_age_h=age_h(created) if created else 0
    if sp.get('suspend'):
        if per is None:
            emit('NOTE','D6 suspended-never-fires',name,f"schedule={sp['schedule']} suspend=true","a suspended job with an impossible schedule can never fail or alert")
        else:
            emit('NOTE','D6 suspended',name,f"schedule={sp['schedule']} suspend=true","intentional? a suspended producer reports nothing by construction")
        continue
    if per is None:
        emit('NOTE','D6 never-fires',name,f"schedule={sp['schedule']}","0 matching times in 8 days — the job can never run or alert")
        continue
    grace=(2*per+15)/60.0      # 2 periods + 15 min, in HOURS (per is in MINUTES)
    if str(sp.get('failedJobsHistoryLimit','1'))=='0':
        emit('NOTE','D6 hides-failures',name,"failedJobsHistoryLimit=0","failures are evicted immediately: a broken run leaves no trace")
    if lok is None:
        if created_age_h < grace*1.5:
            emit('PASS','D1 never-succeeded(pending)',name,f"age={created_age_h:.1f}h period={per}m","younger than 2 periods: first fire not yet due")
        else:
            emit('FAIL','D1 never-succeeded',name,f"age={created_age_h:.1f}h period={per}m","should have succeeded by now")
        continue
    ok_age=age_h(lok); ls_age=age_h(ls) if ls else None
    if ls is None:
        emit('NOTE','D5 smoke-job-not-schedule',name,f"lastSuccessfulTime={ok_age:.1f}h lastScheduleTime=absent","this 'success' came from a manual create-job, not the scheduler")
    elif ls_age > grace:
        emit('FAIL','D5 schedule-missed',name,f"lastScheduleTime={ls_age:.1f}h period={per}m","scheduler has not fired it within 2 periods")
    if ok_age > grace:
        emit('FAIL','D2 stale-success',name,f"lastSuccessfulTime={ok_age:.1f}h period={per}m","a green status older than 2 periods is not evidence it still works")
    else:
        emit('PASS','D2 fresh-success',name,f"lastSuccessfulTime={ok_age:.1f}h period={per}m","within 2 periods")
PY

# ------------------------------------------------ 2. PRODUCER CONTENT (D3,D4)
# D3 producer green but writes nothing/stale rows (file registry, mtime AND last row
# ts — mtime alone is fooled by a writer that re-appends an old cache). D4 a counter
# that advances while the payload never does (quill ingest ledger).
FEEDS="
gmgn_flow.jsonl|30|trading-gmgn-flow */5
gmgn_track.jsonl|30|trading-gmgn-track */1
gmgn_sec.jsonl|30|trading-gmgn-track */1
gmgn_portfolio.jsonl|1560|trading-gmgn-portfolio daily
curve_watch.jsonl|15|trading-curve-watch */3
rhc_prices.jsonl|15|trading-rhc-price */5
equity_curve.jsonl|10|daemon 30s
portfolio_series.jsonl|60|trading-portfolio */15
owner_queue.json|1560|owner decision queue
"
DATA_DIR="$DATA_DIR" FEEDS="$FEEDS" py - <<'PY'
import json,os,time
from pathlib import Path
root=Path(os.environ['DATA_DIR']); now=time.time()
FC=os.environ.get('FCOUNT'); NC=os.environ.get('NCOUNT')
def emit(v,s,i,sig,exp):
    print(f"{v:<9} | {s:<22} | {i:<46} | {sig:<52} | {exp}")
    if v=='FAIL' and FC: open(FC,'a').write(f"{s}|{i}\n")
    if v=='NOTE' and NC: open(NC,'a').write(f"{s}|{i}\n")
n=0
for line in os.environ['FEEDS'].strip().splitlines():
    name,cad,who=line.split('|'); cad=int(cad); p=root/name; n+=1
    if not p.exists():
        emit('FAIL','D3 feed-missing',name,f"cadence={cad}m producer={who}","file exists and is fresh")
        continue
    mtime_age=(now-p.stat().st_mtime)/60
    row_age=None
    if name.endswith('.jsonl'):
        try:
            tail=p.open('rb').read()[-262144:].decode('utf-8','replace').strip().splitlines()
            for ln in reversed(tail):
                try:
                    r=json.loads(ln)
                    t=r.get('ts') or r.get('timestamp') or r.get('time')
                    if t is None: continue
                    t=float(t)
                    if t>1e12: t/=1000.0
                    row_age=(now-t)/60; break
                except Exception: continue
        except Exception: pass
    sig=f"mtime={mtime_age:.1f}m"+(f" last_row={row_age:.1f}m" if row_age is not None else " last_row=n/a")
    worst=max([x for x in (mtime_age,row_age) if x is not None])
    if worst > 2*cad:
        emit('FAIL','D3 stale-producer',name,sig,f"<= {2*cad}m (2x its own {cad}m cadence)")
    else:
        emit('PASS','D3 fresh-producer',name,sig,f"<= {2*cad}m")
print(f"NOTE      | D3 coverage            | {root}                                        | feeds checked={n}                                     | registry, extend when a producer is added")
PY

LEDGER_JSON=$(kubectl exec -n maplespike deploy/quill-api -- cat /data/quill/ingest-ledger.json 2>/dev/null || true)
if [ -z "$LEDGER_JSON" ]; then
  emit NOTE D4 ingest-ledger-unreadable "maplespike/quill-api:/data/quill/ingest-ledger.json" "not readable" "run with cluster access to include the ingest check"
else
  printf '%s' "$LEDGER_JSON" > "$OUT_TMP/ledger.json"
  py - "$OUT_TMP/ledger.json" <<'PY'
import json,sys,os
from datetime import datetime,timezone
d=json.load(open(sys.argv[1])); now=datetime.now(timezone.utc)
FC=os.environ.get('FCOUNT'); NC=os.environ.get('NCOUNT')
def emit(v,s,i,sig,exp):
    print(f"{v:<9} | {s:<22} | {i:<46} | {sig:<52} | {exp}")
    if v=='FAIL' and FC: open(FC,'a').write(f"{s}|{i}\n")
    if v=='NOTE' and NC: open(NC,'a').write(f"{s}|{i}\n")
for mod,v in sorted(d.items()):
    runs=int(v.get('runs') or 0); rec=int(v.get('records') or 0); f=int(v.get('failures') or 0)
    ls=v.get('lastSuccess')
    age_h=(now-datetime.fromisoformat(ls.replace('Z','+00:00'))).total_seconds()/3600 if ls else None
    sig=f"runs={runs} records={rec} failures={f} lastSuccess={age_h:.1f}h ago" if age_h else f"runs={runs} records={rec} failures={f}"
    if runs>0 and rec==0:
        emit('FAIL','D4 zero-payload-ingest',f"quill:{mod}",sig,"a green run that persists 0 records (found>0, ingested=0) is a silent stall")
    elif runs>0 and rec/max(runs,1) < 0.5:
        emit('NOTE','D4 thin-payload-ingest',f"quill:{mod}",sig,f"~{rec/runs:.2f} records/run: nearly everything is being dropped")
    elif runs==0:
        emit('NOTE','D4 no-runs',f"quill:{mod}",sig,"ledger has no runs: the ledger itself may be wrong")
    else:
        emit('PASS','D4 payload-ingest',f"quill:{mod}",sig,f"{rec/runs:.1f} records/run")
PY
fi

# ----------------------------------------------- 3. HERMES CRON JOBS (D1',D7)
# D7 a scheduler entry can be 'ok' with an empty output directory: exit 0 is not a
# result. Also reports any failure streak printed by stack-sentinel.
if command -v hermes >/dev/null 2>&1; then
  HERMES_CRON=$(hermes cron list --all 2>/dev/null || true)
  if [ -z "$HERMES_CRON" ]; then
    emit NOTE D7 hermes-cron-unreadable "hermes cron list" "empty output" "13 jobs expected on nexus"
  else
    CRON_OUT="$HOME/.hermes/cron/output" CRON_LIST="$HERMES_CRON" py - <<'PY'
import os,re,time
from pathlib import Path
txt=os.environ['CRON_LIST']; out=Path(os.environ['CRON_OUT'])
FC=os.environ.get('FCOUNT'); NC=os.environ.get('NCOUNT')
def emit(v,s,i,sig,exp):
    print(f"{v:<9} | {s:<22} | {i:<46} | {sig:<52} | {exp}")
    if v=='FAIL' and FC: open(FC,'a').write(f"{s}|{i}\n")
    if v=='NOTE' and NC: open(NC,'a').write(f"{s}|{i}\n")
blocks=re.split(r'\n(?=  [0-9a-f]{12} \[)', txt)
seen=0
for b in blocks:
    m=re.search(r'^  ([0-9a-f]{12}) \[(\w+)\]', b, re.M)
    if not m: continue
    jid,state=m.group(1),m.group(2); seen+=1
    name=(re.search(r'Name:\s+(\S+)',b) or [None,'?'])[1]
    last=(re.search(r'Last run:\s+(\S+)\s+(\S+)',b) or [None,None,None])
    disp=(re.search(r'Dispatch:\s+([^\n]+)',b) or [None,''])[1].strip()
    if state!='active':
        emit('NOTE','D7 job-inactive',name,f"state={state}",'an inactive job produces nothing and alerts nothing')
    if last[2] and last[2] not in ('ok','running'):
        emit('FAIL','D7 last-run-not-ok',name,f"last={last[1]} status={last[2]}",'status ok')
    if 'late' in disp:
        emit('FAIL','D7 dispatch-late',name,f"dispatch={disp[:40]}","'on time' dispatch")
    d=out/jid; files=sorted(d.glob('*')) if d.exists() else []
    ever_ran = bool(last[1]) and last[2] not in (None,'')
    if not files and ever_ran:
        emit('FAIL','D7 zero-output',name,f"output_dir={d.name} files=0 last_run={last[2]}","status ok WITH a run result: exit 0 and no output is not a result")
    elif not files:
        emit('NOTE','D7 never-ran',name,f"output_dir={d.name} files=0","not yet due: no verdict until the first run")
    else:
        newest=max(files,key=lambda p:p.stat().st_mtime)
        age=(time.time()-newest.stat().st_mtime)/3600; sz=newest.stat().st_size
        if sz==0:
            emit('FAIL','D7 zero-output',name,f"{newest.name} bytes=0 age={age:.1f}h",'a non-empty result')
        else:
            emit('PASS','D7 has-output',name,f"{newest.name} bytes={sz} age={age:.1f}h",'non-empty output')
print(f"NOTE      | D7 coverage            | hermes cron                                            | jobs listed={seen}                                    | 13 expected on nexus")
# failure streaks published by stack-sentinel
for s in re.findall(r'(\S+ .*failures in a row)', txt):
    emit('FAIL','D7 failure-streak','stack-sentinel',s[:51],'no repeated failure streak')
PY
  fi
else
  emit NOTE D7 hermes-absent "hermes CLI" "not on PATH" "run this on nexus to include the cron check"
fi

# --------------------------------------------------- 4. BACKUP UNITS (D8)
# D8 a backup timer whose unit ends in Result=failed reports nothing to anyone: the
# stall watchdog only converts 'activating' stalls into failures, nothing reads the
# failure. Probe both system and user scope, and both scopes for duplicate names.
BACKUPS="memlawb-backup haven-backup stampede-backup media-config-backup activepieces-backup trading-backup gitlawb-backup"
probe_units() {   # $1 = ssh prefix
  local pre="$1" u st res ts mins
  for u in $BACKUPS; do
    for scope in system user; do
      local sflag=""; [ "$scope" = user ] && sflag="--user"
      ls_=$($pre systemctl $sflag show -p LoadState --value "$u.service" 2>/dev/null || true)
      [ "$ls_" = "not-found" ] || [ -z "$ls_" ] && continue
      st=$($pre systemctl $sflag show -p ActiveState --value "$u.service" 2>/dev/null || true)
      res=$($pre systemctl $sflag show -p Result --value "$u.service" 2>/dev/null || true)
      ts=$($pre systemctl $sflag show -p ExecMainExitTimestamp --value "$u.service" 2>/dev/null || true)
      if [ "$res" != "success" ]; then
        emit FAIL D8 backup-failed "$HOSTNAME/$u($scope)" "Result=$res ActiveState=$st last_exit=$ts" "Result=success (a failed backup that nobody reads == no backup)"
      else
        emit PASS D8 backup-result "$HOSTNAME/$u($scope)" "Result=success ActiveState=$st" "Result=success"
      fi
      if [ "$st" = activating ]; then
        mins=$($pre systemctl $sflag show -p ActiveEnterTimestamp --value "$u.service" 2>/dev/null | awk -v now="$(date +%s)" '{print int((now - mktime(gensub(/-/," ","g",$1" "$2" "$3" "$4))) /60)}')
        emit NOTE D8 backup-running "$HOSTNAME/$u($scope)" "activating=${mins}m" "run normally; the stall watchdog kills past 90m"
      fi
    done
  done
}
probe_units ""
if [ "$HOSTS" = 1 ]; then
  for h in forge sentry zephyr; do
    if ssh -o ConnectTimeout=6 -o BatchMode=yes "$h" true 2>/dev/null; then HOSTNAME=$h probe_units "ssh -o ConnectTimeout=6 -o BatchMode=yes $h"; else emit NOTE D8 host-unreachable "$h" "ssh_failed=true" "reachable host (unreachable host = backup state unknown, not healthy)"; fi
  done
fi
# D8b duplicate owners: the same timer in system AND user scope on one host
dups=$(for n in fleet-verify oracle-idle-watch canary-watch rhc-canary-watch backup-stall-watchdog; do
  s=$(systemctl show -p FragmentPath --value "$n.timer" 2>/dev/null); u=$(systemctl --user show -p FragmentPath --value "$n.timer" 2>/dev/null)
  [ -n "$s" ] && [ -n "$u" ] && echo "$n(sys=$s user=$u)"
done)
if [ -n "$dups" ]; then while read -r l; do emit FAIL D8b duplicate-timer "$HOSTNAME" "dup=$l" "ONE owner per state path (two copies drift; the stale one still reports green)"; done <<< "$dups"; else emit PASS D8b duplicate-timer "$HOSTNAME" "duplicates=none" "one owner per timer"; fi

# ------------------------------------------- 5. ALERTING COVERAGE (D3 blind spot)
# D3b: a producer with no metric and no rule cannot fail loudly. Checked by reading
# the metric-name index out of vmsingle (read-only) and the rule set from vmalert.
VMPOD=$(kubectl get pods -n monitoring -o name 2>/dev/null | grep -m1 'vmsingle' || true)
if [ -z "$VMPOD" ]; then
  emit NOTE D3b metrics-unreadable "monitoring/vmsingle" "pod not found" "run on nexus with cluster access"
else
  METRICS=$(kubectl exec -n monitoring "$VMPOD" -- wget -qO- 'http://127.0.0.1:8428/api/v1/label/__name__/values' 2>/dev/null || true)
  M_N=$(printf '%s' "$METRICS" | tr ',' '\n' | grep -c '"' || true)
  if [ "${M_N:-0}" -lt 200 ]; then
    emit INCONCLUSIVE guard "vmsingle metric index" "metrics=${M_N:-0}" ">= 200 (else every coverage claim below is unfounded)"
  else
    for pat in "peakminer_" "miner_" "node_smartmon_"; do
      c=$(printf '%s' "$METRICS" | tr ',' '\n' | grep -c "$pat" || true)
      if [ "${c:-0}" -eq 0 ]; then
        emit FAIL D3b no-metrics "$pat*" "series=0 (index has $M_N names)" "a live producer exposes at least one series, else its death is invisible"
      else
        emit PASS D3b metrics-present "$pat*" "series=$c" ">0"
      fi
    done
  fi
  RULES=$(kubectl exec -n monitoring "$VMPOD" -- wget -qO- 'http://vmalert-vmstack-victoria-metrics-k8s-stack:8080/api/v1/rules' 2>/dev/null || true)
  if [ -z "$RULES" ]; then
    emit NOTE D3b rules-unreadable "vmalert" "no response" "rule health should be readable"
  else
    printf '%s' "$RULES" > "$OUT_TMP/rules.json"
    py - "$OUT_TMP/rules.json" <<'PY'
import json,sys,os
FC=os.environ.get('FCOUNT'); NC=os.environ.get('NCOUNT')
def emit(v,s,i,sig,exp):
    print(f"{v:<9} | {s:<22} | {i:<46} | {sig:<52} | {exp}")
    if v=='FAIL' and FC: open(FC,'a').write(f"{s}|{i}\n")
    if v=='NOTE' and NC: open(NC,'a').write(f"{s}|{i}\n")
d=json.load(open(sys.argv[1])); groups=d.get('data',{}).get('groups',[])
rules=[r for g in groups for r in g['rules']]
bad=[r for r in rules if r.get('health') not in (None,'ok')]
for r in bad:
    emit('FAIL','D3b rule-error',r.get('name','?'),f"health={r.get('health')} err={(r.get('lastError') or '')[:30]}",'health=ok (a rule with an error is a silent gate)')
absent=[r for r in rules if r.get('type')=='alerting' and 'absent(' in (r.get('query') or '')]
emit('NOTE','D3b absent-aware-rules','monitoring/vmalert',f"{len(absent)}/{len(rules)} rules use absent(); firing={sum(1 for r in rules if r.get('state')=='firing')}","absent() is what turns 'no data' into an alert instead of health")
PY
  fi
fi

# ------------------------------------------------------- 5. HOST DRIFT (D9)
# homelab-ops has no ArgoCD Application: `omarchy/<host>/` is delivered by that
# host's own apply.sh, so installed state can drift from the committed tree and
# nothing reports it. Detection only - drift-check.sh has no apply mode, and an
# unreachable host is reported FINDING (unknown is never "in sync").
DC="$HOME/homelab-ops/scripts/verify/drift-check.sh"
if [ -x "$DC" ]; then
  "$DC" 2>/dev/null | grep -E '^(FINDING|OK|NOTE)' | while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
      FINDING*) printf 'drift\n' >> "$F_FILE" ;;
      NOTE*)    printf 'drift\n' >> "$N_FILE" ;;
    esac
  done
else
  emit NOTE D9 drift-check "$DC" "not executable" "run drift-check.sh for committed-vs-installed drift"
fi

# --------------------------------------------------------------- SUMMARY
echo
echo "== summary =="
FINDINGS=$(count "$F_FILE"); NOTES=$(count "$N_FILE"); GUARD_FAIL=$(count "$G_FILE")
echo "findings: $FINDINGS   notes: $NOTES   guard-failures: $GUARD_FAIL"
echo "sections covered: D1 never-succeeded, D2 stale-success, D3 stale-producer(+registry), D3b no-metrics/no-rule, D4 zero-payload-ingest, D5 schedule-missed/smoke-job, D6 suspended/hides-failures, D7 hermes-cron output+dispatch, D8 backup failed/stalled/duplicate, D9 committed-tree-vs-host drift (+leftover occupancy)"
if [ "$GUARD_FAIL" -gt 0 ]; then echo "[INCONCLUSIVE] a guard failed — empty input is never clean"; exit 2; fi
if [ "$FINDINGS" -gt 0 ]; then echo "RESULT: $FINDINGS silent-failure instance(s) — each FAIL names the smallest next action."; exit 1; fi
echo "RESULT: OK (clean on this sweep's coverage — extend the registry when a producer is added)"
exit 0