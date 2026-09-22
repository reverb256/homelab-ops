#!/usr/bin/env python3
"""a2a-profile-identity-cleanup.py — stop non-owning profiles from serving A2A.

Blocker 3.14 residual. Two defects, one fix.

1. FOREIGN identity. 13 profiles on nexus carried `A2A_HOST=100.91.11.2`
   (zephyr's tailnet IP) plus a copy of zephyr's token set, so their A2A adapter
   tried to bind an address this host does not own:

     A2A: could not bind 100.91.11.2:9900 — [Errno 99] Cannot assign requested address
     552 occurrences in 3 h, on every gateway start.

   It is also a `SECRETS.md` rule-3 violation: the same secret with two delivery
   paths, one of them stale.

2. INHERITANCE. A profile that does not disable the platform INHERITS the root
   config's `gateway.platforms.a2a.enabled: true`, so it starts its own adapter
   and races for :9900. With no A2A_HOST of its own it resolves to 127.0.0.1,
   where the documented localhost-only fallback treats the SOCKET as the
   credential and answers ANY request with 200 — so an arbitrary token-less
   profile can end up serving loopback unauthenticated. That is the 3.14 hole,
   and it is timing-dependent, which is why it comes and goes.

The invariant is ONE listener per host (`ss -ltnp | grep :9900`), owned by the
profile that holds this host's A2A identity. Everything else is disabled
explicitly, using the same top-level `platforms:` knob the fleet already uses
(a YAML round-trip is deliberately NOT used: it strips comments and reformats
the file — a targeted line edit keeps the file byte-stable elsewhere).

Idempotent; backs up every file it changes; prints what changed.
Run on the host, then `systemctl --user restart hermes-gateway`.
"""
from __future__ import annotations

import pathlib
import re
import shutil
import sys
import time

import yaml

HOME = pathlib.Path.home()
HH = HOME / ".hermes"
PROFILES = HH / "profiles"
A2A_KEYS = ("A2A_HOST", "A2A_PORT", "A2A_PEER_TOKENS", "A2A_ALLOW_ALL_USERS",
            "A2A_BEARER_TOKEN", "A2A_PUBLIC_URL")
TS = time.strftime("%Y%m%d-%H%M%S")
LOCAL = {"", "127.0.0.1", "localhost", "::1", "0.0.0.0"}

# The profile that legitimately serves A2A on this host, if the host's A2A
# identity lives in a profile rather than in the root config. Everything else
# is disabled. (Set per host; see --serve.)
SERVING: dict[str, str] = {}


def root_endpoint() -> str:
    host = ""
    for ln in (HH / ".env").read_text().splitlines():
        if ln.startswith("A2A_HOST="):
            host = ln.partition("=")[2].strip().strip('"')
    return host


def root_serves() -> bool:
    """True when the root config already enables the a2a platform itself."""
    try:
        doc = yaml.safe_load((HH / "config.yaml").read_text()) or {}
    except Exception:  # noqa: BLE001
        return False
    return bool((((doc.get("gateway") or {}).get("platforms") or {})
                 .get("a2a") or {}).get("enabled"))


def disable_platform_lines(raw: str) -> tuple[str, str]:
    """Return (new_text, action) with top-level platforms.a2a.enabled: false.

    Line-based on purpose: a yaml.safe_dump round-trip strips comments and
    reformats the whole file (learned the hard way — it cost 36 profile configs
    a rewrite for a one-key change).
    """
    lines = raw.splitlines()
    pl = next((i for i, l in enumerate(lines) if re.match(r"^platforms:\s*$", l)), None)
    if pl is None:
        block = ["platforms:", "  a2a:", "    enabled: false"]
        return "\n".join([*lines, *block]).rstrip() + "\n", "block added"
    # platforms: exists -> find its a2a child
    i, a2a = pl + 1, None
    while i < len(lines) and (lines[i].startswith("  ") or not lines[i].strip()):
        if re.match(r"^  a2a:\s*$", lines[i]):
            a2a = i
            break
        i += 1
    if a2a is None:
        return ("\n".join([*lines[:pl + 1], "  a2a:", "    enabled: false", *lines[pl + 1:]])
                .rstrip() + "\n", "a2a key added under platforms")
    j = a2a + 1
    while j < len(lines) and re.match(r"^    \S", lines[j]):
        if re.match(r"^    enabled:\s*(true|false)\s*$", lines[j]):
            if "false" in lines[j]:
                return raw, "already disabled"
            lines[j] = "    enabled: false"
            return "\n".join(lines).rstrip() + "\n", "enabled -> false"
        j += 1
    return ("\n".join([*lines[:a2a + 1], "    enabled: false", *lines[a2a + 1:]])
            .rstrip() + "\n", "enabled key added")


def disable_platform(cfg: pathlib.Path) -> str:
    if not cfg.exists():
        return "no-config"
    raw = cfg.read_text()
    new, action = disable_platform_lines(raw)
    if new == raw:
        return action
    try:
        doc = yaml.safe_load(new) or {}
        assert ((doc.get("platforms") or {}).get("a2a") or {}).get("enabled") is False
    except Exception as e:  # noqa: BLE001
        return f"REFUSED (would not parse / verify: {e})"
    shutil.copy2(cfg, cfg.with_name(cfg.name + f".bak-{TS}"))
    cfg.write_text(new)
    return action


def strip_env(env: pathlib.Path) -> tuple[int, str]:
    """Remove the A2A listener settings; leave everything else byte-identical."""
    raw = env.read_text()
    keep, dropped = [], []
    for ln in raw.splitlines():
        m = re.match(r"^(A2A_[A-Z_]+)=", ln)
        if m and m.group(1) in A2A_KEYS:
            dropped.append(m.group(1))
        else:
            keep.append(ln)
    if not dropped:
        return 0, "no A2A vars"
    new = "\n".join(keep).rstrip() + "\n"
    shutil.copy2(env, env.with_name(env.name + f".bak-{TS}"))
    env.write_text(new)
    env.chmod(0o600)
    return len(dropped), ",".join(dropped)


def main(argv: list[str]) -> int:
    apply = "--yes" in argv
    serve = ""
    if "--serve" in argv:
        serve = argv[argv.index("--serve") + 1]
    endpoint = root_endpoint()
    default_serves = root_serves()
    print(f"host A2A endpoint: {endpoint or '(unset)'}; "
          f"root config enables a2a: {default_serves}")
    if serve:
        print(f"profile exempted (serves A2A here): {serve}")
    print(f"rule: every OTHER profile gets platforms.a2a.enabled=false and its "
          f"A2A listener env removed")
    changed = 0
    for d in sorted(p for p in PROFILES.iterdir() if p.is_dir()):
        env, cfg = d / ".env", d / "config.yaml"
        if not env.exists() and not cfg.exists():
            continue
        a2a_host = ""
        if env.exists():
            for ln in env.read_text().splitlines():
                if ln.startswith("A2A_HOST="):
                    a2a_host = ln.partition("=")[2].strip().strip('"')
        if serve and d.name == serve:
            print(f"  {d.name:22} EXEMPT (serving)")
            continue
        has_env = any(re.match(r"^A2A_[A-Z_]+=", ln)
                      for ln in (env.read_text().splitlines() if env.exists() else []))
        already = False
        if cfg.exists():
            try:
                doc = yaml.safe_load(cfg.read_text()) or {}
                already = ((doc.get("platforms") or {}).get("a2a") or {}).get("enabled") is False
            except Exception:  # noqa: BLE001
                already = False
        if not has_env and already:
            continue                      # already clean, say nothing
        kind = ("FOREIGN" if a2a_host and a2a_host not in LOCAL and a2a_host != endpoint
                else "DUPLICATE" if a2a_host else "no-identity")
        if not apply:
            print(f"  {d.name:22} {kind:11} A2A_HOST={a2a_host or '(unset)':16} "
                  f"env={'yes' if has_env else 'no ':3} disabled={already}")
            continue
        kept = 0
        act = "skipped"
        if env.exists() and has_env:
            kept, which = strip_env(env)
            act = f"env -{kept}"
        cfg_act = disable_platform(cfg) if cfg.exists() else "no-config"
        print(f"  {d.name:22} {kind:11} A2A_HOST={a2a_host or '(unset)':16} "
              f"{act}, platform {cfg_act}")
        changed += 1
    print(f"\n{'CLEANUP-OK — ' + str(changed) + ' profiles cleaned' if apply else 'DRY RUN — nothing written (re-run with --yes)'}")
    if apply:
        print("now: systemctl --user restart hermes-gateway")
        print("verify: ss -ltnp | grep :9900  -> EXACTLY ONE listener, on the host IP;")
        print("        curl -s -o /dev/null -w '%{http_code}' -XPOST 127.0.0.1:9900/ -d '{}' -> 000/refused")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
