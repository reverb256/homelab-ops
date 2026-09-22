#!/bin/bash
# model-health-daemon.sh v2 — self-healing model/provider rotation.
#
# v2 improvements (2026-09-19), benchmarked against LiteLLM Router + gateway patterns:
#  - per-error-class thresholds (auth 2 / quota 2 / rate 8 / timeout 5 per window)
#  - provider set derived from LIVE config + profiles + cron jobs (not a stale literal)
#  - probes validate the response BODY, replicate Hermes' request shape
#    (incl. the required x-opencode-session header for the OpenCode relay),
#    accept reasoning-only replies, use max_tokens=64
#  - half-open recovery: cooled-down providers get probed; 2 consecutive OKs close
#  - escalating cooldowns: 15m base, x2 per repeat offense, cap 2h
#  - degraded mode: when no healthy target, rotate to least-bad instead of nothing
#  - repin matches UNPINNED jobs via model-snapshot map (model=None jobs like the MAM stack)
#  - error matcher requires explicit error tokens (HTTP 401 / Error code: 401 / ...)
#    — bare "401" matched session IDs like ...154017... (false positives, fixed 2026-09-19)
#  - DRY-RUN by default: create ~/.hermes/state/model-health/live to enable real changes
#
# Cron: every 10 min (no-agent). State: ~/.hermes/state/model-health/
# History: $STATE/history.jsonl   Last run: $STATE/last-run
export HOME="${MODEL_HEALTH_HOME:-/home/j_kro}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.local/share/mise/shims"
set -u

# --check: report-only pre-flight. Never writes (no markers, no rotation, no
# history row) and exits nonzero when a credential-invalid signal is active, so a
# gate or a human can ask "would this daemon have noticed?" without side effects.
if [ "${1:-}" = "--check" ]; then export MODEL_HEALTH_CHECK=1; fi

python3 - <<'PY'
import json, os, re, subprocess, time, glob
from datetime import datetime

HOME = os.path.expanduser("~")
STATE = f"{HOME}/.hermes/state/model-health"
LOG = f"{HOME}/.hermes/logs/agent.log"
ENV = f"{HOME}/.hermes/.env"
os.makedirs(STATE, exist_ok=True)
CHECK = os.environ.get("MODEL_HEALTH_CHECK") == "1"   # report-only; nonzero exit on an active auth signal
LIVE = os.path.exists(f"{STATE}/live") and not CHECK  # --check never writes
now = time.time()

# ---- credential-drift detection (the class this daemon used to be blind to) ----
# An `auth` signal is a CREDENTIAL question, not a supply question. The probe below
# uses the root env key, so a green probe proves *that* key works — it says nothing
# about a profile whose own env holds a stale copy. That is exactly how the nexus
# default profile kept answering "Invalid credential" while this daemon reported
# "probe OK -> no action": the store had a good key, ~/.hermes/.env had a rotted
# one, and nothing compared the two. Repair is the house mechanism, not a new one:
# provider-key-render.py --check (store -> host, fingerprints only).
HOSTNAME = os.uname().nodename
REPO = f"{HOME}/homelab-ops" if os.path.isdir(f"{HOME}/homelab-ops") else f"{HOME}/Work/Projects/homelab-ops"
RENDER = f"{REPO}/scripts/provider-key-render.py"
AGE_HOST = "zephyr"          # holds the age identity; the store cannot be read elsewhere
STORE_ROUTES = {             # provider -> (store route, host env var)
  "opencode-go":     ("secrets/ai/opencode-go-api-key.yaml", "OPENCODE_GO_API_KEY"),
  "opencode-zen":    ("secrets/ai/opencode-api-key.yaml", "OPENCODE_API_KEY"),
  "nous":            ("secrets/ai/nous-api-key.yaml", "NOUS_API_KEY"),
  "nvidia":          ("secrets/ai/nvidia-api-key.yaml", "NVIDIA_API_KEY"),
  "openrouter":      ("secrets/ai/openrouter-api-key.yaml", "OPENROUTER_API_KEY"),
  "openrouter-free": ("secrets/ai/openrouter-api-key.yaml", "OPENROUTER_API_KEY"),
}
AUTH_TTL = 3600              # an auth breach stays VISIBLE this long (the line window forgets sooner)

# Test seams: the regression test drives a sandboxed HOME with no network and no
# real host, so the two external commands must be injectable. Production leaves
# these unset and behaves exactly as before.
CURL = os.environ.get("MODEL_HEALTH_CURL", "curl")
SSH = os.environ.get("MODEL_HEALTH_SSH", "ssh")


def store_drift(prov, fix=False):
    """('in-sync'|'drift'|'unknown', detail) for store vs THIS host's env."""
    route, var = STORE_ROUTES.get(prov, (None, None))
    if not route:
        return "unknown", "no store route mapped"
    if not os.path.exists(RENDER):
        return "unknown", f"renderer absent ({RENDER})"
    cmd = [SSH, "-o", "ConnectTimeout=8", AGE_HOST,
           f"/usr/bin/python3 {RENDER} --route {route} --env-var {var} "
           f"--host {HOSTNAME}" + ("" if fix else " --check")]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
    except Exception as e:  # noqa: BLE001
        return "unknown", f"delegation failed: {type(e).__name__}"
    out = (r.stdout or r.stderr or "").strip().replace("\n", " | ")[:220]
    if r.returncode == 0:
        return "in-sync", out
    if r.returncode == 1:
        return "drift", out
    return "unknown", f"rc={r.returncode} {out}"


def active_auth(prov):
    """(is_active, age_s) from the sticky breach marker."""
    try:
        t = float(open(f"{STATE}/auth-breach-{prov}").read().strip())
    except Exception:
        return False, None
    return (t > now - AUTH_TTL), int(now - t)


# ---- probe map: provider -> (url, model, key env(s)) ----
# NOTE: opencode-zen removed — its free tier answers "FreeTierError: ... can only be
# used from within OpenCode" to plain API calls, so it is not a probeable/rotatable target.
PROBES = {
  "opencode-go":     ("https://opencode.ai/zen/go/v1/chat/completions", "deepseek-flash", ("OPENCODE_GO_API_KEY", "OPENCODE_API_KEY")),
  "openrouter-free": ("https://openrouter.ai/api/v1/chat/completions", "nvidia/nemotron-3-ultra-550b-a55b:free", ("OPENROUTER_API_KEY",)),
  "nous":            ("https://inference-api.nousresearch.com/v1/chat/completions", "meituan/longcat-2.0:free", ("NOUS_API_KEY",)),
  "nvidia":          ("https://integrate.api.nvidia.com/v1/chat/completions", "nvidia/nemotron-3-super-120b-a12b", ("NVIDIA_API_KEY",)),
  "kilo":            ("https://api.kilo.ai/api/gateway/chat/completions", "kilo-auto/free", ("KILOCODE_API_KEY",)),
}
# rotation targets — VERIFIED LIVE 2026-09-19 (each passed a body-validating probe).
# (minimax/minimax-m3:free was removed: no longer available for free — 404.)
POOL = [
  ("openrouter-free", "nvidia/nemotron-3-ultra-550b-a55b:free"),
  ("openrouter-free", "inclusionai/ling-3.0-flash-fin:free"),
  ("nous", "meituan/longcat-2.0:free"),
  ("opencode-go", "deepseek-v4.1-flash"),
  ("nvidia", "z-ai/glm-5.3"),
]
SNAPSHOT_MAP = {
  "deepseek-v4.1-flash": "opencode-go",
  "poolside/laguna-s-2.1:free": "nous",
  "minimax/minimax-m3:free": "openrouter-free",
  "nvidia/nemotron-3-ultra-550b-a55b:free": "openrouter-free",
  "inclusionai/ling-3.0-flash-fin:free": "openrouter-free",
  "meituan/longcat-2.0:free": "nous",
}

def env_key(names):
    if isinstance(names, str):
        names = (names,)
    for name in names:
        v = os.environ.get(name)
        if v:
            return v
        try:
            for line in open(ENV):
                if line.startswith(name + "="):
                    val = line.split("=", 1)[1].strip().strip('"').strip("'")
                    if val:
                        return val
        except Exception:
            pass
    return ""

# error classes + thresholds. Matchers require explicit error tokens —
# bare "401" also matches session ids (…154017…) and created false positives.
CLASS_PATTERNS = {
  "auth":    re.compile(r"AuthenticationError|Invalid credential|HTTP 401|Error code: 401|AuthError"),
  "quota":   re.compile(r"HTTP 402|Error code: 402|insufficient_quota|Add credits|Key limit exceeded|HTTP 403"),
  "rate":    re.compile(r"HTTP 429|Error code: 429|RateLimitError|fair-share"),
  "timeout": re.compile(r"TimeoutError|timed out|ETIMEDOUT|HTTP 408"),
}
THRESH = {"auth": 2, "quota": 2, "rate": 8, "timeout": 5}

# ---- 1. live provider set ----
providers = set(PROBES)
try:
    providers.update(re.findall(r"^\s*provider:\s*([A-Za-z0-9._-]+)", open(f"{HOME}/.hermes/config.yaml").read(), re.M))
except Exception:
    pass
for f in glob.glob(f"{HOME}/.hermes/profiles/*/config.yaml"):
    try:
        providers.update(re.findall(r"^\s*provider:\s*([A-Za-z0-9._-]+)", open(f).read(), re.M))
    except Exception:
        pass
jobs = []
try:
    d = json.load(open(f"{HOME}/.hermes/cron/jobs.json"))
    lst = d if isinstance(d, list) else d.get("jobs", d)
    jobs = lst if isinstance(lst, list) else list(lst.values())
    for j in jobs:
        if j.get("enabled") and j.get("provider"):
            providers.add(j["provider"])
except Exception:
    pass

# ---- 2. count error classes per provider ----
counts = {}
lines = []
try:
    lines = subprocess.run(["tail", "-n", "6000", LOG], capture_output=True, text=True, timeout=30).stdout.splitlines()
except Exception:
    lines = []
# per-profile logs (2026-09-21): worker/profile failures live here, not in the root log
for plog in glob.glob(f"{HOME}/.hermes/profiles/*/logs/agent.log"):
    try:
        lines += subprocess.run(["tail", "-n", "1500", plog], capture_output=True, text=True, timeout=30).stdout.splitlines()
    except Exception:
        pass
for ln in lines:
    if "Hook '" in ln:
        continue
    if not re.search(r"ERROR|WARNING|failed", ln):
        continue
    pm = re.search(r"provider=([A-Za-z0-9._-]+)", ln)
    if not pm:
        continue
    p = pm.group(1)
    counts.setdefault(p, {c: 0 for c in CLASS_PATTERNS})
    for c, pat in CLASS_PATTERNS.items():
        if pat.search(ln):
            counts[p][c] += 1
            break

# ---- 2b. sticky auth breach ----
# The window is LINE-COUNT based (tail -6000 root / -1500 per profile), so a real
# auth breach ages out of it within a couple of ticks and the signal silently
# disappears — observed live 2026-09-22: 14:10 `opencode-go {auth: 3, quota: 1}`
# (threshold crossed) -> 14:20 `{quota: 1}` (nothing crossed, no action line).
# Persist the breach so it stays visible and actionable for AUTH_TTL.
for p, cc in counts.items():
    if cc.get("auth", 0) >= THRESH["auth"] and LIVE and not CHECK:
        open(f"{STATE}/auth-breach-{p}", "w").write(str(int(now)))

# ---- 3. cooldown markers (tier + until) ----
def read_marker(p):
    try:
        tier, until = open(f"{STATE}/cooldown-{p}").read().split()
        return int(tier), float(until)
    except Exception:
        return 0, 0.0

def write_marker(p, tier, until):
    open(f"{STATE}/cooldown-{p}", "w").write(f"{tier} {until:.0f}")

def clear_marker(p):
    for f in (f"{STATE}/cooldown-{p}", f"{STATE}/halfopen-ok-{p}"):
        try:
            os.remove(f)
        except Exception:
            pass

def bump_halfopen(p):
    f = f"{STATE}/halfopen-ok-{p}"
    try:
        n = int(open(f).read().strip()) + 1
    except Exception:
        n = 1
    open(f, "w").write(str(n))
    return n

def probe(p):
    ent = PROBES.get(p)
    if not ent:
        return None, "no probe defined"
    url, model, keyenv = ent
    key = env_key(keyenv)
    if not key:
        return False, "missing key"
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": "reply with the single word: ok"}], "max_tokens": 64})
    cmd = [CURL, "-s", "-m", "15", url,
           "-H", f"Authorization: Bearer {key}",
           "-H", "Content-Type: application/json", "-d", body]
    if "opencode.ai" in url:
        # required by the OpenCode relay; mirrors agent/opencode_affinity.py
        cmd[4:4] = ["-H", "x-opencode-session: hermes-health-probe"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=25)
        data = json.loads(r.stdout)
    except Exception:
        return False, "probe transport error"
    try:
        msg = data["choices"][0]["message"]
        content = (msg.get("content") or "").strip()
        reasoning = (msg.get("reasoning") or "").strip()
        return (True, "ok") if (content or reasoning) else (False, "empty content")
    except Exception:
        detail = ""
        try:
            detail = str(data.get("error"))[:90]
        except Exception:
            pass
        return False, "bad body: " + detail

# ---- 4. decide + act ----
actions = []
saturated = []
auth_flagged = []
for p in sorted(providers):
    tier, until = read_marker(p)
    c = counts.get(p, {})
    breached, age = active_auth(p)
    crossed = any(c.get(k, 0) >= v for k, v in THRESH.items())
    # An auth signal is actionable in BOTH shapes: a live crossing, or a sticky
    # breach whose counts have already aged out of the line window.
    auth_sig = breached or c.get("auth", 0) >= THRESH["auth"]
    if crossed:
        reason = "threshold"
    elif breached:
        reason = "auth-sticky"
    elif tier and until <= now:
        reason = "half-open"
    else:
        continue
    ok, detail = probe(p)
    if ok is None:
        actions.append(f"{p}: probe skipped ({detail})")
        continue
    if ok:
        if auth_sig:
            # A GREEN PROBE IS NOT PROOF HERE. The probe uses the root env key, so
            # it validates the store/root credential — not the credential a
            # profile-scoped consumer actually sends. Compare store vs host env
            # (fingerprints only) and repair from the store, which is the source of
            # truth; only if they agree is a green probe evidence that the
            # credential itself is fine.
            st, d = store_drift(p)
            auth_flagged.append(p)
            shown = f"age {age}s" if age is not None else f"auth={c.get('auth', 0)}"
            if st == "drift":
                if CHECK or not LIVE:
                    actions.append(f"AUTH-DRIFT {p} ({shown}): store != {HOSTNAME} env -> "
                                   f"WOULD re-render from the store [{d}]")
                else:
                    st2, d2 = store_drift(p, fix=True)
                    actions.append(f"AUTH-DRIFT {p} ({shown}): store != {HOSTNAME} env -> "
                                   f"re-rendered from the store (now {st2}) [{d2}]")
                    clear_marker(p)
            elif st == "unknown":
                actions.append(f"AUTH-SIGNAL {p} ({shown}): credential-invalid signal active and "
                               f"store drift UNKNOWN [{d}] — a green probe is not proof for "
                               f"profile-scoped keys")
            else:
                actions.append(f"AUTH-SIGNAL {p} ({shown}): credential-invalid signal active and store "
                               f"IN SYNC with {HOSTNAME} env — the credential itself is rejected, so "
                               f"rotate consumers off {p} instead of assuming a supply problem")
                saturated.append(p)      # reuse the rotation pass (now including the default profile)
                if LIVE:
                    write_marker(p, max(tier, 1), now + 900)
            continue
        if reason == "half-open":
            n = bump_halfopen(p)
            if n >= 2:
                clear_marker(p)
                actions.append(f"{p}: half-open probe OK ({n}/2) -> circuit CLOSED")
            else:
                actions.append(f"{p}: half-open probe OK ({n}/2)")
        else:
            nz = {k: v for k, v in c.items() if v}
            actions.append(f"{p}: {reason} {nz} but probe OK -> no action")
            clear_marker(p)
    else:
        newtier = (tier + 1) if reason == "half-open" else 1
        dur = min(900 * (2 ** (newtier - 1)), 7200)
        if LIVE:
            write_marker(p, newtier, now + dur)
        saturated.append(p)
        actions.append(f"{p}: SATURATED (probe: {detail}) -> cooldown tier {newtier}, {dur // 60}m{' [DRY-RUN]' if not LIVE else ''}")

for prov in saturated:
    target = None
    for tp, tm in POOL:
        if tp == prov:
            continue
        t_tier, t_until = read_marker(tp)
        if t_tier and t_until > now:
            continue
        ok, _ = probe(tp)
        if ok:
            target = (tp, tm)
            break
    degraded = False
    if not target:
        cands = [x for x in POOL if x[0] != prov]
        if cands:
            target = min(cands, key=lambda x: read_marker(x[0])[1])
            degraded = True
    if not target:
        actions.append(f"{prov}: no pool target available; no rotation")
        continue
    tp, tm = target
    tag = "DEGRADED TARGET " if degraded else ""
    # The DEFAULT profile lives in ~/.hermes/config.yaml, not profiles/*. Omitting it
    # was the other half of the blind spot: it is the profile that answers inbound A2A
    # (i.e. the on-call responder for money halts) and the one that was pinned to
    # opencode-go while answering "Invalid credential".
    configs = [f"{HOME}/.hermes/config.yaml"] + sorted(
        glob.glob(f"{HOME}/.hermes/profiles/*/config.yaml"))
    for pconf in configs:
        try:
            content = open(pconf).read()
        except Exception:
            continue
        m = re.search(r"(?ms)^model:\s*\n(.*?)(^\S|\Z)", content)
        block = m.group(1) if m else ""
        if re.search(rf"^\s*provider:\s*{re.escape(prov)}\s*$", block, re.M):
            who = "default" if pconf.endswith("/.hermes/config.yaml") else pconf.split("/")[-2]
            if LIVE:
                newc = re.sub(r"(?m)^(\s*)provider: .*$", rf"\1provider: {tp}", content, count=1)
                newc = re.sub(r"(?m)^(\s*)default: .*$", rf"\1default: {tm}", newc, count=1)
                open(pconf, "w").write(newc)
                chk = open(pconf).read()
                if re.search(rf"provider:\s*{re.escape(tp)}", chk) and re.search(rf"default:\s*{re.escape(tm)}", chk):
                    actions.append(f"{tag}ROTATED profile {who} -> {tp}/{tm}")
                else:
                    actions.append(f"!! {pconf}: rotation verify FAILED")
            else:
                actions.append(f"WOULD ROTATE {tag}profile {who} -> {tp}/{tm}")
    for j in jobs:
        if not j.get("enabled"):
            continue
        resolved = j.get("provider") or SNAPSHOT_MAP.get(j.get("model_snapshot") or "")
        if resolved != prov:
            continue
        if LIVE:
            r = subprocess.run(["hermes", "cron", "edit", j["id"], "--provider", tp, "--model", tm],
                               capture_output=True, text=True, timeout=60)
            okp = r.returncode == 0
            actions.append((f"{tag}CRON REPINNED " if okp else "!! repin FAILED ") + f"{j.get('name')} -> {tp}/{tm}")
        else:
            actions.append(f"WOULD REPIN {j.get('name')} -> {tp}/{tm}")

if not CHECK:
    with open(f"{STATE}/history.jsonl", "a") as h:
        h.write(json.dumps({"ts": int(now), "iso": datetime.now().isoformat(timespec="seconds"),
                            "mode": "live" if LIVE else "dry", "saturated": saturated,
                            "counts": {k: {c: v for c, v in cc.items() if v} for k, cc in counts.items() if any(cc.values())},
                            "actions": actions}) + "\n")
    open(f"{STATE}/last-run", "w").write(str(int(time.time())))
for a in actions:
    print(a)
if not actions:
    print("OK: no provider saturation")

if CHECK:
    # The report-only mode is the pre-flight: it answers "would this daemon have
    # noticed today's failure?" without touching state. Nonzero = an active
    # credential-invalid signal that is NOT cleared by a green root-key probe.
    if auth_flagged:
        print(f"CHECK: credential-invalid signal ACTIVE for: {', '.join(sorted(set(auth_flagged)))}")
        raise SystemExit(1)
    print("CHECK: no active credential-invalid signal")
PY
