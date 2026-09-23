#!/usr/bin/env python3
"""scripts/verify/rotation_exposure_check.py

Value-based secret-exposure test: are the live API keys actually present in the files
and git history that used to leak them? Answers "is there a real reason to rotate?"
with counts.

NEVER PRINTS A SECRET. Each candidate is reported as `source:NAME  len=N  sha256=<12 hex>`
— a fingerprint, so you can tell two runs refer to the same value without the value
appearing anywhere in this script's output, logs or argv-on-disk.

WHY THIS SCRIPT LOOKS PARANOID: an earlier iteration of this check reported
`value_matches=0` for every file, which read as "clean". It was meaningless — the
extraction step had returned an empty needle set, so zero files were ever searched.
A zero from an empty haystack or an empty needle set is not evidence. This version
refuses to report a clean result unless it can first prove the machinery works:

  POSITIVE CONTROL — every extracted value is searched for in the file it was read
  FROM. A key that cannot be found in its own source means extraction/matching is
  broken, and the whole run aborts INCONCLUSIVE (exit 2) instead of printing zeros.
  Haystack guards — a target file that is absent or zero-length is INCONCLUSIVE for
  that file, not "0 matches"; sizes are printed next to counts for the same reason.
  Schema drift — the pattern check prints its alternative count and the byte size it
  searched, so a real zero is distinguishable from a broken regex.

Merges /tmp/rotation_case3.py (already value-based and non-leaking) and supersedes
/tmp/rotation_case.sh and /tmp/rotation_case2.sh. rotation_case2.sh must NOT be
reinstated: it wrote candidate key VALUES into /tmp/.k1, /tmp/.k2, /tmp/.k3 and only
cleaned them up on the happy path.

READ-ONLY: opens files, runs `git log` and `stat`. It writes nothing, and it deletes
nothing.
HOST: nexus (~/Work/trading). cwd: anywhere (TRADING_ROOT overrides).
KNOWN LIMITATION: `git log -S <needle>` takes its needle as an argv, so a key value is
briefly visible in this host's process table while the history scan runs. That is
git's own interface, not a choice made here (git grep -f would need every blob of
every revision). Run this on the single-user host that already holds the key files.
FAILURE LOOKS LIKE: exit 2 (INCONCLUSIVE) when the positive control fails or a target
file is empty — investigate before believing any "0 matches"; exit 1 when a value is
found in a file or in git history, which is a real exposure.
"""
import hashlib
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _probe_lib as pl  # noqa: E402

ROOT = os.environ.get("TRADING_ROOT", os.path.expanduser("~/Work/trading"))

# Where a live key might legitimately live on this host (read to build the needle set).
SOURCES = (
    ("data/keys/alchemy.txt", "alchemy.txt"),
    ("data/keys/helius.txt", "helius.txt"),
    ("data/exec.env", "exec.env"),
)

# Files that previously leaked key material.
TARGETS = (
    "data/daemon.log",
    "data/exec_log.jsonl",
    "data/exec_status.json",
    "data/swap_fidelity.json",
    "data/reconcile.jsonl",
)

# Shape-based sweep, reported with its own byte count so a zero is trustworthy.
PATTERN = re.compile(r"(alchemy|helius|api-key=|/v2/[A-Za-z0-9_\-]{20,})", re.I)

# Backups/timers that must NOT be shipping the trading tree off-host.
BACKUP_DIRS = ("/usr/local/bin", "/etc/systemd/system")


def fingerprint(value):
    return hashlib.sha256(value.encode()).hexdigest()[:12]


def extract_candidates(report):
    """Needle set: value -> (label, source_file). Never printed, only fingerprinted."""
    found = {}
    for rel, label in SOURCES:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            report.note("source absent: %s" % rel)
            continue
        size = os.path.getsize(path)
        try:
            body = open(path, errors="replace").read()
        except Exception as exc:
            report.note("source unreadable: %s (%s)" % (rel, exc))
            continue
        report.note("source %-22s %d bytes, mode=%04o"
                    % (rel, size, os.stat(path).st_mode & 0o777))
        for line in body.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", line)
            if not match:
                continue
            name, value = match.group(1), match.group(2).strip().strip('"').strip("'")
            if len(value) >= 16 and not value.startswith("http"):
                found[value] = ("%s:%s" % (label, name), path)
            if value.startswith("http") and "/v2/" in value:
                tail = value.split("/v2/")[-1].split("?")[0]
                if len(tail) >= 16:
                    found[tail] = ("%s:%s:pathseg" % (label, name), path)
    return found


def main():
    report = pl.Report("rotation-exposure")
    report.note("root=%s" % ROOT)
    if not os.path.isdir(ROOT):
        report.unknown("TRADING_ROOT=%s does not exist on this host" % ROOT)
        report.finish()

    # ---------------------------------------------------------------- needles
    report.section("1. NEEDLE SET (names, lengths and fingerprints only — never values)")
    candidates = extract_candidates(report)
    if not candidates:
        report.unknown("extraction produced ZERO candidate values — any '0 matches' "
                       "result below would be meaningless, so none is reported")
        report.finish()
    for value, (label, _src) in sorted(candidates.items(), key=lambda kv: kv[1][0]):
        report.note("%-34s len=%-4d sha256=%s…" % (label, len(value), fingerprint(value)))
    report.ok("extracted %d candidate value(s)" % len(candidates))

    # ---------------------------------------------------------------- control
    report.section("2. POSITIVE CONTROL — each value must be found in its own source")
    control_failures = 0
    for value, (label, src) in sorted(candidates.items(), key=lambda kv: kv[1][0]):
        try:
            body = open(src, errors="replace").read()
        except Exception as exc:
            report.unknown("control: cannot re-read %s (%s)" % (src, exc))
            control_failures += 1
            continue
        hits = body.count(value)
        if hits:
            report.ok("control: %s found in its own source (%d occurrence(s))"
                      % (label, hits))
        else:
            report.bad("control: %s NOT found in its own source %s — extraction/matching "
                       "is broken, distrust every count below" % (label, src))
            control_failures += 1
    if control_failures:
        report.unknown("positive control failed for %d value(s) — aborting rather than "
                       "reporting misleading zeros" % control_failures)
        report.finish()

    # ---------------------------------------------------------------- files
    report.section("3. VALUE OCCURRENCES in the files that previously leaked")
    report.note("targets are appended to live by the daemon, so byte counts can differ "
                "between passes; the size printed next to each count is what was searched")
    for rel in TARGETS:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            report.unknown("%s: absent — cannot claim it is clean" % rel)
            continue
        size = os.path.getsize(path)
        if size == 0:
            report.unknown("%s: zero-length — 0 matches would be vacuous" % rel)
            continue
        body = open(path, errors="replace").read()
        counts = {label: body.count(value)
                  for value, (label, _s) in candidates.items() if body.count(value)}
        total = sum(counts.values())
        report.note("%-26s bytes=%-9d value_matches=%d %s"
                    % (rel, size, total, counts if counts else ""))
        if total:
            report.bad("%s still contains %d key occurrence(s): %s" % (rel, total, counts))
        else:
            report.ok("%s carries no candidate value (searched %d bytes)" % (rel, size))

    report.banner("shape-based sweep (same files, pattern with its alternative count)")
    for rel in TARGETS:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            report.note("%-26s absent" % rel)
            continue
        body = open(path, errors="replace").read()
        hits = PATTERN.findall(body)
        report.note("%-26s bytes=%-9d pattern_hits=%d %s"
                    % (rel, len(body), len(hits), sorted({h[0].lower() for h in hits})))

    # ---------------------------------------------------------------- git
    report.section("4. GIT HISTORY — did any value ever reach a commit?")
    if not os.path.isdir(os.path.join(ROOT, ".git")):
        report.unknown("no .git at %s" % ROOT)
    else:
        head = subprocess.run(["git", "-C", ROOT, "rev-list", "--all", "--count"],
                              capture_output=True, text=True)
        if head.returncode != 0:
            report.unknown("git unavailable in %s: %s" % (ROOT, head.stderr.strip()[:120]))
        else:
            report.note("revisions reachable from all refs: %s" % head.stdout.strip())
            for value, (label, _src) in sorted(candidates.items(), key=lambda kv: kv[1][0]):
                try:
                    proc = subprocess.run(
                        ["git", "-C", ROOT, "log", "--all", "--oneline", "-S", value],
                        capture_output=True, text=True, timeout=300)
                except Exception as exc:
                    report.unknown("git log -S for %s failed: %s" % (label, exc))
                    continue
                if proc.returncode != 0:
                    report.unknown("git log -S rc=%d for %s: %s"
                                   % (proc.returncode, label, proc.stderr.strip()[:120]))
                    continue
                commits = [ln for ln in proc.stdout.splitlines() if ln.strip()]
                if commits:
                    report.bad("%s appears in %d commit(s)" % (label, len(commits)))
                    for line in commits[:4]:
                        report.note("     %s" % line)
                else:
                    report.ok("%s never appears in git history" % label)
            # Shape sweep. A pattern like `api-key=` is generic: it matches docs,
            # env-var references and curl examples as readily as a leak. It is only an
            # exposure if a token of LIVE-KEY LENGTH rides along with it, so the
            # threshold is derived from the keys actually extracted above (measured
            # evidence) rather than a magic number. Matching text is measured and
            # fingerprinted, never printed.
            min_live_len = min(len(v) for v in candidates)
            report.note("live-key lengths: %s — a token shorter than %d chars cannot be "
                        "one of them"
                        % (sorted({len(v) for v in candidates}), min_live_len))
            for pattern in ("api-key=", "AKIA", "ACCESS_KEY"):
                proc = subprocess.run(
                    ["git", "-C", ROOT, "log", "--all", "--oneline", "-S", pattern],
                    capture_output=True, text=True, timeout=300)
                if proc.returncode != 0:
                    report.unknown("git log -S '%s' rc=%d" % (pattern, proc.returncode))
                    continue
                shas = [ln.split()[0] for ln in proc.stdout.splitlines() if ln.strip()]
                if not shas:
                    report.ok("pattern '%s' absent from history" % pattern)
                    continue
                shaped, longest = [], 0
                for sha in shas[:8]:
                    diff = subprocess.run(
                        ["git", "-C", ROOT, "show", "--format=", "--unified=0", sha],
                        capture_output=True, text=True, timeout=120).stdout
                    for line in diff.splitlines():
                        if not line.startswith(("+", "-")) or pattern.lower() not in line.lower():
                            continue
                        for tok in re.findall(r"[A-Za-z0-9_\-]{%d,}" % min_live_len, line):
                            shaped.append((tok, sha))
                        for tok in re.findall(r"[A-Za-z0-9_\-]{8,}", line):
                            longest = max(longest, len(tok))
                if shaped:
                    report.bad("pattern '%s' appears in %d commit(s) WITH %d token(s) of "
                               "live-key length (>=%d chars): len=%d sha256=%s… in %s"
                               % (pattern, len(shas), len(shaped), min_live_len,
                                  len(shaped[0][0]), fingerprint(shaped[0][0]),
                                  shaped[0][1][:8]))
                else:
                    report.note("pattern '%s' in %d commit(s) but the longest token-shaped "
                                "string is %d chars (< %d = shortest live key) — not a "
                                "live-key exposure" % (pattern, len(shas), longest, min_live_len))

    # ---------------------------------------------------------------- backups
    report.section("5. OFF-HOST BACKUP SCOPE — does anything ship the trading tree?")
    hits = []
    for base in BACKUP_DIRS:
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            path = os.path.join(base, name)
            if not os.path.isfile(path) or os.path.getsize(path) > 200_000:
                continue
            try:
                body = open(path, errors="replace").read()
            except Exception:
                continue
            if "Work/trading" in body or "trading/data" in body:
                tools = sorted(set(re.findall(r"aws|s3://[^\s\"']+|rclone|rsync|tar", body)))[:4]
                hits.append((path, tools))
    if hits:
        for path, tools in hits:
            report.note("%s  %s" % (path, tools))
        report.bad("%d backup/timer file(s) reference the trading tree" % len(hits))
    else:
        report.ok("no backup script in %s references the trading tree"
                  % ", ".join(BACKUP_DIRS))

    rustfs = "/usr/local/bin/backup-to-rustfs.sh"
    if os.path.exists(rustfs):
        st = os.stat(rustfs)
        body = open(rustfs, errors="replace").read()
        creds = len(re.findall(r"(ACCESS|SECRET)[A-Z_]*\s*=", body))
        report.note("%s mode=%04o uid=%d size=%d hardcoded_credential_lines=%d"
                    % (rustfs, st.st_mode & 0o777, st.st_uid, st.st_size, creds))
        if creds and (st.st_mode & 0o777) & 0o077:
            report.bad("%s carries %d hardcoded credential line(s) AND is readable "
                       "beyond its owner (mode=%04o)"
                       % (rustfs, creds, st.st_mode & 0o777))
        elif creds:
            report.note("%s carries %d hardcoded credential line(s) but is owner-only "
                        "(mode=%04o)" % (rustfs, creds, st.st_mode & 0o777))
        else:
            report.ok("%s holds no hardcoded credentials; mode=%04o alone is not a finding"
                      % (rustfs, st.st_mode & 0o777))
    else:
        report.note("%s absent" % rustfs)

    report.finish()


if __name__ == "__main__":
    main()
