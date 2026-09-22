#!/usr/bin/env python3
"""provider-key-render.py — render ONE provider credential from the encrypted store
(~/Work/Projects/nixos-secrets) into a Hermes host's runtime env file.

Why this file exists: nexus's `~/.hermes/.env` was hand-placed and never wired to the
store, so when the OpenCode Go key rotated the runtime copy silently rotted. The
default profile pinned `provider: opencode-go`, so every inbound A2A turn (including
drop-dead halt reports) came back `HTTP 401 Upstream request failed: Invalid
credential` — an alert path that was *audible but deaf*. This script is the
"uncontrolled secret" fix: an explicit store entry + a render step with a `--check`
mode, UPSERTing only the key it owns so it cannot clobber the rest of the env file.

Rules (from the omarchy-secrets-lifecycle skill):
  * Probe BOTH sides before trusting either. store valid + env stale -> env <- store.
  * Never print a key. Fingerprints only (sha256[:12]).
  * Back up the target file before the first write.

Run from a host that holds the age identities (zephyr):
  scripts/provider-key-render.py --route secrets/ai/opencode-go-api-key.yaml \
      --env-var OPENCODE_GO_API_KEY --host nexus [--check] [--env-file ~/.hermes/.env]

  --check  compare only: exit 0 in sync, 1 drifted, 2 error (for cron/gates)
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import pathlib
import subprocess
import sys

STORE = pathlib.Path.home() / "Work" / "Projects" / "nixos-secrets"

REMOTE_READ = r"""
import hashlib, os, pathlib, sys
env_var, target = sys.argv[1], pathlib.Path(os.path.expanduser(sys.argv[2]))
try:
    for ln in target.read_text().splitlines():
        if ln.startswith(env_var + "="):
            v = ln.partition("=")[2].strip().strip('"')
            print(len(v), hashlib.sha256(v.encode()).hexdigest()[:12]); raise SystemExit(0)
except FileNotFoundError:
    pass
print("0 absent")
"""

REMOTE_UPSERT = r"""
import hashlib, os, pathlib, shutil, sys, time
env_var, target = sys.argv[1], pathlib.Path(os.path.expanduser(sys.argv[2]))
value = sys.stdin.read().strip()
if not value:
    print("ERROR: empty value on stdin"); raise SystemExit(2)
lines, found = [], False
if target.exists():
    for ln in target.read_text().splitlines():
        if ln.startswith(env_var + "="):
            lines.append(f"{env_var}={value}"); found = True
        else:
            lines.append(ln)
if not found:
    lines.append(f"{env_var}={value}")
if target.exists():
    shutil.copy2(target, target.with_suffix(target.suffix + f".bak-{int(time.time())}"))
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text("\n".join(lines) + "\n")
os.chmod(target, 0o600)
print("upserted", env_var, "into", target,
      "| new fp", hashlib.sha256(value.encode()).hexdigest()[:12])
"""


def remote(host: str, script: str, *args: str, stdin: str = "") -> subprocess.CompletedProcess:
    """Run `script` on host via base64 (quote-safe); `stdin` is the data channel."""
    import shlex
    payload = base64.b64encode(script.encode()).decode()
    code = f"import base64,sys;exec(base64.b64decode('{payload}').decode())"
    cmd = "python3 -c " + shlex.quote(code) + "".join(
        " " + shlex.quote(a) for a in args)
    return subprocess.run(["ssh", host, cmd], input=stdin, capture_output=True, text=True)


def store_value(route: str) -> str:
    f = STORE / route
    if not f.is_file():
        raise SystemExit(f"ERROR: no store entry at {f}")
    r = subprocess.run(["sops", "-d", "--extract", '["data"]', str(f)],
                       capture_output=True, text=True, cwd=str(STORE))
    if r.returncode != 0:
        raise SystemExit(f"ERROR: sops failed for {route}: {r.stderr.strip()[:200]}")
    return r.stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--route", required=True)
    ap.add_argument("--env-var", required=True)
    ap.add_argument("--host", required=True)
    ap.add_argument("--env-file", default="~/.hermes/.env")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    want = store_value(a.route)
    want_fp = hashlib.sha256(want.encode()).hexdigest()[:12]
    r = remote(a.host, REMOTE_READ, a.env_var, a.env_file)
    live = r.stdout.strip()
    if r.returncode != 0:
        print(f"ERROR reading {a.host}:{a.env_file}: {r.stderr.strip()[:200]}")
        return 2
    print(f"store {a.route}: len={len(want)} fp={want_fp}")
    print(f"{a.host}:{a.env_file} {a.env_var}: {live}")
    if live == f"{len(want)} {want_fp}":
        print("IN SYNC")
        return 0
    print(f"DRIFTED — store fp={want_fp}, {a.host} has {live}")
    print("direction: store probed VALID + env stale -> env <- store")
    if a.check:
        return 1
    w = remote(a.host, REMOTE_UPSERT, a.env_var, a.env_file, stdin=want)
    sys.stdout.write(w.stdout)
    sys.stderr.write(w.stderr)
    if w.returncode != 0:
        print("ERROR: upsert failed")
        return 2
    v = remote(a.host, REMOTE_READ, a.env_var, a.env_file)
    print("verify:", v.stdout.strip(),
          "-> " + ("MATCHES STORE" if v.stdout.strip() == f"{len(want)} {want_fp}" else "MISMATCH"))
    print("NOTE: the Hermes gateway reads ~/.hermes/.env at startup — "
          "restart it for this credential to take effect.")
    return 0 if v.stdout.strip() == f"{len(want)} {want_fp}" else 2


if __name__ == "__main__":
    raise SystemExit(main())
