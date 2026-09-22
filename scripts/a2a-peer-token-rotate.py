#!/usr/bin/env python3
"""a2a-peer-token-rotate.py — rotate the Hermes A2A peer tokens THROUGH THE STORE.

Why this file exists: the A2A peer tokens are what makes an inbound message
carry an authenticated peer identity, and they were (a) hand-placed in
`~/.hermes/.env` with no store entry, so rule 5 of `SECRETS.md` ("a secret that
exists only hand-placed is not controlled") applied, and (b) surfaced in plain
text in session transcripts. Rotation has to be a procedure, not an intention.

This tool owns the whole procedure and is the ONLY writer of those values:

  * the token set lives in the encrypted store
    (`secrets/infra/hermes-a2a-peer-tokens.yaml`), which is the source of truth;
  * it renders BOTH delivery paths on BOTH live peers — the inbound allow-list
    (`~/.hermes/.env A2A_PEER_TOKENS`) and the outbound client token
    (`~/.hermes/config.yaml a2a_agents.<peer>.auth.token`);
  * it enforces the cross-host consistency the mesh depends on
    (nexus's outbound token to zephyr == zephyr's inbound entry for `nexus`;
    nexus's self entry == its own `a2a_agents.hermes-nexus` token — the path a
    money halt travels), and refuses to write an inconsistent set;
  * it rotates with OVERLAP, so the halt path never sees a 401 window:
    old+new accepted -> callers switched -> old dropped.

Never prints a value: fingerprints only. Failures stop the run in the last
state that was verified working (an overlap state is always safe).

Usage (run on zephyr — it holds the age identity and the store):
  a2a-peer-token-rotate.py plan            # what exists now (fingerprints)
  a2a-peer-token-rotate.py check           # store vs live host state, exit 0/1/2
  a2a-peer-token-rotate.py rotate --yes    # do the whole rotation, verified
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HOME = pathlib.Path.home()
STORE = HOME / "Work" / "Projects" / "nixos-secrets"
ROUTE = STORE / "secrets" / "infra" / "hermes-a2a-peer-tokens.yaml"
REPO = HOME / "Work" / "Projects" / "homelab-ops"
APPLIER = REPO / "scripts" / "a2a-token-apply.py"

# The two live peers (forge and sentry have no :9900 listener and no gateway
# running — verified; their entries are rotated as inert values only).
HOSTS = {
    "nexus": {"ip": "100.76.105.73", "outbound": ["hermes-nexus", "hermes-forge",
                                                 "hermes-sentry", "hermes-zephyr"]},
    "zephyr": {"ip": "100.91.11.2", "outbound": []},
}
TOKEN_LEN = 32          # hex chars -> a 32-byte token, matching the live set
HALT_HOST = "nexus"     # the host that pushes money-halt reports


def fp(v: str) -> str:
    return f"len={len(v):3} fp={hashlib.sha256(v.encode()).hexdigest()[:12]}"


def new_token() -> str:
    return secrets.token_hex(TOKEN_LEN)


def sh(args: list[str], stdin: str | None = None, check: bool = True,
       cwd: pathlib.Path | None = None) -> str:
    r = subprocess.run(args, input=stdin, capture_output=True, text=True,
                       cwd=str(cwd) if cwd else None)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} -> rc={r.returncode}: {r.stderr.strip()[:400]}")
    return r.stdout


# An interpreter that can actually `import yaml`, resolved per host. Bare
# `python3` is a mise shim on these hosts and does NOT carry PyYAML — the
# remote half of this tool must never assume it (the apply step writes to the
# money-halt path).
PY_CANDIDATES = [
    "/usr/bin/python3",
    "/home/j_kro/.hermes/hermes-agent/venv/bin/python",
    "/home/j_kro/.local/share/mise/installs/python/3.11.16/bin/python",
]
_PY_CACHE: dict[str, str] = {}


def remote_python(host: str, announce: bool = False) -> str:
    if host in _PY_CACHE:
        return _PY_CACHE[host]
    probe = ("for P in " + " ".join(PY_CANDIDATES) + " python3; do "
             "if command -v \"$P\" >/dev/null 2>&1 && \"$P\" -c 'import yaml' 2>/dev/null; "
             "then echo \"$P\"; break; fi; done")
    got = subprocess.run(["ssh", "-o", "ConnectTimeout=8", host, probe],
                         capture_output=True, text=True).stdout.strip()
    if not got:
        raise RuntimeError(f"no python with PyYAML on {host} — refusing to touch its files")
    _PY_CACHE[host] = got
    if announce:
        print(f"  {host}: interpreter {got}")
    return got


# --------------------------------------------------------------- host state

REMOTE_READ = r'''
import hashlib, json, pathlib, re, sys
home = pathlib.Path.home()
env, cfg = home/".hermes"/".env", home/".hermes"/"config.yaml"
peer_tokens = ""
for ln in (env.read_text().splitlines() if env.exists() else []):
    if ln.startswith("A2A_PEER_TOKENS="):
        peer_tokens = ln.partition("=")[2].strip().strip('"')
out = {}
raw = cfg.read_text() if cfg.exists() else ""
m = re.search(r"^a2a_agents:\n((?:.*\n)*?)(?=^\S)", raw, re.M)
if m:
    cur = None
    for line in m.group(1).splitlines():
        mm = re.match(r"^  ([A-Za-z0-9._-]+):\s*$", line)
        if mm:
            cur = mm.group(1); continue
        tm = re.match(r"^\s+token:\s*(\S+)", line)
        if tm and cur:
            out[cur] = tm.group(1).strip().strip('"\'')
print(json.dumps({"peer_tokens": peer_tokens, "outbound": out}))
'''


def read_host(host: str) -> dict:
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=8", host,
                        remote_python(host), "-"], input=REMOTE_READ,
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"ssh {host} state read failed: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout)


def split_peers(s: str) -> dict[str, str]:
    out = {}
    for pair in (s or "").split(","):
        if ":" in pair:
            n, _, t = pair.partition(":")
            out[n.strip()] = t.strip()
    return out


def join_peers(m: dict[str, str]) -> str:
    return ",".join(f"{k}:{v}" for k, v in m.items())


# ------------------------------------------------------------------- store

def store_write(doc: dict) -> None:
    """Encrypt into the store.

    sops resolves its creation rules from the nearest `.sops.yaml` **relative to
    the target file's path**, so a plaintext temp in /tmp matches no rule and
    sops refuses ("no creation rules"). `--filename-override` makes sops
    evaluate the rule against the INTENDED destination while the plaintext
    still lives outside the store tree — deliberately: the store is a git
    repo, and a plaintext scratch file inside it is one `git add -A` away from
    being committed.
    """
    ROUTE.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
        import yaml
        yaml.safe_dump(doc, fh, sort_keys=False)
        plain = fh.name
    try:
        out = sh(["sops", "--config", str(STORE / ".sops.yaml"),
                  "--encrypt", "--input-type", "yaml", "--output-type",
                  "yaml", "--filename-override", str(ROUTE), plain],
                 check=True, cwd=STORE)
        if "sops:" not in out and "ENC[AES256_GCM" not in out:
            raise RuntimeError("sops produced no ciphertext envelope — refusing to write")
        for value in (v for d in doc["hosts"].values()
                      for v in list(split_peers(d.get("peer_tokens", "")).values())
                      + list((d.get("outbound") or {}).values())):
            if value and value in out:
                raise RuntimeError("ciphertext contains a plaintext token — refusing to write")
        if ROUTE.exists():
            ROUTE.with_name(ROUTE.name + f".bak-{time.strftime('%Y%m%d-%H%M%S')}").write_text(
                ROUTE.read_text())
        ROUTE.write_text(out)
        ROUTE.chmod(0o600)
    finally:
        pathlib.Path(plain).unlink(missing_ok=True)


def store_read() -> dict:
    if not ROUTE.exists():
        return {}
    import yaml
    return yaml.safe_load(sh(["sops", "-d", "--output-type", "yaml", str(ROUTE)])) or {}


# ------------------------------------------------------------------ probes

def probe(host: str, token: str | None, label: str) -> int:
    """Unknown JSON-RPC method: 200 + -32601 = token accepted; 401 = rejected."""
    req = urllib.request.Request(
        f"http://{HOSTS[host]['ip']}:9900/",
        data=json.dumps({"jsonrpc": "2.0", "id": "probe",
                         "method": "a2a/probe-nonexistent", "params": {}}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = resp.read()[:200].decode(errors="replace")
            print(f"    [{label}] {host}: HTTP {resp.status} {body[:90]}")
            return resp.status
    except urllib.error.HTTPError as e:
        print(f"    [{label}] {host}: HTTP {e.code}")
        return e.code
    except Exception as e:  # noqa: BLE001
        print(f"    [{label}] {host}: ERROR {type(e).__name__}: {e}")
        return 0


def restart_and_wait(host: str) -> None:
    sh(["ssh", "-o", "ConnectTimeout=8", host,
        "systemctl --user restart hermes-gateway.service"], check=False)
    ip = HOSTS[host]["ip"]
    for _ in range(30):
        time.sleep(5)
        r = sh(["ssh", "-o", "ConnectTimeout=8", host,
                f"ss -ltnp 2>/dev/null | grep -c '{ip}:9900'"], check=False)
        if r.strip().startswith("1"):
            time.sleep(3)          # let the adapter finish wiring auth
            print(f"    {host}: gateway up, {ip}:9900 bound")
            return
    print(f"    WARNING: {host}: {ip}:9900 not bound after 150s — continuing to probes")


def apply(host: str, payload: dict) -> None:
    sh(["scp", "-q", str(APPLIER), f"{host}:/tmp/a2a-token-apply.py"])
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=8", host,
                        remote_python(host), "/tmp/a2a-token-apply.py"],
                       input=json.dumps(payload), capture_output=True, text=True)
    print(r.stdout.rstrip() or r.stderr.strip()[:300])
    if r.returncode != 0:
        raise RuntimeError(f"apply on {host} failed rc={r.returncode}")


def halt_e2e() -> tuple[bool, str]:
    """The money-halt push, end to end, through the rotated token."""
    out = sh(["ssh", "-o", "ConnectTimeout=8", HALT_HOST,
              f"cd {HOME}/Work/trading && {remote_python(HALT_HOST)} tools/halt_alerts.py --test"],
             check=False)
    ok = "ok=True" in out and "status=200" in out
    reply = ""
    for i, line in enumerate(out.splitlines()):
        if line.startswith("reply:"):
            reply = " ".join(out.splitlines()[i:i + 3])[:700]
    return ok, ("\n".join(l for l in out.splitlines() if "test send" in l) if ok
                else out.strip()[:500]) + (f"\n{reply}" if reply else "")


# -------------------------------------------------------------------- flow

def build_set(state: dict[str, dict], old_store: dict) -> dict:
    """New token set, cross-host constraints enforced by construction."""
    nexus_in = split_peers(state["nexus"]["peer_tokens"])
    zephyr_in = split_peers(state["zephyr"]["peer_tokens"])

    # one fresh token per (host, slot); the shared slots reuse the same value
    t_nexus_self = new_token()                     # nexus inbound['nexus'] == its hermes-nexus token
    t_nexus_to_zephyr = new_token()                # nexus outbound hermes-zephyr == zephyr inbound['nexus']
    nexus_in_new = {n: new_token() for n in nexus_in}
    nexus_in_new["nexus"] = t_nexus_self
    zephyr_in_new = {n: new_token() for n in zephyr_in}
    if "nexus" in zephyr_in_new:
        zephyr_in_new["nexus"] = t_nexus_to_zephyr

    nexus_out = {p: new_token() for p in HOSTS["nexus"]["outbound"]}
    nexus_out["hermes-nexus"] = t_nexus_self
    if "hermes-zephyr" in nexus_out:
        nexus_out["hermes-zephyr"] = t_nexus_to_zephyr
    # preserve the deployed pair convention (nexus inbound[<peer>] == outbound[hermes-<peer>])
    for peer in ("forge", "sentry"):
        if f"hermes-{peer}" in nexus_out and peer in nexus_in_new:
            nexus_out[f"hermes-{peer}"] = nexus_in_new[peer]

    doc = {"# rotated by": "scripts/a2a-peer-token-rotate.py",
           "hosts": {
               "nexus": {"peer_tokens": join_peers(nexus_in_new), "outbound": nexus_out},
               "zephyr": {"peer_tokens": join_peers(zephyr_in_new), "outbound": {}},
           }}
    assert doc["hosts"]["nexus"]["outbound"]["hermes-zephyr"] == \
        split_peers(doc["hosts"]["zephyr"]["peer_tokens"])["nexus"], "cross-host constraint"
    assert doc["hosts"]["nexus"]["outbound"]["hermes-nexus"] == \
        split_peers(doc["hosts"]["nexus"]["peer_tokens"])["nexus"], "self/halt constraint"
    return doc


def overlap(host: str, fresh: dict[str, str], old: dict[str, str]) -> str:
    """New tokens first, then the old ones under the same name.

    `_parse_peer_tokens` returns {token: name}, so two tokens may carry the same
    peer name and BOTH authenticate as it — that is what removes the 401 window.
    """
    parts = [f"{n}:{t}" for n, t in fresh.items()]
    parts += [f"{n}:{t}" for n, t in old.items() if t and t != fresh.get(n)]
    return ",".join(parts)


def cmd_smoke() -> int:
    """No-op apply on both hosts: proves interpreter + scp + stdin + no-op detect.

    Writes the value each host ALREADY has, so a correct applier reports
    "already in sync" and creates no backup file. Any failure here would have
    been failure #3 on the money-halt path.
    """
    print(f"  driver: {sys.executable}")
    for h in HOSTS:
        remote_python(h, announce=True)
        st = read_host(h)
        print(f"  {h}: read state OK ({len(split_peers(st['peer_tokens']))} inbound, "
              f"{len(st.get('outbound') or {})} outbound)")
        apply(h, {"peer_tokens": st["peer_tokens"]})
        r = sh(["ssh", "-o", "ConnectTimeout=8", h,
                "ls ~/.hermes/.env.bak-* ~/.hermes/config.yaml.bak-* 2>/dev/null | wc -l"])
        print(f"  {h}: backup files present = {r.strip()} (unchanged by a no-op)")
    print("SMOKE-OK")
    return 0


def cmd_plan() -> int:
    print("## live host state (fingerprints only)")
    for h in HOSTS:
        st = read_host(h)
        print(f"  {h}")
        for n, t in split_peers(st["peer_tokens"]).items():
            print(f"    inbound[{n:14}] {fp(t)}")
        for p, t in (st.get("outbound") or {}).items():
            print(f"    outbound.{p:20} {fp(t)}")
    print("## store")
    doc = store_read()
    if not doc:
        print(f"  {ROUTE}: ABSENT (tokens are hand-placed — the gap this tool closes)")
    else:
        for h, d in (doc.get("hosts") or {}).items():
            print(f"  {h}: {len(split_peers(d.get('peer_tokens','')))} inbound, "
                  f"{len(d.get('outbound') or {})} outbound")
    return 0


def cmd_check() -> int:
    doc = store_read()
    if not doc:
        print("check: store entry ABSENT (drift: cannot be the source of truth)")
        return 1
    drifted = 0
    for h, d in (doc.get("hosts") or {}).items():
        st = read_host(h)
        want_in, got_in = split_peers(d.get("peer_tokens", "")), split_peers(st["peer_tokens"])
        want_out = d.get("outbound") or {}
        got_out = st.get("outbound") or {}
        for n, t in want_in.items():
            ok = got_in.get(n) == t
            print(f"  {h}.inbound[{n:14}] {'in sync' if ok else 'DRIFTED'} "
                  f"store={fp(t)} host={fp(got_in.get(n,''))}")
            drifted += 0 if ok else 1
        for p, t in want_out.items():
            ok = got_out.get(p) == t
            print(f"  {h}.outbound.{p:18} {'in sync' if ok else 'DRIFTED'} "
                  f"store={fp(t)} host={fp(got_out.get(p,''))}")
            drifted += 0 if ok else 1
    print("check: IN SYNC" if not drifted else f"check: {drifted} DRIFTED")
    return 0 if not drifted else 1


def cmd_rotate(yes: bool) -> int:
    print(f"== 0. interpreters (explicit; bare python3 here is a mise shim with no PyYAML) ==")
    print(f"  driver: {sys.executable} (yaml {__import__('yaml').__version__})")
    for h in HOSTS:
        remote_python(h, announce=True)

    print("== 1. read live state ==")
    state = {h: read_host(h) for h in HOSTS}
    old = {h: split_peers(state[h]["peer_tokens"]) for h in HOSTS}
    for h in HOSTS:
        print(f"  {h}: {len(old[h])} inbound, {len(state[h].get('outbound') or {})} outbound")

    print("== 2. build the new set (constraints enforced) ==")
    doc = build_set(state, store_read())
    for h, d in doc["hosts"].items():
        for n, t in split_peers(d["peer_tokens"]).items():
            print(f"  NEW {h}.inbound[{n:14}] {fp(t)}")
        for p, t in d["outbound"].items():
            print(f"  NEW {h}.outbound.{p:18} {fp(t)}")
    if not yes:
        print("\nDRY RUN — nothing written. Re-run with --yes to apply.")
        return 0

    print("== 3. store is the source of truth first ==")
    store_write(doc)
    back = store_read()
    assert back["hosts"]["nexus"]["peer_tokens"] == doc["hosts"]["nexus"]["peer_tokens"], \
        "store round-trip mismatch"
    print(f"  wrote {ROUTE.relative_to(HOME)} (round-trip verified)")

    print("== 4. overlap: old + new accepted on both peers ==")
    for h in HOSTS:
        fresh = split_peers(doc["hosts"][h]["peer_tokens"])
        apply(h, {"peer_tokens": overlap(h, fresh, old[h])})
    for h in HOSTS:
        restart_and_wait(h)

    print("== 5. prove the overlap (both tokens live, junk rejected) ==")
    ok = True
    for h in HOSTS:
        fresh = split_peers(doc["hosts"][h]["peer_tokens"])
        self_name = h if h in fresh else next(iter(fresh))
        ok &= probe(h, fresh[self_name], "NEW") == 200
        if old[h]:
            old_name = next(iter(old[h]))
            old_code = probe(h, old[h][old_name], "OLD")
            ok &= old_code == 200
        ok &= probe(h, None, "no-auth") == 401
        ok &= probe(h, "f" * 2 * TOKEN_LEN, "unknown") == 401
    if not ok:
        print("STOP: overlap not proven — nothing further changed, both tokens still work.")
        return 1

    print("== 6. switch the outbound callers to the new tokens ==")
    for h in HOSTS:
        apply(h, {"outbound": doc["hosts"][h]["outbound"]})

    print("== 7. halt path end to end with the new token ==")
    good, detail = halt_e2e()
    print(detail or "  (no status line)")
    if not good:
        print("STOP: halt e2e failed — overlap is still in place, roll back with "
              "`rotate` history or restore the .bak files.")
        return 1
    print("  halt e2e: ok=True status=200")

    print("== 8. final: drop the old tokens, keep the new ==")
    for h in HOSTS:
        apply(h, {"peer_tokens": doc["hosts"][h]["peer_tokens"]})
    for h in HOSTS:
        restart_and_wait(h)

    print("== 9. final verification ==")
    ok2 = True
    for h in HOSTS:
        fresh = split_peers(doc["hosts"][h]["peer_tokens"])
        ok2 &= probe(h, fresh[h if h in fresh else next(iter(fresh))], "NEW") == 200
        if old[h]:
            ok2 &= probe(h, next(iter(old[h].values())), "OLD-revoked") == 401
        ok2 &= probe(h, None, "no-auth") == 401
        ok2 &= probe(h, "f" * 2 * TOKEN_LEN, "unknown") == 401
    good2, detail2 = halt_e2e()
    print(detail2 or "  (no status line)")
    ok2 &= good2
    print(f"\n{'ROTATION-OK — new tokens live, old revoked, halt path proven' if ok2 else 'ROTATION-FAILED — see above'}")
    return 0 if ok2 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["plan", "check", "smoke", "rotate"])
    ap.add_argument("--yes", action="store_true", help="required to write anything")
    a = ap.parse_args()
    return {"plan": cmd_plan, "check": cmd_check, "smoke": cmd_smoke,
            "rotate": lambda: cmd_rotate(a.yes)}[a.mode]()


if __name__ == "__main__":
    raise SystemExit(main())
