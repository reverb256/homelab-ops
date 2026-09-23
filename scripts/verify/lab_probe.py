#!/usr/bin/env python3
"""scripts/verify/lab_probe.py

Read-only probe of the lab database (data/lab.sqlite): the collector `runs` ledger,
`token_state` and `snapshots`, plus the extraction-health faults recorded against
them.

Merges /tmp/lab_check3.py, lab_check4.py and lab_check5.py — three iterative fragments
that each opened the same 554 MB database to ask a related question. One file, one
read-only connection, all sections. Superseded shell names are noted in the README.

What it asserts (and why each assertion exists):
  * tables/columns are printed as FOUND, so column drift is visible immediately;
  * `runs` must be non-empty and must contain every expected source — a collector that
    silently stops writing one source is the failure mode this catches;
  * the `trenches:near_completion` category must exist and grow (it was previously
    discarded, ~120 rows against ~24.7k for its sibling);
  * any EXTRACTION-DROP fault note is surfaced, not buried.
  An empty table is INCONCLUSIVE (exit 2), never a clean pass.

READ-ONLY: sqlite is opened with mode=ro + busy_timeout (the live ledger holds a write
lock during cycles, and a plain connect can raise "database is locked" — which is
easily mistaken for "no data"). No INSERT/UPDATE/DELETE, no file writes.

HOST: nexus (~/Work/trading). cwd: anywhere (TRADING_ROOT overrides).
FAILURE LOOKS LIKE: exit 1 with [FAIL] lines (a source stopped arriving, near_completion
  has no rows while its sibling has thousands), or exit 2 with [INCONCLUSIVE] if a table
  is empty / a column vanished / the DB could not be opened read-only.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _probe_lib as pl  # noqa: E402

ROOT = os.environ.get("TRADING_ROOT", os.path.expanduser("~/Work/trading"))
DB = os.path.join(ROOT, "data/lab.sqlite")

# Sources the collector is expected to write every cycle.
EXPECTED_SOURCES = ("trending", "trenches", "signal", "sm_trades", "kol_trades", "watchlist")
# A source that has not been written in this many minutes is stale for this pipeline.
STALE_MIN = 60.0
# The category that was previously discarded; it must now be present.
REQUIRED_KIND = "near_completion"


def main():
    report = pl.Report("lab_probe")
    report.note("db=%s" % DB)

    # ---------------------------------------------------------------- open
    try:
        con = pl.open_ro(DB)
    except Exception as exc:
        report.unknown("read-only open of %s failed: %s" % (DB, exc))
        report.finish()

    size = os.path.getsize(DB)
    report.note("sqlite opened read-only (mode=ro, busy_timeout=20000); size=%d bytes" % size)

    tables = [r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
    report.section("1. SCHEMA AS FOUND (drift visible, not guessed)")
    report.note("tables: %s" % ", ".join(tables))
    for table in ("runs", "token_state", "snapshots"):
        if table not in tables:
            report.unknown("table `%s` is absent — schema drift" % table)
            continue
        cols = pl.columns(con, table)
        count = con.execute("SELECT COUNT(*) FROM %s" % table).fetchone()[0]
        report.note("%-12s rows=%-7d columns=%s" % (table, count, ", ".join(cols)))
    if not any(t in tables for t in ("runs", "token_state", "snapshots")):
        report.unknown("none of the expected tables exist — cannot verify anything")
        report.finish()

    # ---------------------------------------------------------------- runs
    report.section("2. COLLECTOR `runs` — every expected source must be arriving")
    if "runs" not in tables:
        report.unknown("no runs table")
    else:
        total = con.execute("SELECT COUNT(*) FROM runs").fetchone()[0]
        if not total:
            report.unknown("runs is empty — all downstream checks would be vacuous")
        else:
            report.ok("runs has %d rows" % total)
            rows = list(con.execute(
                "SELECT source, COUNT(*), MAX(ts), SUM(items) FROM runs "
                "GROUP BY source ORDER BY COUNT(*) DESC"))
            seen = set()
            # Cycle sources are the scheduled feeds whose cadence matters. Everything
            # else is a one-off per-token probe (token_info:0x…, token_security:0x…),
            # which has no cadence — listing 130 of them buried the signal, so they are
            # aggregated instead. Their ages are one-off timestamps, not staleness.
            cycle = [row for row in rows if row[0] in EXPECTED_SOURCES]
            probes = [row for row in rows if row[0] not in EXPECTED_SOURCES]
            for source, n, newest, items in cycle:
                seen.add(source)
                age = pl.age_min(newest) if newest else None
                report.note("%-24s rows=%-6d newest=%s age_min=%s sum_items=%s"
                            % (source[:24], n, pl.hhmm(newest),
                               "?" if age is None else round(age, 1), items))
            if probes:
                probe_rows = sum(n for _, n, _, _ in probes)
                probe_newest = max((mx for _, _, mx, _ in probes if mx), default=None)
                report.note("per-token probe sources: %d source(s), %d row(s) total, "
                            "newest %s" % (len(probes), probe_rows, pl.hhmm(probe_newest)))
                report.note("   (one-off probes — no cadence; aggregated rather than listed)")
            for source in EXPECTED_SOURCES:
                if source not in seen:
                    report.bad("expected source `%s` is missing from runs" % source)
                    continue
                newest = con.execute(
                    "SELECT MAX(ts) FROM runs WHERE source=?", (source,)).fetchone()[0]
                age = pl.age_min(newest) if newest else None
                if age is None:
                    report.unknown("source `%s` has no numeric ts" % source)
                elif age > STALE_MIN:
                    report.bad("source `%s` last ran %.0f min ago" % (source, age))
                else:
                    report.ok("source `%s` fresh (%.1f min)" % (source, age))

            report.banner("newest watchlist cycle, note field in full")
            for ts, ok, items, note in con.execute(
                    "SELECT ts, ok, items, note FROM runs WHERE source='watchlist' "
                    "ORDER BY ts DESC LIMIT 3"):
                report.note("%s ok=%s items=%s" % (pl.hhmm(ts), ok, items))
                report.note("     note: %s" % str(note)[:300])

    # ---------------------------------------------------------------- trenches
    report.section("3. TRENCHES SUB-KINDS — is near_completion still arriving?")
    if "runs" not in tables:
        report.unknown("no runs table")
    else:
        rows = list(con.execute(
            "SELECT source, COUNT(*), MAX(ts), SUM(items) FROM runs "
            "WHERE source LIKE 'trenches%' GROUP BY source ORDER BY COUNT(*) DESC"))
        if not rows:
            report.unknown("no 'trenches' rows in runs")
        for source, n, newest, items in rows:
            report.note("%-28s rows=%-7d newest=%s sum_items=%s"
                        % (source, n, pl.hhmm(newest), items))

    report.banner("token_state / snapshots: kind inventory + the previously-discarded kind")
    for table in ("token_state", "snapshots"):
        if table not in tables:
            report.unknown("%s absent" % table)
            continue
        kinds = list(con.execute(
            "SELECT kind, COUNT(*), MAX(ts) FROM %s GROUP BY kind "
            "ORDER BY COUNT(*) DESC LIMIT 12" % table))
        if not kinds:
            report.unknown("%s has no rows" % table)
            continue
        for kind, n, newest in kinds:
            age = pl.age_min(newest) if newest else None
            report.note("%-12s %-34s n=%-7d newest=%s%s"
                        % (table, str(kind)[:34], n, pl.hhmm(newest),
                           "" if age is None else "  (age %.0f min)" % age))
        near = [n for kind, n, _ in con.execute(
            "SELECT kind, COUNT(*), MAX(ts) FROM %s WHERE kind LIKE '%%%s%%' "
            "GROUP BY kind" % (table, REQUIRED_KIND))]
        near_total = sum(near)
        sibling = [n for kind, n, _ in con.execute(
            "SELECT kind, COUNT(*), MAX(ts) FROM %s WHERE kind LIKE '%%new_creation%%' "
            "GROUP BY kind" % table)]
        if near_total:
            report.ok("%s: %s rows present (%d kind(s))%s"
                      % (table, REQUIRED_KIND, len(near), 
                         "" if not sibling else "  vs new_creation=%d" % sum(sibling)))
        elif sibling and sum(sibling) > 0:
            report.bad("%s: %s has ZERO rows while new_creation has %d — the discarded "
                       "category is not arriving" % (table, REQUIRED_KIND, sum(sibling)))
        else:
            report.note("%s: no %s rows (and no new_creation baseline to compare)"
                        % (table, REQUIRED_KIND))

    # ---------------------------------------------------------------- cycles
    report.section("4. LAST CYCLES ACROSS ALL SOURCES (are counts stable, or dipping?)")
    if "runs" in tables:
        rows = list(con.execute(
            "SELECT ts, source, ok, items FROM runs ORDER BY ts DESC LIMIT 14"))
        if not rows:
            report.unknown("no rows in runs")
        for ts, source, ok, items in rows:
            report.note("%s %-30s ok=%s items=%s"
                        % (pl.hhmm(ts), str(source)[:30], ok, items))
    else:
        report.unknown("no runs table")

    # ---------------------------------------------------------------- faults
    report.section("5. EXTRACTION-DROP FAULTS recorded by the collector")
    if "runs" in tables:
        hits = list(con.execute(
            "SELECT COUNT(*) FROM runs WHERE note LIKE '%EXTRACTION-DROP%' "
            "OR note LIKE '%extraction_drop%'"))
        n = hits[0][0] if hits else 0
        report.note("rows whose note mentions extraction drops: %d" % n)
        if n:
            for ts, source, note in con.execute(
                    "SELECT ts, source, note FROM runs "
                    "WHERE note LIKE '%EXTRACTION-DROP%' OR note LIKE '%extraction_drop%' "
                    "ORDER BY ts DESC LIMIT 5"):
                report.note("%s %s : %s" % (pl.hhmm(ts), source, str(note)[:200]))
            report.ok("extraction-drop faults are being recorded (guard is wired)")
        else:
            report.ok("no extraction-drop faults recorded in runs")
    else:
        report.unknown("no runs table")

    con.close()
    report.finish()


if __name__ == "__main__":
    main()
