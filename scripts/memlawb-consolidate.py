#!/usr/bin/env python3
"""memlawb-consolidate — inventory and dedupe pass over the encrypted memory store.

Read-only by default. Writes a JSON + markdown report. The ONLY mutation it can
perform is `--apply-duplicates`, which deletes entries whose plaintext body is an
exact duplicate of a kept entry. Near-duplicates are reported, never deleted: a
merge is a judgement call and this tool does not make it.

Usage:
  memlawb-consolidate.py                 # report to stdout
  memlawb-consolidate.py --json          # machine-readable summary
  memlawb-consolidate.py --apply-duplicates   # delete exact duplicates, then report
  memlawb-consolidate.py --threshold 0.90 --report-dir /path

Env:
  MEMLAWB_URL        default http://127.0.0.1:8080
  MEMLAWB_NAMESPACE  default user:j_kro
  MEMLAWB_PASSPHRASE or ~/.memlawb-passphrase.txt

Exit codes: 0 ok, 1 error, 2 nothing decrypted (wrong key / unreachable).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import importlib.util

# Load client.py by path: the package __init__ imports Hermes internals
# (agent.memory_provider), which are absent when this runs as a plain cron
# script under system python. client.py itself is stdlib + cryptography only.
CLIENT_PATH = Path.home() / "Work/Projects/memlawb-for-hermes/memlawb_provider/client.py"


def _load_client_module(path: Path):
    spec = importlib.util.spec_from_file_location("memlawb_client", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_client_mod = _load_client_module(CLIENT_PATH)
MemlawbClient = _client_mod.MemlawbClient
MemlawbError = _client_mod.MemlawbError
decrypt_entry = _client_mod.decrypt_entry

if not getattr(_client_mod, "_HAS_CRYPTO", False):
    raise SystemExit(
        "ERROR: this python has no 'cryptography' package, so nothing can be "
        "decrypted. Run under the Hermes runtime python, e.g. "
        "~/.hermes/tools/python-*/bin/python3"
    )

WORD = re.compile(r"[a-z0-9][a-z0-9_.:/-]+")
SHINGLE = 5


def shingles(text: str) -> set[str]:
    words = WORD.findall(text.lower())
    if len(words) < SHINGLE:
        return {hashlib.sha1(" ".join(words).encode()).hexdigest()} if words else set()
    return {
        hashlib.sha1(" ".join(words[i:i + SHINGLE]).encode()).hexdigest()
        for i in range(len(words) - SHINGLE + 1)
    }


def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def body(content: str) -> str:
    """Strip the leading markdown title so near-identical files compare on substance."""
    lines = [ln for ln in content.strip().splitlines() if not ln.startswith("# ")]
    return "\n".join(lines).strip()


def norm(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower()).strip()


def load_entries(client: MemlawbClient) -> tuple[dict[str, str], list[str]]:
    raw = client.get_namespace()
    good: dict[str, str] = {}
    bad: list[str] = []
    for key, blob in raw.items():
        try:
            good[key] = client_descriptor(client, key, blob)
        except Exception:
            bad.append(key)
    return good, bad


def client_descriptor(client, key, blob):
    """Decrypt one entry through the provider's own crypto path."""
    return decrypt_entry(client._get_key(), key, blob)


def build_report(entries: dict[str, str], undecryptable: list[str], threshold: float) -> dict:
    keys = sorted(entries)
    bodies = {k: norm(body(entries[k])) for k in keys}
    hashes = {k: hashlib.sha256(bodies[k].encode()).hexdigest() for k in keys}

    # exact duplicates: same normalized body, different keys
    by_hash: dict[str, list[str]] = {}
    for k, h in hashes.items():
        by_hash.setdefault(h, []).append(k)
    exact = [sorted(v) for v in by_hash.values() if len(v) > 1]

    # near duplicates within the same top-level prefix (cheap blocking)
    sh = {k: shingles(bodies[k]) for k in keys}
    near = []
    seen = set()
    for i, a in enumerate(keys):
        pa = a.split("/")[0]
        for b in keys[i + 1:]:
            if b.split("/")[0] != pa:
                continue
            if hashes[a] == hashes[b]:
                continue
            pair = (a, b)
            if pair in seen:
                continue
            seen.add(pair)
            score = jaccard(sh[a], sh[b])
            if score >= threshold:
                near.append({"a": a, "b": b, "score": round(score, 3)})
    near.sort(key=lambda r: -r["score"])

    prefixes: dict[str, int] = {}
    for k in keys:
        top = k.split("/")[0] if "/" in k else "(root)"
        prefixes[top] = prefixes.get(top, 0) + 1

    # Layout drift: entries written before the key convention (user/*, project/*, ...)
    # landed at the namespace root. Reported, never renamed automatically.
    root_keys = [k for k in keys if "/" not in k]

    sizes = sorted(((len(entries[k]), k) for k in keys), reverse=True)

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "entries": len(keys),
        "undecryptable": len(undecryptable),
        "total_chars": sum(len(v) for v in entries.values()),
        "prefixes": dict(sorted(prefixes.items(), key=lambda x: -x[1])),
        "layout_drift_root_keys": len(root_keys),
        "layout_drift_sample": root_keys[:10],
        "exact_duplicate_groups": exact,
        "exact_duplicate_wasted_chars": sum(
            sum(len(entries[k]) for k in grp[1:]) for grp in exact
        ),
        "near_duplicates": near[:50],
        "near_duplicate_count": len(near),
        "threshold": threshold,
        "largest": [{"key": k, "chars": n} for n, k in sizes[:10]],
        "empty": [k for k in keys if not bodies[k]],
    }


def apply_duplicates(client: MemlawbClient, groups: list[list[str]], entries: dict[str, str]) -> list[str]:
    """Keep one entry per exact-duplicate group (longest, then first key). Delete the rest."""
    deleted = []
    for grp in groups:
        if len(grp) < 2:
            continue
        keep = sorted(grp, key=lambda k: (-len(entries[k]), k))[0]
        for k in grp:
            if k == keep:
                continue
            try:
                client.delete(k)
                deleted.append(k)
            except (MemlawbError, OSError) as exc:
                print(f"WARN delete failed {k}: {exc}", file=sys.stderr)
    return deleted


def render_md(rep: dict, deleted: list[str]) -> str:
    out = [
        "# memlawb consolidation report",
        "",
        f"- generated: {rep['generated_at']}",
        f"- entries: {rep['entries']} ({rep['total_chars']} chars plaintext)",
        f"- undecryptable: {rep['undecryptable']}",
        f"- exact duplicate groups: {len(rep['exact_duplicate_groups'])} "
        f"({rep['exact_duplicate_wasted_chars']} redundant chars)",
        f"- near duplicates at Jaccard >= {rep['threshold']}: {rep['near_duplicate_count']}",
        f"- layout drift: {rep['layout_drift_root_keys']} entries at the namespace root (no prefix)",
        "",
        "## Prefixes",
        "",
    ]
    for p, n in rep["prefixes"].items():
        out.append(f"- {p}: {n}")
    if rep["exact_duplicate_groups"]:
        out += ["", "## Exact duplicates", ""]
        for grp in rep["exact_duplicate_groups"]:
            out.append(f"- {', '.join(grp)}")
    if rep["near_duplicates"]:
        out += ["", "## Near duplicates (merge candidates — review by hand)", ""]
        for r in rep["near_duplicates"]:
            out.append(f"- {r['score']}: {r['a']}  <->  {r['b']}")
    if rep["largest"]:
        out += ["", "## Largest entries", ""]
        for e in rep["largest"]:
            out.append(f"- {e['chars']:>7}  {e['key']}")
    if rep["empty"]:
        out += ["", "## Empty bodies", ""] + [f"- {k}" for k in rep["empty"]]
    if deleted:
        out += ["", "## Deleted this run", ""] + [f"- {k}" for k in deleted]
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--threshold", type=float, default=0.86)
    ap.add_argument("--apply-duplicates", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--report-dir", default=str(Path.home() / ".hermes/memlawb-consolidate"))
    ap.add_argument("--no-report-file", action="store_true")
    args = ap.parse_args()

    url = os.environ.get("MEMLAWB_URL", "http://127.0.0.1:8080")
    ns = os.environ.get("MEMLAWB_NAMESPACE", "user:j_kro")
    client = MemlawbClient.from_config({"url": url, "namespace": ns})

    try:
        if not client.is_alive():
            print(f"ERROR: memlawb unreachable at {url}", file=sys.stderr)
            return 2
        entries, undecryptable = load_entries(client)
    except (MemlawbError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if not entries:
        print(f"ERROR: decrypted 0 of the namespace {ns} - wrong passphrase?", file=sys.stderr)
        return 2

    rep = build_report(entries, undecryptable, args.threshold)
    deleted: list[str] = []
    if args.apply_duplicates and rep["exact_duplicate_groups"]:
        deleted = apply_duplicates(client, rep["exact_duplicate_groups"], entries)
        entries, undecryptable = load_entries(client)
        rep = build_report(entries, undecryptable, args.threshold)
        rep["deleted"] = deleted

    if args.json:
        print(json.dumps(rep, indent=2))
    else:
        print(render_md(rep, deleted), end="")

    if not args.no_report_file:
        d = Path(args.report_dir)
        d.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        (d / f"report-{stamp}.json").write_text(json.dumps(rep, indent=2) + "\n")
        (d / "latest.json").write_text(json.dumps(rep, indent=2) + "\n")
        (d / "latest.md").write_text(render_md(rep, deleted))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
