#!/bin/bash
# model-health-daemon.sh v3 (2026-10-16) — self-healing model/provider rotation.
#
# v3 (card t_7d75bafd): the probe map, the rotation pool and the dead-provider list
# are now DATA from `scripts/fleet-routing.json` (the fleet routing spec — the
# source of record, verified by `fleet-route.py probe`), not literals in this file
# that rot. v2 shipped three defects that made this daemon the reason a fixed fleet
# went BACK to the dead primary:
#   * its `nous` probe used meituan/longcat-2.0:free and its `openrouter-free`
#     probe nvidia/nemotron-3-ultra-550b-a55b:free — both 404 — so two HEALTHY
#     providers were reported SATURATED on every tick ("probe: bad body: None");
#   * its rotation pool then offered opencode-go/deepseek-v4.1-flash, the one
#     provider whose probe passes HERE (this probe sends the required
#     x-opencode-session header; the agent path does not) while its real answer is
#     HTTP 400 MissingSessionID. Measured 17:00:57 and 17:10:56 on 2026-10-16:
#     "ROTATED profile reviewer -> opencode-go/deepseek-v4.1-flash", twice, over a
#     fix that had landed minutes earlier — and again at 18:40:57, over 20 profiles
#     re-pointed at 18:37;
#   * the rotation rewrote model.provider + model.default and LEFT model.base_url
#     alone, so a rotated profile kept calling the OLD host. Live state it left
#     behind: provider opencode-go with base_url
#     https://inference-api.nousresearch.com/v1.
# It also now rotates consumers OFF a provider the spec lists as dead (a probe is
# not evidence there: this probe answers 200 on opencode-go while the agent path
# gets 400), and it will not move a panel judge (spec `judge_family`) to another
# model family.
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


# ---- probe map + rotation pool: DATA from the fleet routing spec ----
# v3 (2026-10-16, card t_7d75bafd). Both maps used to be literals here, and both
# rotted while the fleet ran on live traffic:
#
#   * the probe for `nous` used meituan/longcat-2.0:free and for `openrouter-free`
#     nvidia/nemotron-3-ultra-550b-a55b:free — both dead (404). Measured
#     2026-10-16: both providers were reported SATURATED on EVERY tick, "probe:
#     bad body: None", while answering real turns fine (nous answered a JSON
#     judge call in 1.3-4.0 s, 3/3);
#   * POOL then offered opencode-go/deepseek-v4.1-flash as the rotation target —
#     the ONE provider whose probe PASSES here (this probe sends the required
#     x-opencode-session header; the agent path does not) and whose real API
#     answer is HTTP 400 MissingSessionID. So the "self-healing" rotator drove
#     every nous/openrouter-free profile ONTO the dead provider: it logged
#     "ROTATED profile reviewer -> opencode-go/deepseek-v4.1-flash" at 17:00:57
#     and again at 17:10:56, and 20 profiles at 18:40:57, over fixes that had
#     landed minutes earlier. The cron output is
#     ~/.hermes/cron/output/292b321c453a/.
#
# The spec is now the source of record: scripts/fleet-routing.json next to
# fleet-route.py carries providers (base_url + api_key_env + the probe model),
# dead_providers, dead_slugs and rotation_pool. `fleet-route.py probe` verifies
# the same set on a schedule. The literals below are only a fallback for a host
# without the checkout, and they hold the slugs measured live on 2026-10-16.
SPEC_PATH = os.environ.get("MODEL_HEALTH_SPEC", f"{HOME}/ai-content-pipeline/scripts/fleet-routing.json")
try:
    SPEC = json.load(open(SPEC_PATH))
except Exception:
    SPEC = {}

# NOTE: opencode-zen removed — its free tier answers "FreeTierError: ... can only be
# used from within OpenCode" to plain API calls, so it is not a probeable/rotatable target.
PROBES = {
  "opencode-go":     ("https://opencode.ai/zen/go/v1/chat/completions", "deepseek-v4.1-flash", ("OPENCODE_GO_API_KEY", "OPENCODE_API_KEY")),
  "openrouter-free": ("https://openrouter.ai/api/v1/chat/completions", "nvidia/nemotron-3-super-120b-a12b:free", ("OPENROUTER_API_KEY",)),
  "nous":            ("https://inference-api.nousresearch.com/v1/chat/completions", "poolside/laguna-s-2.1:free", ("NOUS_API_KEY",)),
  "nvidia":          ("https://integrate.api.nvidia.com/v1/chat/completions", "nvidia/nemotron-3-super-120b-a12b", ("NVIDIA_API_KEY",)),
  "kilo":            ("https://api.kilo.ai/api/gateway/chat/completions", "kilo-auto/free", ("KILOCODE_API_KEY",)),
}
for _p, _d in (SPEC.get("providers") or {}).items():
    _base, _model, _key = _d.get("base_url"), _d.get("model"), _d.get("api_key_env")
    if _base and _model and _key:
        PROBES[_p] = (_base.rstrip("/") + "/chat/completions", _model, (_key,))
# base_url per provider, so a rotation moves the ENDPOINT with the provider.
PROVIDER_BASE = {p: d.get("base_url") for p, d in (SPEC.get("providers") or {}).items()
                 if d.get("base_url")}

# rotation targets, best first. Every entry must be a provider that ANSWERS a
# body-validating probe; the loop below probes each candidate before it is used.
POOL = [(x["provider"], x["model"]) for x in (SPEC.get("rotation_pool") or [])
        if isinstance(x, dict) and x.get("provider") and x.get("model")]
if not POOL:
    POOL = [
      ("kilo", "kilo-auto/free"),
      ("nous", "poolside/laguna-s-2.1:free"),
      ("nvidia", "z-ai/glm-5.3"),
      ("nous", "poolside/laguna-xs-2.1:free"),
    ]
# Providers that cannot serve an API caller at all. Consumers are rotated OFF
# these on sight, whatever the error window says — a dead primary costs the first
# call of every session.
DEAD = set(SPEC.get("dead_providers") or []) or {"opencode-go", "opencode-zen"}
# Slugs the spec measured dead. A rotation target must not be one of them: this
# probe validates a PROVIDER, so a pool entry carrying a dead slug would be picked
# on the strength of its provider alone (measured trap: pool entry
# opencode-go/deepseek-v4.1-flash passed here while every agent call 400'd).
DEAD_SLUGS = set(SPEC.get("dead_slugs") or [])
# Profiles whose routing is a CONTRACT with another lane: the music review panel
# needs three DISJOINT model families (music/rubrics/README.md, enforced by
# music/scripts/check_panel_membership.py). This daemon may heal a dead primary
# for such a profile, but only with a target from the SAME family.
PINS = {n: (v.get("judge_family") or "")
        for n, v in (SPEC.get("profiles") or {}).items() if v.get("judge_family")}
SNAPSHOT_MAP = {
  "deepseek-v4.1-flash": "opencode-go",
  "poolside/laguna-s-2.1:free": "nous",
  "poolside/laguna-xs-2.1:free": "nous",
  "reflection/beam-1.0-501b-a23b:free": "nous",
  "nvidia/nemotron-3-super-120b-a12b": "nvidia",
  "nvidia/nemotron-3-super-120b-a12b:free": "nvidia",
  "z-ai/glm-5.3": "nvidia",
  "kilo-auto/free": "kilo",
  "dots-studio/dots-3-note-preview:free": "kilo",
  "meituan/longcat-2.0:free": "nous",
  "nvidia/nemotron-3-ultra-550b-a55b:free": "openrouter-free",
  "inclusionai/ling-3.0-flash-fin:free": "openrouter-free",
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
    # max_tokens 256, not 64 (card t_7d75bafd). A reasoning model spends its
    # budget on reasoning FIRST. Measured 2026-10-16: nvidia nemotron-3-super
    # answers {"content": null, "reasoning_content": "..."} at max_tokens=64
    # (finish_reason=length, 64/64 reasoning tokens) and real JSON content at 800
    # — so a 64-token probe reported a HEALTHY provider as SATURATED and handed
    # its profiles to the rotator. Also: the reasoning key is `reasoning_content`
    # on NIM and `reasoning` on nous; reading only `reasoning` sees neither.
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": "reply with the single word: ok"}], "max_tokens": 256})
    # -m 45, not 15: a reasoning model at 256 tokens can take ~20 s (measured:
    # z-ai/glm-5.3 on NIM, 19.3 s for 380 completion tokens on 2026-10-16). A
    # 15 s cap makes a SLOW provider look DEAD, which is the same false
    # saturation this probe exists to stop reporting.
    cmd = [CURL, "-s", "-m", "45", url,
           "-H", f"Authorization: Bearer {key}",
           "-H", "Content-Type: application/json", "-d", body]
    if "opencode.ai" in url:
        # required by the OpenCode relay; mirrors agent/opencode_affinity.py
        cmd[4:4] = ["-H", "x-opencode-session: hermes-health-probe"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        data = json.loads(r.stdout)
    except Exception:
        return False, "probe transport error"
    try:
        msg = data["choices"][0]["message"]
        content = (msg.get("content") or "").strip()
        # `reasoning` (nous) or `reasoning_content` (nvidia NIM). Reading only
        # `reasoning` made every NIM reasoning model look EMPTY (card t_7d75bafd).
        reasoning = (msg.get("reasoning") or msg.get("reasoning_content") or "").strip()
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

# ---- 4c. a provider the SPEC lists as dead: rotate consumers OFF it ----
# This is the repair the fleet needed on 2026-10-16 and the daemon never made: v2
# only ever rotated when the ERROR WINDOW tripped, and its POOL pointed BACK at
# the dead provider, so profiles stayed on opencode-go (HTTP 400 MissingSessionID)
# indefinitely while the rotator reported healthy operation.
#
# The list is DATA (`dead_providers` in the spec), not this probe's opinion — and
# that matters, because this probe CANNOT see the defect: it sends the required
# x-opencode-session header (mirroring agent/opencode_affinity.py) while the
# agent's own path does not. Measured 2026-10-16: the probe answers 200 here and
# the agent answers HTTP 400 MissingSessionID on the same provider, so a green
# probe is not evidence of a usable provider. A spec-dead provider is rotated off
# on sight, and the disagreement is logged.
for prov in sorted(DEAD):
    if prov in saturated or prov in auth_flagged:
        continue
    ok, detail = probe(prov)
    if ok is None:
        actions.append(f"{prov}: listed DEAD in the spec and not probeable ({detail}) "
                       f"-> rotating consumers off it")
    elif ok:
        actions.append(f"{prov}: listed DEAD in the spec but this probe ANSWERS — the probe "
                       f"sends x-opencode-session and the agent path does not, so this is not "
                       f"evidence the provider is usable -> rotating consumers off it")
    else:
        actions.append(f"{prov}: DEAD for API callers (probe: {detail}) -> rotating consumers off it")
    saturated.append(prov)


def family_of(model):
    return (model or "").split("/")[0].strip().lower()


_TARGETS = {}


def pick_target(prov, pin):
    """(provider, model, degraded) to move a consumer of `prov` onto, or None.

    `pin` is a model FAMILY. When it is set, the consumer's routing is a contract
    with another lane (the reviewer* profiles — the music review panel needs three
    DISJOINT families, music/rubrics/README.md), so only a SAME-FAMILY target may
    be used: a repair must never collide two sibling judges.
    """
    ck = (prov, pin)
    if ck in _TARGETS:
        return _TARGETS[ck]
    chosen = None
    for tp, tm in POOL:
        if tp == prov or tp in DEAD or tm in DEAD_SLUGS:
            continue
        if pin and family_of(tm) != pin:
            continue
        t_tier, t_until = read_marker(tp)
        if t_tier and t_until > now:
            continue
        ok, _ = probe(tp)
        if ok:
            chosen = (tp, tm, False)
            break
    if not chosen:
        cands = [(tp, tm) for tp, tm in POOL
                 if tp != prov and tp not in DEAD and tm not in DEAD_SLUGS
                 and (not pin or family_of(tm) == pin)]
        if cands:
            chosen = (cands[0][0], cands[0][1], True)
    _TARGETS[ck] = chosen
    return chosen


def block_span(content):
    """The TOP-LEVEL `model:` block as a match whose group(1) is its body."""
    m = re.search(r"(?ms)^model:[ \t]*\n(.*?)(^\S|\Z)", content)
    return m if m else None


def rotate_block(block, tp, tm):
    """Rewrite ONE model block: provider, default, AND the endpoint that must
    follow the provider.

    Measured defect this fixes (2026-10-16, card t_7d75bafd): v2 substituted
    provider + default and left model.base_url alone, so profile `reviewer` ended
    up with provider `opencode-go` and base_url
    `https://inference-api.nousresearch.com/v1` — the OpenCode model name sent to
    the Nous host. Every call fails there, and `fleet-route.py audit` (which reads
    provider + model) cannot see it.
    """
    tbase = PROVIDER_BASE.get(tp, "")
    want = [("provider", tp), ("default", tm)] + ([("base_url", tbase)] if tbase else [])
    wantd = dict(want)
    keys = {}
    for ln in block.split("\n"):
        s = ln.strip()
        if s and ln[:1] in (" ", "\t") and ":" in s:
            keys[s.split(":", 1)[0].strip()] = ln[: len(ln) - len(ln.lstrip())]
    out, seen = [], set()
    for ln in block.split("\n"):
        s = ln.strip()
        k = s.split(":", 1)[0].strip() if (s and ln[:1] in (" ", "\t") and ":" in s) else ""
        if k in wantd and k not in seen:
            out.append(f"{keys.get(k, '  ')}{k}: {wantd[k]}")
            seen.add(k)
            continue
        out.append(ln)
    missing = [(k, v) for k, v in want if k not in seen]
    if tbase and "api_mode" not in keys:
        missing.append(("api_mode", "chat_completions"))
    if missing:
        anchor = next((i for i, ln in enumerate(out) if ln.strip().startswith("provider:")), None)
        ind = keys.get("provider", "  ")
        add = [f"{ind}{k}: {v}" for k, v in missing]
        out = (out[: anchor + 1] + add + out[anchor + 1:]) if anchor is not None else add + out
    return "\n".join(out)


for prov in saturated:
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
        m = block_span(content)
        if not m:
            continue
        block = m.group(1)
        if not re.search(rf"^\s*provider:\s*{re.escape(prov)}\s*$", block, re.M):
            continue
        who = "default" if pconf.endswith("/.hermes/config.yaml") else pconf.split("/")[-2]
        pin = PINS.get(who, "")
        target = pick_target(prov, pin)
        if not target:
            actions.append(f"!! {who}: primary {prov} is saturated but the rotation pool holds no "
                           f"{('same-family (' + pin + ') ') if pin else ''}live target "
                           f"({SPEC_PATH}) — a cross-family move is NOT allowed for a panel judge")
            continue
        tp, tm, degraded = target
        tag = "DEGRADED TARGET " if degraded else ""
        if not LIVE:
            actions.append(f"WOULD ROTATE {tag}profile {who} -> {tp}/{tm}")
            continue
        newc = content[: m.start(1)] + rotate_block(block, tp, tm) + content[m.end(1):]
        tmpf = pconf + ".tmp-health"
        open(tmpf, "w").write(newc)
        os.replace(tmpf, pconf)
        chk = open(pconf).read()
        cm = block_span(chk)
        cblock = cm.group(1) if cm else chk
        tbase = PROVIDER_BASE.get(tp, "")
        okp = (re.search(rf"^\s*provider:\s*{re.escape(tp)}\s*$", cblock, re.M)
               and re.search(rf"^\s*default:\s*{re.escape(tm)}\s*$", cblock, re.M)
               and (not tbase or re.search(rf"^\s*base_url:\s*{re.escape(tbase)}\s*$", cblock, re.M)))
        actions.append(f"{tag}ROTATED profile {who} -> {tp}/{tm}" if okp else
                       f"!! {pconf}: rotation verify FAILED (provider/default/base_url did not all move)")
    for j in jobs:
        if not j.get("enabled"):
            continue
        resolved = j.get("provider") or SNAPSHOT_MAP.get(j.get("model_snapshot") or "")
        if resolved != prov:
            continue
        jt = pick_target(prov, None)
        if not jt:
            actions.append(f"!! cron {j.get('name')}: no pool target available; not repinned")
            continue
        tp, tm, jdeg = jt
        tag = "DEGRADED TARGET " if jdeg else ""
        if LIVE:
            # HERMES_HOME is pinned here on purpose. This script may be invoked from
            # a PROFILE shell (HERMES_HOME=~/.hermes/profiles/<p>), and `hermes cron
            # edit` would then read THAT profile's job store instead of the root one
            # this loop just read from disk. Measured 2026-10-16: "Job not found:
            # ee4af9b4d0fb" (stack-sentinel, pinned to opencode-go) so the job stayed
            # on the dead provider.
            r = subprocess.run(["hermes", "cron", "edit", j["id"], "--provider", tp, "--model", tm],
                               capture_output=True, text=True, timeout=60,
                               env=dict(os.environ, HERMES_HOME=f"{HOME}/.hermes"))
            okp = r.returncode == 0
            err = "" if okp else (r.stderr or r.stdout or "").strip().replace("\n", " ")[:120]
            actions.append((f"{tag}CRON REPINNED " if okp else f"!! repin FAILED ({err}) ")
                           + f"{j.get('name')} -> {tp}/{tm}")
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
