#!/usr/bin/env python3
"""Shared read-only helpers for scripts/verify/*.py and the python blocks in *.sh.

Rules enforced here (see scripts/verify/README.md):
  * open_ro()    — sqlite opened with mode=ro + busy_timeout. The live ledger holds a
                   write lock during cycles; a plain connect can raise
                   "database is locked", which is easily mistaken for "no data".
  * newest_ts()  — never guesses a timestamp field. Real schemas here disagree
                   (cluster_shadow.jsonl uses event_ts/recorded_ts, NOT ts), so the
                   caller prints the field it used; a wrong guess is visible instead
                   of silently reported as staleness.
  * Report.unknown — an empty input is INCONCLUSIVE and forces exit code 2, so a
                   vacuous run can never masquerade as a clean verification.

Nothing in this module writes to disk, to sqlite, or to any service.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import urllib.request

# Timestamp field names seen across this system's artifacts, newest-first priority.
TS_FIELDS = ("ts", "event_ts", "recorded_ts", "updated_ts", "created_ts",
             "created_at", "snapshot_ts", "block_time", "last_ts")

VM_DEFAULT = "http://10.43.33.250:8428"
KUBECONFIG_DEFAULT = "/etc/rancher/k3s/k3s.yaml"


class Report:
    """Status vocabulary shared with _lib.sh: PASS / FAIL / INCONCLUSIVE.

    finish() exits with 2 if anything was INCONCLUSIVE, 1 if any FAIL, else 0.
    """

    def __init__(self, name):
        self.name = name
        self.host = socket.gethostname()
        self.n_ok = self.n_bad = self.n_unknown = 0
        print("-" * 64)
        print("%s  host=%s  read-only" % (name, self.host))

    def section(self, title):
        print("\n== %s ==" % title)

    def note(self, msg):
        print("   %s" % msg)

    def banner(self, msg):
        print("  -- %s --" % msg)

    def ok(self, msg):
        self.n_ok += 1
        print("  [PASS] %s" % msg)

    def bad(self, msg):
        self.n_bad += 1
        print("  [FAIL] %s" % msg)

    def unknown(self, msg):
        """Empty input or schema drift. Never let this read as a clean result."""
        self.n_unknown += 1
        print("  [INCONCLUSIVE] %s" % msg)

    def finish(self):
        print("-" * 64)
        print("verify summary: %d pass / %d fail / %d inconclusive"
              % (self.n_ok, self.n_bad, self.n_unknown))
        if self.n_unknown:
            print("RESULT: INCONCLUSIVE — empty input or schema drift; NOT a clean verification")
            sys.exit(2)
        if self.n_bad:
            print("RESULT: FAIL")
            sys.exit(1)
        print("RESULT: OK")
        sys.exit(0)


def open_ro(path, timeout_ms=20000):
    """Open sqlite strictly read-only with a busy timeout."""
    if not os.path.exists(path):
        raise FileNotFoundError(path)
    con = sqlite3.connect("file:%s?mode=ro" % path, uri=True,
                          timeout=timeout_ms / 1000.0)
    con.execute("PRAGMA busy_timeout=%d" % timeout_ms)
    con.execute("PRAGMA query_only=1")
    return con


def columns(con, table):
    return [r[1] for r in con.execute("PRAGMA table_info(%s)" % table)]


def jsonl_rows(path):
    """-> (rows|None, note). None means absent/unreadable; [] means genuinely empty."""
    if not os.path.exists(path):
        return None, "absent"
    if os.path.getsize(path) == 0:
        return [], "zero-length"
    rows, bad = [], 0
    with open(path, errors="replace") as fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                bad += 1
    return rows, ("unparseable_lines=%d" % bad) if bad else ""


def read_json(path):
    if not os.path.exists(path):
        return None, "absent"
    try:
        return json.load(open(path, errors="replace")), ""
    except Exception as exc:
        return None, str(exc)


def newest_ts(row):
    """-> (field_name, value) using the first present timestamp field, else (None, None)."""
    for field in TS_FIELDS:
        val = row.get(field)
        if isinstance(val, bool):
            continue
        if isinstance(val, (int, float)) and val > 0:
            return field, val
    return None, None


def age_min(ts, now=None):
    return ((time.time() if now is None else now) - ts) / 60.0


def hhmm(ts):
    return time.strftime("%H:%M:%S", time.localtime(ts)) \
        if isinstance(ts, (int, float)) and ts else "?"


def show_fields(report, label, row):
    """Print a row's field names so schema drift is visible rather than a silent zero."""
    if row is None:
        report.note("%s: <no row>" % label)
        return None, None
    report.note("%s fields: %s" % (label, ", ".join(sorted(row.keys()))))
    field, val = newest_ts(row)
    if field:
        report.note("%s timestamp field: %s = %s (%s) age=%.1f min"
                    % (label, field, val, hhmm(val), age_min(val)))
    else:
        report.note("%s: NO recognised timestamp field among %s"
                    % (label, sorted(row.keys())))
    return field, val


def expected_minutes(schedule):
    """Rough cadence in minutes from a standard 5-field cron expr (minute field only).

    Returns None when it cannot tell, so callers report INCONCLUSIVE rather than
    inventing a threshold.
    """
    if not schedule:
        return None
    parts = schedule.split()
    if len(parts) < 5:
        return None
    minute, hour, dom, mon, dow = parts[:5]

    def step(field):
        if "/" in field:
            tail = field.split("/")[-1].strip()
            if tail.isdigit() and int(tail) > 0:
                return int(tail)
        return None

    m_step = step(minute)            # */N, a-b/N  (e.g. 3-59/15)
    if m_step:
        return m_step
    h_step = step(hour)              # */N hours
    if h_step:
        return h_step * 60
    sparse = dom != "*" or mon != "*" or dow != "*"
    if minute == "*":
        return 1
    if "," in minute:
        vals = sorted(int(x) for x in minute.split(",") if x.strip().isdigit())
        if len(vals) < 2:
            return None
        gaps = [b - a for a, b in zip(vals, vals[1:])] + [60 - vals[-1] + vals[0]]
        return min(gaps) if hour == "*" else min(gaps) * 60
    if hour == "*":
        return 60
    if sparse:
        return 10080                  # weekly-ish; monthly is only more patient
    if "," in hour:
        vals = sorted(int(x) for x in hour.split(",") if x.strip().isdigit())
        if len(vals) >= 2:
            gaps = [b - a for a, b in zip(vals, vals[1:])] + [24 - vals[-1] + vals[0]]
            return min(gaps) * 60
    return 1440                       # daily


def kubectl_json(*args, timeout=90):
    """Read-only kubectl call. -> (parsed|None, error_string)."""
    if not shutil.which("kubectl"):
        return None, "kubectl not on PATH"
    env = dict(os.environ)
    env.setdefault("KUBECONFIG", KUBECONFIG_DEFAULT)
    try:
        proc = subprocess.run(["kubectl", *args], capture_output=True, text=True,
                              timeout=timeout, env=env)
    except Exception as exc:
        return None, "kubectl failed: %s" % exc
    if proc.returncode != 0:
        return None, "kubectl rc=%d: %s" % (proc.returncode, proc.stderr.strip()[:200])
    try:
        return json.loads(proc.stdout), ""
    except Exception as exc:
        return None, "unparseable kubectl output: %s" % exc


def kubectl_text(*args, timeout=90):
    """Read-only kubectl call returning raw stdout text. -> (text|None, error)."""
    if not shutil.which("kubectl"):
        return None, "kubectl not on PATH"
    env = dict(os.environ)
    env.setdefault("KUBECONFIG", KUBECONFIG_DEFAULT)
    try:
        proc = subprocess.run(["kubectl", *args], capture_output=True, text=True,
                              timeout=timeout, env=env)
    except Exception as exc:
        return None, "kubectl failed: %s" % exc
    if proc.returncode != 0:
        return None, "kubectl rc=%d: %s" % (proc.returncode, proc.stderr.strip()[:200])
    return proc.stdout, ""


def vm_query(expr, base=None, timeout=12):
    """VictoriaMetrics instant query (read-only). -> (result_list|None, error)."""
    base = base or os.environ.get("VM", VM_DEFAULT)
    url = base + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    try:
        with urllib.request.urlopen(url, timeout=timeout) as fh:
            return json.load(fh)["data"]["result"], ""
    except Exception as exc:
        return None, str(exc)
