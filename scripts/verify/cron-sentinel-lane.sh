#!/usr/bin/env bash
# scripts/verify/cron-sentinel-lane.sh
#
# Is the nexus stack-sentinel cron job (ee4af9b4d0fb) still ABLE to run its agent
# layer? This exists because on 2026-10-14 that job had been failing for three
# weeks unnoticed: the model-health rotation had repinned it to a provider/model
# pair whose model name does not resolve on the endpoint the run actually used
# (agent.log: provider=opencode-go base_url=https://inference-api.nousresearch.com/v1
# model=deepseek-v4.1-flash -> HTTP 404 "Model 'deepseek-v4.1-flash' not found";
# the Nous endpoint serves it prefixed, as deepseek/deepseek-v4.1-flash), and the
# job had additionally drifted into no_agent mode, so the "diagnose each red +
# SENTINEL ACTION" layer never ran. The sentinel's own sweep then printed
# SENTINEL-RED about its own failure streak, its script exited 1 on that RED, the
# job stayed in error, and the streak could never clear — a self-sustaining red.
#
# Three assertions, in the order the scheduler evaluates them:
#   1. agent mode is on (no_agent=false) — otherwise the diagnosis layer is gone
#   2. the stored provider/base_url pair passes hermes' own credential-exfil
#      validator (tools.cronjob_job_args._validate_cron_base_url). A pair that
#      fails here fails every run with "blocked for safety" before the agent starts.
#   3. the pinned model actually answers on the pinned endpoint (1-token probe,
#      content OR reasoning_content accepted). This is the assertion the 2026-10-14
#      incident needed: a repin to an unfunded/renamed lane still looks healthy in
#      `hermes cron list` until a real completion is attempted.
#
# HOST: nexus (reads ~/.hermes/cron/jobs.json + ~/.hermes/.env). cwd: anywhere.
# READ-ONLY: file reads + one outbound 1-token probe per run. No store writes.
# FAILURE LOOKS LIKE: rc=1 with the specific assertion that broke; rc=2 when the job
#   record or the pinned endpoint cannot be read at all (inconclusive, not clean).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"

: "${HERMES_HOME:=$HOME/.hermes}"
JOBS="$HERMES_HOME/cron/jobs.json"
JOB_NAME="${JOB_NAME:-stack-sentinel}"
JOB_ID="${JOB_ID:-ee4af9b4d0fb}"
HERMES_SRC="${HERMES_SRC:-/opt/hermes-agent}"

echo "verify/cron-sentinel-lane.sh  host=$(hostname)  job=$JOB_NAME  read-only"
[ -f "$JOBS" ] || { inconclusive "job store not found: $JOBS"; finish; }
_hr

section "1. JOB RECORD + MODE"
REC="$("$PY" - "$JOBS" "$JOB_NAME" <<'PY'
import json, sys
store, name = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(store))
except Exception as exc:
    print("\t".join(["-", "-", "-", "-", "-", "unreadable: %s" % exc]))
    raise SystemExit(0)
jobs = data.get("jobs", data) if isinstance(data, dict) else data
job = next((j for j in jobs if isinstance(j, dict) and j.get("name") == name), None)
if not job:
    print("\t".join(["-", "-", "-", "-", "-", "absent"]))
    raise SystemExit(0)
err = " ".join(str(job.get("last_error") or "").split())[:140]
print("\t".join([
    str(job.get("provider") or "-"),
    str(job.get("model") or "-"),
    str(job.get("base_url") or "-"),
    "false" if job.get("no_agent") in (False, None) else "true",
    str(job.get("failure_streak") if job.get("failure_streak") is not None else "-"),
    err or "-",
]))
PY
)"
IFS=$'\t' read -r PROVIDER MODEL BASE_URL NO_AGENT STREAK LAST_ERR <<<"$REC"
echo "  provider=$PROVIDER  model=$MODEL  base_url=$BASE_URL"
echo "  no_agent=$NO_AGENT  failure_streak=$STREAK"
echo "  last_error=$LAST_ERR"
if [ "$PROVIDER" = "-" ]; then
  inconclusive "job record for '$JOB_NAME' is absent/unreadable in $JOBS — renamed, removed, or the store moved"
  finish
fi
check "$([ "$NO_AGENT" = "false" ] && echo 0 || echo 1)" \
  "agent mode is on (no_agent=false) — the SENTINEL ACTION layer can run"
[ "$NO_AGENT" = "false" ] || note "FIX: hermes cron edit $JOB_NAME --agent"
case "$LAST_ERR" in
  *"cron streak"*) note "last_error names a cron streak: the RED is about this job's own failures" ;;
esac

section "2. PROVIDER/BASE_URL PAIR (mirrors hermes' own scheduler guard)"
# The real guard is tools.cronjob_job_args._validate_cron_base_url, which fails CLOSED
# (refuses the run) whenever the override's host does not match the named provider's own
# registered endpoint. Its imports need a full hermes runtime, so this section applies the
# same host rule from the registry source instead of importing it:
#   provider's registered endpoint host == override host -> allowed, else refused.
if [ "$BASE_URL" = "-" ]; then
  note "no base_url override stored on the job — the run inherits the global endpoint"
else
  PAIR_VERDICT="$("$PY" - "$PROVIDER" "$BASE_URL" "$HERMES_SRC" <<'PY'
import re, sys
from urllib.parse import urlparse
prov, base_url, src = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    text = open(src + "/hermes_cli/auth.py", encoding="utf-8").read()
except OSError as exc:
    print("UNEVALUABLE registry-unreadable: %s" % exc)
    raise SystemExit(0)
entry = re.search(r'\("%s",\s*"[^"]*",\s*"([^"]+)"' % re.escape(prov), text)
if not entry:
    # Not a built-in provider: a named custom provider carries its own endpoint, and a
    # bare "custom" provider derives the key from the override itself — both are legal.
    print("UNEVALUABLE provider %r is not in the built-in registry (custom/BYOK provider)" % prov)
    raise SystemExit(0)
registered = urlparse(entry.group(1))
override = urlparse(base_url)
if registered.hostname and override.hostname and registered.hostname == override.hostname:
    print("")
else:
    print("base_url %r is not allowed for provider %r: registered endpoint host is %r, "
          "override host is %r — the scheduler refuses this pair at run time"
          % (base_url, prov, registered.hostname, override.hostname))
PY
)"
  case "$PAIR_VERDICT" in
    "" ) check 0 "provider=$PROVIDER may send its stored credential to base_url=$BASE_URL (hosts match)" ;;
    *UNEVALUABLE* ) inconclusive "could not evaluate the pair: $PAIR_VERDICT" ;;
    * ) check 1 "scheduler guard REJECTS provider=$PROVIDER with base_url=$BASE_URL :: $PAIR_VERDICT" ;;
  esac
fi

section "3. PINNED MODEL ANSWERS ON THE PINNED ENDPOINT"
"$PY" - "$PROVIDER" "$MODEL" "$BASE_URL" "$HERMES_HOME" "$JOB_ID" "$HERMES_SRC" <<'PY'
import json, os, re, subprocess, sys
prov, model, base_url, home, job_id, src = sys.argv[1:7]

def env_key(name):
    if not name:
        return ""
    if os.environ.get(name):
        return os.environ[name]
    try:
        for line in open(os.path.join(home, ".env")):
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return ""

url, key_env = "", ""
if base_url and base_url != "-":
    url = base_url.rstrip("/") + "/chat/completions"
if not url:
    # With no per-job override, a cron run inherits the GLOBAL model endpoint from
    # config.yaml (observed 2026-10-14: job provider=opencode-go, model=deepseek-v4.1-flash,
    # no override -> the run was sent to config.yaml's https://inference-api.nousresearch.com/v1
    # and 404'd, because that endpoint only serves the prefixed name deepseek/deepseek-v4.1-flash).
    # So the config's base_url is what must be probed here — the registry row would have probed
    # the provider's own endpoint and wrongly reported the lane healthy.
    cfg_url = ""
    try:
        for line in open(os.path.join(home, "config.yaml"), encoding="utf-8"):
            m = re.match(r"\s*base_url:\s*(\S+)", line)
            if m:
                cfg_url = m.group(1).strip().strip('"').strip("'")
                break
    except OSError:
        cfg_url = ""
    if cfg_url:
        print("   note: no per-job override — probing config.yaml model.base_url=%s" % cfg_url)
        url = cfg_url.rstrip("/") + "/chat/completions"
if not url:
    # Resolve the provider's own endpoint from the registry SOURCE (hermes_cli/auth.py) rather
    # than importing hermes: the CLI's interpreter has deps this check's python does not, and an
    # ImportError here would hide a dead lane behind an INCONCLUSIVE.
    try:
        text = open(src + "/hermes_cli/auth.py", encoding="utf-8").read()
        row = re.search(r'\("%s",\s*"[^"]*",\s*"([^"]*)",\s*\(([^)]*)\)' % re.escape(prov), text)
    except OSError as exc:
        print("   [INCONCLUSIVE] registry unreadable: %s" % exc)
        raise SystemExit(2)
    if not row:
        print("   [INCONCLUSIVE] provider %r has no registered endpoint row (custom/BYOK provider)" % prov)
        raise SystemExit(2)
    endpoint = row.group(1).strip()
    names = re.findall(r'"([A-Z0-9_]+)"', row.group(2))
    key_env = names[0] if names else ""
    if not endpoint:
        print("   [INCONCLUSIVE] provider %r registers no static endpoint" % prov)
        raise SystemExit(2)
    url = endpoint.rstrip("/") + "/chat/completions"
key = env_key(key_env) or env_key("OPENCODE_GO_API_KEY") or env_key("NOUS_API_KEY")
print("   endpoint=%s  model=%s  key_env=%s" % (url, model, key_env or "OPENCODE_GO_API_KEY/NOUS_API_KEY"))
if not key:
    print("   [INCONCLUSIVE] no credential found in the environment or %s/.env" % home)
    raise SystemExit(2)
body = json.dumps({"model": model, "max_tokens": 24,
                   "messages": [{"role": "user", "content": "reply with the single word: ok"}]})
cmd = ["curl", "-s", "-m", "30", url, "-H", "Authorization: Bearer " + key,
       "-H", "Content-Type: application/json", "-d", body]
if "opencode.ai" in url:  # the OpenCode relay requires this header, as the agent sends it
    cmd[4:4] = ["-H", "x-opencode-session: hermes-verify-probe"]
out = ""
try:
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=45).stdout
    data = json.loads(out)
except Exception as exc:
    print("   [INCONCLUSIVE] probe transport/parse failure (%s): %r" % (exc.__class__.__name__, out[:120]))
    raise SystemExit(2)
try:
    msg = data["choices"][0]["message"]
    # The Zen lane answers with reasoning_content and an EMPTY content field; reading
    # only `reasoning` made a healthy lane look "empty" on 2026-10-14.
    said = (msg.get("content") or "").strip() or (msg.get("reasoning_content") or "").strip()
except Exception:
    err = " ".join(str(data.get("error") or data.get("message") or data).split())[:180]
    print("   [FAIL] pinned lane does NOT serve model %r -> %s" % (model, err))
    print("          FIX: repin to a lane that answers (or restore the account):")
    print("               hermes cron edit %s --provider <provider> --model <model>" % job_id)
    raise SystemExit(1)
if not said:
    print("   [FAIL] pinned lane returned an empty completion for model %r" % model)
    raise SystemExit(1)
print("   [PASS] pinned lane answered (%s): %r" % (prov, said[:60]))
raise SystemExit(0)
PY
bump_rc "$?"
finish
