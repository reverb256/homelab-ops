#!/usr/bin/env python3
"""a2a-token-apply.py — apply an A2A token set to THIS host's Hermes files.

Reads a JSON payload on STDIN (never argv, never the environment, so a token
never shows up in `ps`, the shell history, or a transcript):

  {"peer_tokens": "zephyr:tok,nexus:tok,zephyr:tok2",   # allows OLD+NEW overlap
   "outbound":    {"hermes-nexus": "tok", "hermes-zephyr": "tok"}}

  peer_tokens -> ~/.hermes/.env          A2A_PEER_TOKENS   (inbound allow-list)
  outbound    -> ~/.hermes/config.yaml   a2a_agents.<peer>.auth.token

Writes are UPSERT-only, backed up, mode-preserving and YAML-validated. Prints
fingerprints only — never a value. Exit 0 = applied, 2 = refused.

Why the inbound list is the thing to overlap: the listener is
`A2ASecurityContext.capture()` at adapter start, and `_parse_peer_tokens`
returns {token: name} — so TWO tokens may carry the same peer name and both
authenticate as it. That makes a rotation possible with no 401 window: add the
new token beside the old, restart, switch the callers, drop the old.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import re
import shutil
import sys
import time

import yaml

HOME = pathlib.Path.home()
ENV = HOME / ".hermes" / ".env"
CFG = HOME / ".hermes" / "config.yaml"
TS = time.strftime("%Y%m%d-%H%M%S")


def fp(v: str) -> str:
    return f"len={len(v)} fp={hashlib.sha256(v.encode()).hexdigest()[:12]}"


def upsert_env(path: pathlib.Path, key: str, value: str) -> bool:
    """Replace the key's line, or append it. Preserves mode. Returns changed."""
    lines = path.read_text().splitlines() if path.exists() else []
    mode = path.stat().st_mode & 0o7777 if path.exists() else 0o600
    out, found = [], False
    for ln in lines:
        if ln.startswith(key + "="):
            out.append(f"{key}={value}")
            found = True
        else:
            out.append(ln)
    if not found:
        out.append(f"{key}={value}")
    new = "\n".join(out) + "\n"
    old = ("\n".join(lines) + "\n") if lines else ""
    if new == old:
        return False
    shutil.copy2(path, path.with_name(path.name + f".bak-{TS}"))
    path.write_text(new)
    path.chmod(mode)
    return True


def set_peer_token(path: pathlib.Path, peer: str, token: str) -> bool:
    """Set a2a_agents.<peer>.auth.token in config.yaml (YAML-validated)."""
    raw = path.read_text()
    m = re.search(rf"^  {re.escape(peer)}:\n((?:    .*\n)+)", raw, re.M)
    if not m:
        print(f"  ERROR: a2a_agents.{peer} not found — refusing")
        raise SystemExit(2)
    block = m.group(1)
    if not re.search(r"^      token: ", block, re.M):
        print(f"  ERROR: a2a_agents.{peer} has no auth.token line — refusing")
        raise SystemExit(2)
    new_block = re.sub(r"^      token: \S+$", f"      token: {token}",
                       block, count=1, flags=re.M)
    if new_block == block:
        return False
    new_raw = raw[:m.start(1)] + new_block + raw[m.end(1):]
    try:                       # never leave config.yaml unparseable
        yaml.safe_load(new_raw)
    except Exception as e:  # noqa: BLE001
        print(f"  ERROR: refusing to write unparseable config.yaml: {e}")
        raise SystemExit(2)
    shutil.copy2(path, path.with_name(path.name + f".bak-{TS}"))
    path.write_text(new_raw)
    return True


def main() -> int:
    payload = json.loads(sys.stdin.read() or "{}")
    peer_tokens = str(payload.get("peer_tokens") or "")
    outbound = payload.get("outbound") or {}

    if peer_tokens:
        entries = [p for p in peer_tokens.split(",") if ":" in p]
        print(f"  .env A2A_PEER_TOKENS: {len(entries)} entries")
        for e in entries:
            n, _, t = e.partition(":")
            print(f"    {n.strip():16} {fp(t.strip())}")
        changed = upsert_env(ENV, "A2A_PEER_TOKENS", peer_tokens)
        print(f"  .env write: {'changed' if changed else 'already in sync'}")

    for peer, token in outbound.items():
        if not token:
            continue
        changed = set_peer_token(CFG, peer, token)
        print(f"  config a2a_agents.{peer}: {fp(token)} "
              f"({'changed' if changed else 'already in sync'})")

    print("APPLY-OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
