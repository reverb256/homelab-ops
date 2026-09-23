#!/usr/bin/env python3
"""
reclaim-leftovers.py - proof-ranked leftover manifest for the media downloads dir.

DRY-RUN BY DEFAULT. Nothing is deleted unless `--apply --i-mean-it` is passed.

An item under --root qualifies as a *leftover* only when ALL of these hold:

  P1 device    every path in the item (and the item itself) lives on the SAME
               block device as --root. This is the -x / --one-file-system
               guarantee, enforced per-path with os.lstat().st_dev so a network
               mount nested inside the pool (nfs4 / cifs autofs mounts under
               /data/media) can never be walked or deleted.
  P2 nlink     every regular file in the item has st_nlink == 1. A hardlinked
               file is still referenced by the *arr library, so it is NOT a
               leftover. (This is what makes the Akira case visible: the
               library remux and the release payload are separate files, both
               nlink=1.)
  P3 library   no file in the item is the same inode as a library file, and no
               library path (sonarr EpisodeFiles, radarr MovieFiles, jellyfin
               BaseItems) sits inside the item.
  P4 client    no qBittorrent torrent's content path sits inside the item.

Proof sources are fail-closed: if a source cannot be read the item is marked
UNPROVEN and is NOT eligible for reclaim. Every source is recorded in the
manifest so a reviewer can see what was actually checked.

Usage
-----
  reclaim-leftovers.py --root /data/media/downloads [--json OUT] [--top N]
  reclaim-leftovers.py --root ... --apply --i-mean-it

qBittorrent credentials come from the environment (never printed):
  QBT_URL (default http://qbittorrent:8082), QBT_USER, QBT_PASS
If they are absent the client proof is UNAVAILABLE and nothing is eligible.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import sqlite3
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ARR_CONFIG = Path(os.environ.get("ARR_CONFIG_PATH", "/data/media/config"))
JELLYFIN_DB = Path(
    os.environ.get(
        "JELLYFIN_DB", "/data/media/config/jellyfin/data/data/jellyfin.db"
    )
)
SONARR_DB = ARR_CONFIG / "sonarr" / "sonarr.db"
RADARR_DB = ARR_CONFIG / "radarr" / "radarr.db"

WALK_TIMEOUT_S = int(os.environ.get("RECLAIM_WALK_TIMEOUT", "600"))


class Timeout(Exception):
    pass


def _alarm(_sig, _frm):
    raise Timeout()


def walk_item(item: Path, root_dev: int):
    """Walk an item without following symlinks, refusing to cross devices."""
    files = []
    dirs = []
    total = 0
    crossed = False
    err = None
    signal.signal(signal.SIGALRM, _alarm)
    signal.alarm(WALK_TIMEOUT_S)
    try:
        st = os.lstat(item)
        if st.st_dev != root_dev:
            return files, dirs, 0, True, None
        if os.path.isdir(item) and not os.path.islink(item):
            dirs.append(item)
            for dirpath, _dirnames, filenames in os.walk(item, followlinks=False):
                dp = Path(dirpath)
                if dp != item:
                    dirs.append(dp)
                for name in filenames:
                    p = dp / name
                    try:
                        pst = os.lstat(p)
                    except OSError as e:
                        err = "lstat %s: %s" % (p, e)
                        continue
                    if pst.st_dev != root_dev:
                        crossed = True
                        continue
                    files.append(p)
                    total += pst.st_size
        else:
            files.append(item)
            total += st.st_size
    except Timeout:
        err = "walk timed out after %ss" % WALK_TIMEOUT_S
    except OSError as e:
        err = "walk error: %s" % e
    finally:
        signal.alarm(0)
    return files, dirs, total, crossed, err


def _ro(db: Path):
    if not db.exists():
        return None
    try:
        c = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=15)
        c.execute("select 1")
        return c
    except sqlite3.Error:
        return None


def library_paths():
    """Collect every library file path plus its (dev, ino) where readable."""
    paths = set()
    inodes = set()
    sources = {}

    c = _ro(SONARR_DB)
    if c:
        try:
            root = c.execute("select Path from RootFolders order by Id limit 1").fetchone()
            root = root[0].rstrip("/") if root and root[0] else ""
            n = len(paths)
            for (rel, orig) in c.execute("select RelativePath, OriginalFilePath from EpisodeFiles"):
                if rel:
                    paths.add(os.path.normpath(root + "/" + rel))
                if orig:
                    paths.add(os.path.normpath(orig))
            sources["sonarr"] = "ok (+%d paths)" % (len(paths) - n)
        except sqlite3.Error as e:
            sources["sonarr"] = "error: %s" % e
        finally:
            c.close()
    else:
        sources["sonarr"] = "unreadable: %s" % SONARR_DB

    c = _ro(RADARR_DB)
    if c:
        try:
            root = c.execute("select Path from RootFolders order by Id limit 1").fetchone()
            root = root[0].rstrip("/") if root and root[0] else ""
            n = len(paths)
            for (rel, orig) in c.execute("select RelativePath, OriginalFilePath from MovieFiles"):
                if rel:
                    paths.add(os.path.normpath(root + "/" + rel))
                if orig:
                    paths.add(os.path.normpath(orig))
            sources["radarr"] = "ok (+%d paths)" % (len(paths) - n)
        except sqlite3.Error as e:
            sources["radarr"] = "error: %s" % e
        finally:
            c.close()
    else:
        sources["radarr"] = "unreadable: %s" % RADARR_DB

    c = _ro(JELLYFIN_DB)
    if c:
        try:
            n = len(paths)
            for (p,) in c.execute("select Path from BaseItems where Path is not null and Path <> ''"):
                paths.add(os.path.normpath(p))
            sources["jellyfin"] = "ok (+%d paths)" % (len(paths) - n)
        except sqlite3.Error as e:
            sources["jellyfin"] = "error: %s" % e
        finally:
            c.close()
    else:
        sources["jellyfin"] = "unreadable: %s" % JELLYFIN_DB

    for p in paths:
        try:
            st = os.lstat(p)
            inodes.add((st.st_dev, st.st_ino))
        except OSError:
            pass
    return paths, inodes, sources


class Qbt:
    def __init__(self):
        self.url = os.environ.get("QBT_URL", "http://qbittorrent:8082").rstrip("/")
        self.user = os.environ.get("QBT_USER", "")
        self.pw = os.environ.get("QBT_PASS", "")
        self.cookie = ""
        self.status = "unavailable (no credentials in env)"
        self.content = []

    def login(self):
        if not self.user:
            return False
        try:
            data = urllib.parse.urlencode({"username": self.user, "password": self.pw}).encode()
            req = urllib.request.Request(
                self.url + "/api/v2/auth/login", data=data, headers={"Referer": self.url}
            )
            with urllib.request.urlopen(req, timeout=15) as r:
                body = r.read().decode()
                code = r.status
                self.cookie = r.headers.get("Set-Cookie", "").split(";")[0]
            # qBittorrent 5.x answers 200/204 with an EMPTY body on success (older
            # builds return "Ok."), so a body-content check rejects a valid
            # credential. HTTP status is the signal; "Fails" is the failure body.
            if code not in (200, 204) or "Fails" in body:
                self.status = "login rejected (http %s)" % code
                return False
            return True
        except Exception as e:
            self.status = "login error: %s" % type(e).__name__
            return False

    def load(self):
        if not self.login():
            return
        try:
            req = urllib.request.Request(
                self.url + "/api/v2/torrents/info",
                headers={"Cookie": self.cookie, "Referer": self.url},
            )
            with urllib.request.urlopen(req, timeout=30) as r:
                torrents = json.loads(r.read())
        except Exception as e:
            self.status = "info error: %s" % type(e).__name__
            return
        for t in torrents:
            paths = []
            for key in ("content_path", "save_path"):
                v = t.get(key)
                if v:
                    paths.append(host_path(v))
            self.content.append(
                {
                    "name": t.get("name"),
                    "state": t.get("state"),
                    "hash": t.get("hash"),
                    "paths": paths,
                }
            )
        self.status = "ok (%d torrents; %d complete, %d error/metaDL states)" % (
            len(torrents),
            sum(1 for t in torrents if t.get("progress") == 1),
            sum(
                1
                for t in torrents
                if t.get("state") in ("error", "missingFiles", "metaDL")
            ),
        )

    def delete(self, hashes, delete_files=True):
        """Delete torrents through the API. delete_files=True is the only mode
        this tool uses: removing the registry entry while leaving the payload on
        disk would create exactly the false state it exists to prevent."""
        if not self.cookie:
            return False, "not authenticated"
        try:
            data = urllib.parse.urlencode(
                {"hashes": "|".join(hashes), "deleteFiles": "true" if delete_files else "false"}
            ).encode()
            req = urllib.request.Request(
                self.url + "/api/v2/torrents/delete",
                data=data,
                headers={"Cookie": self.cookie, "Referer": self.url},
            )
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status in (200, 204), "http %s" % r.status
        except Exception as e:
            return False, "%s: %s" % (type(e).__name__, e)

    def match(self, item):
        """Torrents that actually own the bytes at `item`.

        A torrent matches only when its host-mapped content path IS the item.
        A bare name match is reported but never used for deletion: the client's
        content lives wherever save_path says (here /krash2/downloads), and
        deleteFiles on a name match would destroy a different pool's data while
        leaving the local item in place.
        """
        owned, name_only = [], []
        for t in self.content:
            for c in t["paths"]:
                if os.path.normpath(c) == os.path.normpath(str(item)):
                    owned.append(t)
                    break
                if under(c, str(item)) or under(str(item), c):
                    owned.append(t)
                    break
            else:
                nm = t.get("name") or ""
                if nm and nm == os.path.basename(str(item)):
                    name_only.append(t)
        return owned, name_only


# qBittorrent reports container paths. Map them back to host paths, else a
# torrent's content never matches an item on the pool.
QBT_PATH_MAP = [
    (a, b)
    for a, b in (
        pair.split("=", 1)
        for pair in os.environ.get(
            "QBT_PATH_MAP",
            "/downloads=/data/media/downloads,/krash2=/data/media/krash2-media",
        ).split(",")
        if "=" in pair
    )
]


def host_path(p):
    p = os.path.normpath(p)
    for src, dst in QBT_PATH_MAP:
        src = os.path.normpath(src).rstrip("/")
        if p == src or p.startswith(src + "/"):
            return os.path.join(dst, p[len(src):].lstrip("/"))
    return p


def under(child, parent):
    child = os.path.normpath(child)
    parent = os.path.normpath(parent).rstrip("/")
    return child == parent or child.startswith(parent + "/")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--json", default=None)
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--i-mean-it", action="store_true")
    ap.add_argument("--apply-report", default=None)
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        print("FATAL: %s is not a directory" % root, file=sys.stderr)
        return 2
    root_dev = os.lstat(root).st_dev
    print("root=%s dev=%d:%d" % (root, os.major(root_dev), os.minor(root_dev)))
    print("mode=%s" % ("APPLY" if args.apply else "DRY-RUN"))

    lib_paths, lib_inodes, lib_sources = library_paths()
    print("proof sources:")
    for k, v in lib_sources.items():
        print("  library/%s: %s" % (k, v))
    qbt = Qbt()
    qbt.load()
    print("  download-client/qbittorrent: %s" % qbt.status)

    client_ok = qbt.status.startswith("ok")
    lib_ok = all(v.startswith("ok") for v in lib_sources.values())

    try:
        entries = sorted(
            [p for p in root.iterdir() if not p.name.startswith(".")],
            key=lambda p: p.name,
        )
    except OSError as e:
        print("FATAL: cannot list %s: %s" % (root, e), file=sys.stderr)
        return 2

    manifest = []
    skipped_mount = []
    for item in entries:
        try:
            ist = os.lstat(item)
        except OSError:
            continue
        if ist.st_dev != root_dev:
            skipped_mount.append(str(item))
            continue
        files, dirs, total, crossed, err = walk_item(item, root_dev)
        rec = {
            "path": str(item),
            "bytes": total,
            "files": len(files),
            "dirs": len(dirs),
            "proofs": {},
            "eligible": False,
            "reasons": [],
        }
        if crossed or err:
            rec["proofs"]["P1_device"] = (
                "FAIL: crosses filesystem" if crossed else "FAIL: %s" % err
            )
            rec["reasons"].append("foreign-device-or-walk-error")
            manifest.append(rec)
            continue
        rec["proofs"]["P1_device"] = "PASS (single device)"

        nlink_bad = []
        for f in files:
            try:
                if os.lstat(f).st_nlink != 1:
                    nlink_bad.append(str(f))
            except OSError:
                nlink_bad.append(str(f))
        if nlink_bad:
            rec["proofs"]["P2_nlink"] = "FAIL: %d file(s) nlink>1" % len(nlink_bad)
            rec["reasons"].append("hardlinked-into-library")
        else:
            rec["proofs"]["P2_nlink"] = "PASS (all %d nlink==1)" % len(files)

        if not lib_ok:
            rec["proofs"]["P3_library"] = "UNPROVEN (a library source failed)"
            rec["reasons"].append("library-unproven")
        else:
            hit = None
            for f in files:
                try:
                    st = os.lstat(f)
                except OSError:
                    continue
                if (st.st_dev, st.st_ino) in lib_inodes:
                    hit = "inode match %s" % f
                    break
                if str(f) in lib_paths:
                    hit = "path match %s" % f
                    break
            if hit is None:
                for lp in lib_paths:
                    if under(lp, str(item)):
                        hit = "library path inside item: %s" % lp
                        break
            if hit:
                rec["proofs"]["P3_library"] = "REFERENCED: %s" % hit
                rec["reasons"].append("library-referenced")
            else:
                rec["proofs"]["P3_library"] = "PASS (no library reference)"

        if not client_ok:
            rec["proofs"]["P4_client"] = "UNPROVEN (qBittorrent unreadable)"
            rec["reasons"].append("client-unproven")
        else:
            hit = None
            for t in qbt.content:
                for c in t["paths"]:
                    if under(c, str(item)) or under(str(item), c):
                        hit = "%s [%s] %s" % (t["name"], t["state"], c)
                        break
                if hit:
                    break
            if hit:
                rec["proofs"]["P4_client"] = "REFERENCED: %s" % hit
                rec["reasons"].append("download-client-referenced")
            else:
                rec["proofs"]["P4_client"] = "PASS (not in download client)"

        rec["eligible"] = not rec["reasons"]
        manifest.append(rec)

    eligible = sorted([r for r in manifest if r["eligible"]], key=lambda r: -r["bytes"])
    manifest.sort(key=lambda r: -r["bytes"])

    print(
        "\nentries=%d  eligible=%d  reclaimable=%.1f GB"
        % (len(manifest), len(eligible), sum(r["bytes"] for r in eligible) / 1e9)
    )
    if skipped_mount:
        print("skipped foreign-mount entries (%d):" % len(skipped_mount))
        for s in skipped_mount:
            print("  SKIP %s" % s)

    print("\ntop %d eligible leftovers:" % args.top)
    for r in eligible[: args.top]:
        print("  %9.2f GB  %s" % (r["bytes"] / 1e9, r["path"]))

    cats = {
        "eligible-and-unreferenced": eligible,
        "still-active-in-download-client": [
            r for r in manifest if "download-client-referenced" in r["reasons"]
        ],
        "hardlinked-into-library": [
            r for r in manifest if "hardlinked-into-library" in r["reasons"]
        ],
        "library-referenced": [
            r for r in manifest if "library-referenced" in r["reasons"]
        ],
        "genuinely-unknown": [
            r
            for r in manifest
            if set(r["reasons"]).intersection(
                {"library-unproven", "client-unproven", "foreign-device-or-walk-error"}
            )
        ],
    }
    print("\ncategories:")
    for name, items in cats.items():
        print(
            "  %-34s items=%3d  bytes=%9.1f GB"
            % (name, len(items), sum(r["bytes"] for r in items) / 1e9)
        )

    rejected = [r for r in manifest if not r["eligible"]]
    print("\ntop %d REJECTED (with reason):" % min(args.top, 10))
    for r in rejected[:10]:
        print("  %9.2f GB  %s  <- %s" % (r["bytes"] / 1e9, r["path"], ",".join(r["reasons"])))

    out = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "root": str(root),
        "device": "%d:%d" % (os.major(root_dev), os.minor(root_dev)),
        "proof_sources": dict(
            [("library/%s" % k, v) for k, v in lib_sources.items()]
            + [("download-client/qbittorrent", qbt.status)]
        ),
        "reclaimable_bytes": sum(r["bytes"] for r in eligible),
        "categories": {k: len(v) for k, v in cats.items()},
        "category_bytes": {k: sum(r["bytes"] for r in v) for k, v in cats.items()},
        "eligible": eligible,
        "all_entries": manifest,
    }
    if args.json:
        Path(args.json).write_text(json.dumps(out, indent=2))
        print("\nmanifest written: %s" % args.json)

    if not args.apply:
        print("\nDRY-RUN: nothing deleted.")
        return 0
    if not args.i_mean_it:
        print("\nREFUSING: --apply needs --i-mean-it")
        return 2
    if not eligible:
        print("\nnothing eligible; nothing deleted.")
        return 0

    if not client_ok:
        print("\nREFUSING: --apply needs a working download-client session, or the")
        print("client would be left pointing at files that no longer exist.")
        return 2

    freed = 0
    report = []
    for r in eligible:
        p = Path(r["path"])
        rec = {"path": str(p), "bytes": r["bytes"], "via": None, "detail": None}
        try:
            if os.lstat(p).st_dev != root_dev:
                rec["via"] = "skipped"
                rec["detail"] = "device changed since manifest"
                print("  SKIP (device changed) %s" % p)
                report.append(rec)
                continue
            owned, name_only = qbt.match(p)
            if owned:
                ok, detail = qbt.delete([t["hash"] for t in owned if t.get("hash")])
                rec["via"] = "qbittorrent-api(deleteFiles)"
                rec["detail"] = "%s; hashes=%s" % (detail, len(owned))
                if not ok:
                    print("  FAILED (client) %s: %s" % (p, detail))
                    report.append(rec)
                    continue
                # the API owns the payload; confirm the path is actually gone
                if p.exists() and os.lstat(p).st_dev == root_dev:
                    if p.is_dir() and not p.is_symlink():
                        shutil.rmtree(p)
                    else:
                        p.unlink()
                    rec["detail"] += "; payload still present, filesystem cleanup"
                freed += r["bytes"]
                print("  DELETED via client %9.2f GB  %s" % (r["bytes"] / 1e9, p))
            else:
                # No torrent owns these bytes. Re-check the device immediately
                # before the unlink so a mount that appeared after the audit
                # cannot be walked.
                if p.is_dir() and not p.is_symlink():
                    shutil.rmtree(p)
                else:
                    p.unlink()
                freed += r["bytes"]
                rec["via"] = "filesystem"
                rec["detail"] = (
                    "no owning torrent; name-only matches=%d" % len(name_only)
                    if name_only
                    else "no torrent entry"
                )
                print("  DELETED via fs     %9.2f GB  %s" % (r["bytes"] / 1e9, p))
        except OSError as e:
            rec["via"] = "failed"
            rec["detail"] = str(e)
            print("  FAILED %s: %s" % (p, e))
        report.append(rec)
    print("\nfreed %.1f GB" % (freed / 1e9))
    via = {}
    for rec in report:
        via[rec["via"]] = via.get(rec["via"], 0) + 1
    print("apply paths: %s" % via)
    rp = Path(args.apply_report) if args.apply_report else Path(
        (args.json or "leftover-manifest.json") + ".applied.json"
    )
    rp.write_text(json.dumps({"freed_bytes": freed, "items": report}, indent=2))
    print("apply report: %s" % rp)
    return 0


if __name__ == "__main__":
    sys.exit(main())
