#!/usr/bin/env python3
"""Sync lan-pages/pages/* into the media-k8s media-rp-config ConfigMap.

The pages in this directory are the SOURCE OF TRUTH for the static pages the
homelab edge (nginx-rp, VIP 10.1.1.100:443) serves on *.lan names. Deployment
stays declarative: this script rewrites the page keys of

    media-k8s/cluster/addons/media-reverse-proxy/configmap-media-rp-config.yaml

so the normal flow applies:

    edit pages/<name>.html  ->  ./sync.py  ->  commit media-k8s  ->  ArgoCD

Usage:
    ./sync.py           # write changes into the ConfigMap source
    ./sync.py --check   # exit 1 (and name files) if the source is out of sync
"""
import argparse
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
PAGES = HERE / "pages"
CM = (pathlib.Path.home()
      / "Work/Projects/media-k8s/cluster/addons/media-reverse-proxy/configmap-media-rp-config.yaml")

# page file -> ConfigMap data key (what the nginx config actually serves)
PAGE_TO_KEY = {
    "index.html": "index.html",    # media.lan portal (default vhost)
    "mining.html": "mining.html",  # mining.lan fleet page
    # trading.html is NOT in the CM: trading.lan proxies to the dash on
    # nexus:9798; the file here is the reference copy of that page.
}


def read_block(text: str, key: str):
    """Return the literal-block body of `key` (4-space indent stripped)."""
    m = re.search(rf"^  {re.escape(key)}: \|\n((?:[ \t]*.*\n)*?)(?=^  [A-Za-z0-9._-]+: \||\Z)",
                  text, re.M)
    if not m:
        return None
    out = []
    for line in m.group(1).split("\n"):
        if line.startswith("    "):
            out.append(line[4:])
        elif line.strip() == "":
            out.append("")
        else:
            raise SystemExit(f"unexpected indentation in {key} block: {line!r}")
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out) + "\n"


def block_for(page_text: str) -> str:
    return "".join(("    " + l if l.strip() else "") + "\n"
                   for l in page_text.rstrip("\n").split("\n"))


def block_bounds(text: str, key: str):
    marker = f"  {key}: |\n"
    start = text.index(marker) + len(marker)
    m = re.search(r"^  [A-Za-z0-9._-]+: \|", text[start:], re.M)
    end = start + (m.start() if m else len(text) - start)
    return start, end


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="verify sync, write nothing")
    args = ap.parse_args()

    if not CM.exists():
        print(f"ConfigMap source not found: {CM}", file=sys.stderr)
        return 2

    text = CM.read_text()
    changed = []
    for page_name, key in PAGE_TO_KEY.items():
        page_path = PAGES / page_name
        if not page_path.exists():
            print(f"missing page: {page_path}", file=sys.stderr)
            return 2
        want = page_path.read_text()
        got = read_block(text, key)
        if got is None:
            print(f"ConfigMap has no '{key}' block", file=sys.stderr)
            return 2
        if got == want:
            continue
        changed.append(page_name)
        if not args.check:
            start, end = block_bounds(text, key)
            text = text[:start] + block_for(want) + text[end:]

    if args.check:
        if changed:
            print("OUT OF SYNC: " + ", ".join(changed))
            return 1
        print("in sync: " + ", ".join(PAGE_TO_KEY))
        return 0

    if changed:
        CM.write_text(text)
        print("updated: " + ", ".join(changed))
        print(f"next: commit {CM.relative_to(pathlib.Path.home())} (media-k8s) and push")
    else:
        print("already in sync: " + ", ".join(PAGE_TO_KEY))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
