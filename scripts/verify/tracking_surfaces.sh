#!/usr/bin/env bash
# scripts/verify/tracking_surfaces.sh
#
# Verifies the three fund-tracking surfaces agree and are actually fresh:
#   1. WALLET FEED      data/wallet_feed.json  +  data/wallets.sqlite:wallet_trades
#                       (are the amounts non-zero, not just present?)
#   2. RECONCILE RAILS  data/reconcile.jsonl (SOL) and data/reconcile_evm.jsonl (RHC/EVM)
#                       freshness + drift + that the CronJobs that write them fire
#   3. DAEMON LOG LINE  the "[WALLETS] fetched N/N wallets ..." line, and sol dryrun
#
# Supersedes /tmp/verify_tracking.sh, which had two silent-zero bugs:
#   * it globbed data/*wallet* expecting *.jsonl, but the wallet feed is
#     wallet_feed.json (JSON, not JSONL) — so its wallet section printed NOTHING and
#     the empty output read as "clean";
#   * it looked for reconcile fields `logged`/`onchain`/`missing`; the SOL rail's real
#     fields are logged_count/onchain_count/logged_unconfirmed/onchain_only, so those
#     probes reported a vacuous absence.
# Both are now impossible: field names are printed, and an empty extractor is
# INCONCLUSIVE (exit 2).
#
# HOST: nexus (~/Work/trading + kubectl). cwd: anywhere (TRADING_ROOT overrides).
# READ-ONLY: file reads, sqlite mode=ro + busy_timeout, kubectl get/logs.
# FAILURE LOOKS LIKE: wallet feed not ok / stale, zero non-zero amounts, a reconcile
#   rail with drift != 0 or older than twice its schedule, or no [WALLETS] line found.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
: "${TRADING_ROOT:=$HOME/Work/trading}"
export TRADING_ROOT

echo "verify/tracking_surfaces.sh  host=$(hostname)  cwd=$(pwd)  read-only"
echo "  trading_root=$TRADING_ROOT"
if [ ! -d "$TRADING_ROOT" ]; then
  inconclusive "TRADING_ROOT=$TRADING_ROOT does not exist on $(hostname) — wrong host?"
  finish
fi
_hr

# ------------------------------------------------------- 1. wallet feed
section "1. WALLET FEED — file health, then the AMOUNTS (a feed of zeros is not a feed)"
"$PY" - <<'PY'
import os
import _probe_lib as pl
r = pl.Report("wallet-feed")
root = os.environ.get("TRADING_ROOT", os.path.expanduser("~/Work/trading"))

# --- 1a. the writer's own status file
feed, err = pl.read_json(os.path.join(root, "data/wallet_feed.json"))
if feed is None:
    r.unknown("data/wallet_feed.json: %s" % err)
else:
    r.note("wallet_feed.json fields: %s" % ", ".join(sorted(feed.keys())))
    interval = feed.get("interval_s")
    age = feed.get("age_s")
    r.note("ok=%s fetched=%s wallets=%s new_rows=%s quiet=%s source=%s "
           "newest_ts=%s age_s=%s interval_s=%s errors=%s"
           % (feed.get("ok"), feed.get("fetched"), feed.get("wallets"), feed.get("new_rows"),
              feed.get("quiet"), feed.get("source"), feed.get("newest_ts"), age, interval,
              feed.get("errors")))
    if feed.get("ok") is not True:
        r.bad("wallet_feed ok=%s (failed=%s errors=%s)"
              % (feed.get("ok"), feed.get("failed"), feed.get("errors")))
    else:
        r.ok("wallet_feed self-reports ok")
    if not isinstance(age, (int, float)) or not isinstance(interval, (int, float)):
        r.unknown("wallet_feed age_s/interval_s not numeric — cannot judge cadence")
    elif age > 2 * interval + 60:
        r.bad("wallet_feed age=%ss but interval=%ss" % (age, interval))
    else:
        r.ok("wallet_feed age=%ss within 2x interval=%ss" % (age, interval))
    if not feed.get("wallets") or feed.get("fetched") != feed.get("wallets"):
        r.bad("wallet_feed fetched %s of %s wallets" % (feed.get("fetched"), feed.get("wallets")))
    else:
        r.ok("wallet_feed fetched %s/%s wallets" % (feed.get("fetched"), feed.get("wallets")))

# --- 1b. the actual rows + amounts
db = os.path.join(root, "data/wallets.sqlite")
try:
    con = pl.open_ro(db)
except Exception as exc:
    r.unknown("wallets.sqlite read-only open failed: %s" % exc)
    r.finish()
trades_total = con.execute("SELECT COUNT(*) FROM wallet_trades").fetchone()[0]
r.note("wallet_trades columns: %s" % ", ".join(pl.columns(con, "wallet_trades")))
r.note("wallet_trades rows=%d" % trades_total)
if trades_total == 0:
    r.unknown("wallet_trades is empty — amount checks below would be vacuous")
else:
    r.ok("wallet_trades has %d rows" % trades_total)
    newest = con.execute("SELECT MAX(ts) FROM wallet_trades").fetchone()[0]
    if newest:
        r.note("newest trade ts=%s (%s) age=%.1f min"
               % (newest, pl.hhmm(newest), pl.age_min(newest)))
    # quote_amount is the field whose zeros were the original bug
    rows = con.execute(
        "SELECT quote_amount FROM wallet_trades ORDER BY ts DESC LIMIT 40").fetchall()
    amounts = [x[0] for x in rows if isinstance(x[0], (int, float))]
    nonzero = [a for a in amounts if a]
    r.note("last 40 trades: %d numeric quote_amount, %d non-zero" % (len(amounts), len(nonzero)))
    if not amounts:
        r.unknown("no numeric quote_amount in the last 40 trades — column may have drifted")
    elif not nonzero:
        r.bad("ALL of the last %d quote_amount values are zero (the original bug)" % len(amounts))
    else:
        r.ok("%d/%d recent trades carry a non-zero quote_amount" % (len(nonzero), len(amounts)))
r.finish()
PY
bump_rc $?

# ------------------------------------------------------- 2. reconcile rails
section "2. RECONCILE RAILS — freshness, drift, and whether their CronJobs fire"
"$PY" - <<'PY'
import os
import _probe_lib as pl
r = pl.Report("reconcile-rails")
root = os.environ.get("TRADING_ROOT", os.path.expanduser("~/Work/trading"))

# 2a. the CronJobs that write them
d, err = pl.kubectl_json("-n", "trading", "get", "cronjobs", "-o", "json")
if d is None:
    r.unknown("kubectl get cronjobs: %s" % err)
else:
    import datetime
    now = datetime.datetime.now(datetime.timezone.utc)
    found = 0
    for cj in d.get("items", []):
        name = cj["metadata"]["name"]
        if "reconcile" not in name:
            continue
        found += 1
        st = cj.get("status") or {}
        sched = cj["spec"].get("schedule")
        for label, key in (("lastSchedule", "lastScheduleTime"), ("lastSuccess", "lastSuccessfulTime")):
            val = st.get(key)
            age = ("NEVER" if not val else
                   round((now - datetime.datetime.fromisoformat(val.replace("Z", "+00:00")))
                         .total_seconds() / 60.0, 1))
            r.note("%-26s %-14s schedule=%-14s age_min=%s" % (name, label, sched, age))
        ok_age = st.get("lastSuccessfulTime")
        if not ok_age:
            r.bad("%s has never succeeded" % name)
        else:
            actual = (now - datetime.datetime.fromisoformat(ok_age.replace("Z", "+00:00"))).total_seconds() / 60.0
            expected = pl.expected_minutes(sched)
            if expected is None:
                r.unknown("%s: cannot derive cadence from '%s'" % (name, sched))
            elif actual > max(2 * expected, expected + 5):
                r.bad("%s last success %.0f min ago vs cadence %d min" % (name, actual, expected))
            else:
                r.ok("%s fired %.0f min ago (cadence %d min)" % (name, actual, expected))
    if not found:
        r.unknown("no reconcile CronJobs found in namespace trading")

# 2b. the rows themselves, with their real field names
for fname, rail in (("reconcile.jsonl", "SOL"), ("reconcile_evm.jsonl", "RHC/EVM")):
    path = os.path.join(root, "data", fname)
    rows, note = pl.jsonl_rows(path)
    if rows is None:
        r.unknown("%s (%s rail): %s" % (fname, rail, note))
        continue
    if not rows:
        r.unknown("%s (%s rail): no parseable rows (%s)" % (fname, rail, note))
        continue
    last = rows[-1]
    r.note("%s (%s) rows=%d%s" % (fname, rail, len(rows), " " + note if note else ""))
    field, val = pl.show_fields(r, fname, last)
    if field is None:
        r.unknown("%s: no timestamp field — freshness unknown" % fname)
    elif pl.age_min(val) > 150:
        r.bad("%s newest row is %.0f min old" % (fname, pl.age_min(val)))
    else:
        r.ok("%s newest row %.0f min old" % (fname, pl.age_min(val)))
    if "drift" not in last:
        r.unknown("%s has no 'drift' field (schema drift?)" % fname)
    elif last.get("drift") not in (0, 0.0, None):
        r.bad("%s drift=%s" % (fname, last.get("drift")))
    else:
        r.ok("%s drift=%s" % (fname, last.get("drift")))
    for key, value in sorted(last.items()):
        if key == field:
            continue
        sval = str(value)
        r.note("     %-22s %s" % (key, sval[:90]))
r.finish()
PY
bump_rc $?

# ------------------------------------------------------- 3. daemon log line
section "3. DAEMON LOG — the [WALLETS] line must exist (absence is not 'clean')"
LOGS="$(kubectl -n trading logs -l app=trading-daemon --tail=600 2>/dev/null || true)"
WALLETS_LINE="$(printf '%s\n' "$LOGS" | grep -E '\[WALLETS\]' | tail -3)"
DRYRUN_LINE="$(printf '%s\n' "$LOGS" | grep -iE 'sol_dryrun|dryrun' | tail -3)"
if assert_nonempty "daemon log stream" "$LOGS"; then
  check 0 "daemon log readable ($(printf '%s\n' "$LOGS" | wc -l) lines)"
fi
if assert_nonempty "[WALLETS] lines in the last 600 log lines" "$WALLETS_LINE"; then
  printf '%s\n' "$WALLETS_LINE" | sed 's/^/   /'
  check 0 "[WALLETS] line present"
else
  check 1 "[WALLETS] line NOT present in the last 600 lines"
fi
if [ -n "${DRYRUN_LINE//[[:space:]]/}" ]; then
  note "sol dryrun:"
  printf '%s\n' "$DRYRUN_LINE" | sed 's/^/     /'
else
  note "no sol dryrun lines in the last 600 log lines (informational)"
fi

finish
