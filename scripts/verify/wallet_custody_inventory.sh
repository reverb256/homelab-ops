#!/usr/bin/env bash
# scripts/verify/wallet_custody_inventory.sh
#
# Read-only inventory of fund custody for one host: who can reach what, which key
# files exist and with what mode, whether anything can move funds right now, and
# whether the reconcile rails are carrying balances.
#
# Merges /tmp/access_wallets.sh and /tmp/wallets_final.sh. They disagreed because each
# looked in only one place: the encrypted store lives on ZEPHYR, but the key files and
# reconcile data live on NEXUS. The second script existed purely to correct the first
# ("my earlier check looked in the wrong place"). This version reads from the host it
# is run on and *says so*, and reports the store as absent-in-place rather than
# concluding it is missing.
#
# It also stops printing guessed reconcile field names: access_wallets.sh asked for
# wallet/balance/balance_eth/chain_id/head, none of which exist on either rail. Field
# names are now echoed from the row that was actually read.
#
# NEVER prints a secret value: key files are described by mode/uid/size/readability and
# a sha256 FINGERPRINT (first 12 hex chars) plus value length. Nothing else.
#
# HOST: nexus for the full picture; run it on zephyr to see the encrypted store's
#       working tree and local key files. cwd: anywhere (TRADING_ROOT overrides).
# READ-ONLY: stat/ls/find, file reads, sqlite mode=ro, ssh reachability probes, kubectl.
# FAILURE LOOKS LIKE: a key file world-readable or group-readable, an absent key file
#   that should exist, exec armed with a KILL file absent, or a rail whose balances
#   are missing/unreadable.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$HERE/_lib.sh"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
: "${TRADING_ROOT:=$HOME/Work/trading}"
: "${SECRETS_STORE:=$HOME/Work/Projects/nixos-secrets}"
export TRADING_ROOT SECRETS_STORE

echo "verify/wallet_custody_inventory.sh  host=$(hostname)  cwd=$(pwd)  read-only"
echo "  trading_root=$TRADING_ROOT  secrets_store=$SECRETS_STORE"
if [ ! -d "$TRADING_ROOT" ]; then
  inconclusive "TRADING_ROOT=$TRADING_ROOT does not exist on $(hostname) — wrong host?"
  finish
fi
_hr

# ------------------------------------------------------- 1. reachability
section "1. HOST REACHABILITY (from $(hostname))"
"$PY" - <<'PY'
import subprocess
import socket
import _probe_lib as pl
r = pl.Report("reachability")
targets = ["zephyr", "forge", "sentry", "nexus", "oracle-vps", "100.64.0.2"]
here = socket.gethostname()
probed = 0
for target in targets:
    if target == here:
        r.note("%-14s (this host) reachable" % target)
        probed += 1
        continue
    proc = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
                           "-o", "StrictHostKeyChecking=accept-new", target, "echo ok"],
                          capture_output=True, text=True, timeout=20)
    if proc.returncode == 0 and "ok" in proc.stdout:
        r.note("%-14s reachable" % target)
        probed += 1
    else:
        r.note("%-14s NOT reachable" % target)
if not probed:
    r.unknown("no host was reachable — the inventory below cannot be cross-checked")
else:
    r.ok("%d/%d probe targets responded" % (probed, len(targets)))
r.finish()
PY
bump_rc $?

# ------------------------------------------------------- 2. key files
section "2. KEY FILES ON THIS HOST: mode / owner / size / readable / fingerprint"
"$PY" - <<'PY'
import hashlib
import os
import stat
import _probe_lib as pl
r = pl.Report("key-files")
root = os.environ.get("TRADING_ROOT", os.path.expanduser("~/Work/trading"))
CANDIDATES = ["data/keys/live.json", "data/keys/rhc.json", "data/keys/devnet.json",
              "data/keys/alchemy.txt", "data/keys/helius.txt", "data/exec.env"]
FINGERPRINT_CAP = 128 * 1024
present = 0
for rel in CANDIDATES:
    path = os.path.join(root, rel)
    if not os.path.exists(path):
        r.note("%-24s absent" % rel)
        continue
    present += 1
    st = os.stat(path)
    mode = stat.S_IMODE(st.st_mode)
    with open(path, "rb") as fh:
        blob = fh.read(FINGERPRINT_CAP)
    fingerprint = hashlib.sha256(blob).hexdigest()[:12]
    r.note("%-24s mode=%04o uid=%d size=%-7d readable=%s sha256=%s…"
           % (rel, mode, st.st_uid, st.st_size, os.access(path, os.R_OK), fingerprint))
    if mode & 0o077:
        r.bad("%s mode=%04o is readable beyond the owner" % (rel, mode))
    else:
        r.ok("%s mode=%04o owner-only" % (rel, mode))

keysdir = os.path.join(root, "data/keys")
if present == 0:
    r.unknown("none of the known key files exist under %s — wrong host, or custody moved"
              % root)
elif not os.path.isdir(keysdir):
    r.unknown("data/keys/ directory missing")
else:
    r.ok("%d key file(s) present and vetted (values never printed)" % present)
    r.note("data/keys/ inventory: %s"
           % ", ".join(sorted(os.listdir(keysdir))[:12]))
r.finish()
PY
bump_rc $?

# ------------------------------------------------------- 3. arm state
section "3. ARM STATE: can anything move funds right now?"
"$PY" - <<'PY'
import os
import re
import _probe_lib as pl
r = pl.Report("arm-state")
root = os.environ.get("TRADING_ROOT", os.path.expanduser("~/Work/trading"))

status_path = os.path.join(root, "data/exec_status.json")
status, err = pl.read_json(status_path)
if status is None:
    r.unknown("exec_status.json: %s" % err)
else:
    r.note("exec_status.json fields: %s" % ", ".join(sorted(status.keys())))
    r.note("armed=%s mode=%s sent_today=%s"
           % (status.get("armed"), status.get("mode"), status.get("sent_today")))
    if status.get("armed"):
        r.note("exec is ARMED — expected only for an intentional live window")
    else:
        r.ok("exec not armed")

env_path = os.path.join(root, "data/exec.env")
names, err = ([], "absent")
if os.path.exists(env_path):
    body = open(env_path, errors="replace").read()
    names = re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)=", body, re.M)
    err = ""
if names:
    r.note("exec.env holds %d key NAME(s) (values never printed): %s"
           % (len(names), ", ".join(sorted(names))))
    arm_flags = [n for n in names if n in ("EXEC_ARMED", "EVMC_ALLOW_LIVE", "FUEL_REFUEL_MODE")]
    r.note("arm-relevant names present: %s" % (arm_flags or "none"))
    r.ok("exec.env key inventory read (%d names)" % len(names))
else:
    r.unknown("exec.env unreadable or holds no KEY= lines (%s)" % err)

kill = os.path.join(root, "data/KILL")
if os.path.exists(kill):
    r.bad("KILL switch file PRESENT at %s" % kill)
else:
    r.ok("no KILL switch file (not killed)")
r.finish()
PY
bump_rc $?

# ------------------------------------------------------- 4. encrypted store
section "4. ENCRYPTED STORE (lives on zephyr — reported as absent-in-place, not missing)"
"$PY" - <<'PY'
import os
import socket
import subprocess
import _probe_lib as pl
r = pl.Report("secrets-store")
store = os.environ.get("SECRETS_STORE", os.path.expanduser("~/Work/Projects/nixos-secrets"))
here = socket.gethostname()
if not os.path.isdir(store):
    # The store lives on zephyr, which is a WORKSTATION: nothing is installed, copied
    # or left there, and this script is never placed on it. So the store is inventoried
    # READ-ONLY over ssh from here instead — no file is created on the remote host.
    remote = os.environ.get("SECRETS_STORE_HOST", "zephyr")
    r.note("no local store tree at %s on %s" % (store, here))
    # Filter and count SERVER-SIDE. Piping a truncated listing home and filtering it
    # there reports a false zero whenever the interesting files sit past the truncation
    # point (the store's .git objects sort first, and they are 40+ of the 132 files) —
    # the exact silent-zero trap this suite exists to prevent.
    remote_cmd = (
        "printf 'TOTAL=%%s\\n' \"$(find %s -maxdepth 3 -type f -not -path '*/.git/*' "
        "2>/dev/null | wc -l)\"; find %s -maxdepth 3 -type f -not -path '*/.git/*' "
        "-printf '%%s %%m %%p\\n' 2>/dev/null "
        "| grep -iE 'keypair|exec|a2a|trading|alchemy|helius|rhc|sol|devnet' | head -20"
    ) % (store, store)
    probe = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                            remote, remote_cmd], capture_output=True, text=True)
    total, rows = None, []
    for line in probe.stdout.splitlines():
        if line.startswith("TOTAL="):
            total = line.split("=", 1)[1].strip()
        elif line.strip():
            rows.append(line.split(None, 2))
    if probe.returncode != 0 or total is None:
        r.unknown("store not local, and %s reported none: %s"
                  % (remote, probe.stderr.strip()[:110] or "empty reply"))
    else:
        r.note("read-only remote inventory on %s: %s file(s) excl. .git, %d custody-related "
               "(counted and filtered on that host)" % (remote, total, len(rows)))
        for size, mode, path in rows[:12]:
            r.note("   %-56s size=%-7s mode=%s" % (path.replace(store, "..."), size, mode))
        if rows:
            r.ok("store inventory: %d custody file(s) on %s (nothing copied to or written "
                 "on that host)" % (len(rows), remote))
        else:
            r.unknown("0 custody files matched on %s out of %s file(s) — confirm the filter "
                      "still matches the store's layout" % (remote, total))
else:
    total = 0
    for sub in ("secrets/infra", "secrets/ai"):
        d = os.path.join(store, sub)
        if not os.path.isdir(d):
            r.note("%s: absent" % sub)
            continue
        names = sorted(os.listdir(d))
        total += len(names)
        hits = [n for n in names
                if any(w in n.lower() for w in ("keypair", "exec", "a2a", "trading",
                                                "alchemy", "helius", "rhc", "sol", "devnet"))]
        r.note("%s: %d entries, %d custody-related" % (sub, len(names), len(hits)))
        for n in hits[:12]:
            path = os.path.join(d, n)
            st = os.stat(path)
            r.note("   %-40s size=%-7d mode=%04o" % (n, st.st_size, st.st_mode & 0o777))
    if total:
        r.ok("store has %d entries (names/sizes only — contents are encrypted)" % total)
    else:
        r.unknown("store tree exists but is empty")
r.finish()
PY
bump_rc $?

# ------------------------------------------------------- 5. reconcile balances
section "5. RECONCILE RAILS: real field names + balances"
"$PY" - <<'PY'
import os
import _probe_lib as pl
r = pl.Report("reconcile-balances")
root = os.environ.get("TRADING_ROOT", os.path.expanduser("~/Work/trading"))
for fname in ("reconcile.jsonl", "reconcile_evm.jsonl"):
    rows, note = pl.jsonl_rows(os.path.join(root, "data", fname))
    if rows is None:
        r.unknown("%s: %s" % (fname, note))
        continue
    if not rows:
        r.unknown("%s: no parseable rows (%s)" % (fname, note))
        continue
    last = rows[-1]
    r.note("%s rows=%d" % (fname, len(rows)))
    pl.show_fields(r, fname, last)
    # print every field of the newest row so a guessed name cannot hide a real one
    for key, value in sorted(last.items()):
        sval = str(value)
        if len(sval) > 88:
            sval = sval[:88] + "…"
        r.note("     %-22s %s" % (key, sval))
    r.ok("%s newest row read with %d fields" % (fname, len(last)))
r.finish()
PY
bump_rc $?

finish
