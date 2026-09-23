# scripts/verify — reproducible verification

Verification tools for the trading system, the k3s cluster, secrets custody and model
serving. They exist so a claim like "the reconcile rails are fresh", "the cluster-shadow
writer is alive" or "no key reached git" can be **re-run tomorrow** instead of being
anecdotal — and so a run that proves nothing cannot be mistaken for a clean one.

**These are verification tools, not fixers. None of them mutates state.**

## The contract every script in here keeps

1. **Read-only by default.** sqlite is opened `mode=ro` with `busy_timeout=20000` (the
   live ledger holds a write lock during cycles, and a plain connect can raise
   `database is locked` — which is easy to mistake for "no data"). kubectl is used for
   `get`/`logs` only — never `apply`/`delete`/`exec`/`patch`. Nothing writes to disk.
2. **Never prints a secret value.** Key material is described by mode/uid/size/readability
   and a `sha256` **fingerprint** (first 12 hex chars) plus value length — enough to tell
   whether two runs saw the same value, without the value appearing in output or logs.
3. **Assert non-empty input before reporting anything clean.** A zero produced by an
   extractor that returned nothing is not evidence. Empty input, an absent file or a
   vanished column is `INCONCLUSIVE`, and `INCONCLUSIVE` exits non-zero.
4. **Print the field names it found.** Real schemas here disagree with each other
   (`cluster_shadow.jsonl` carries `event_ts`/`recorded_ts` and has no `ts` at all;
   the SOL rail has `logged_count`/`onchain_count`, not `logged`/`onchain`). Every
   JSONL/DB read echoes the row's field names the first time, so schema drift shows up
   as drift instead of as a silent zero or a false "stale" verdict.

### Failure vocabulary

| Marker | Exit | Meaning |
| --- | --- | --- |
| `[PASS]` | — | Assertion evaluated and held. |
| `[FAIL]` | 1 | Assertion evaluated and did **not** hold — a real finding. |
| `[INCONCLUSIVE]` | 2 | Could not evaluate: empty/absent input, unexplainable cadence, schema drift. **Not** a clean result. |
| `RESULT: OK` | 0 | Every section was evaluated and held. |

A single run's exit code is the worst outcome: `2 > 1 > 0`. `run_all.sh` aggregates the
same way, so `... | run_all.sh; echo $?` is a usable gate.

**Zephyr is a workstation.** Nothing in this directory is installed, copied or left on
zephyr, and no script here is run *from* zephyr. Anything that must be observed there
(the encrypted store, the host timer list) is read **read-only over ssh from nexus**.

## Scripts

Run from **nexus** unless noted (`~/Work/trading` for data, kubectl for the cluster).
`cwd` does not matter — each script resolves its own directory and takes
`TRADING_ROOT` (default `~/Work/trading`), `SECRETS_STORE` (default
`~/Work/Projects/nixos-secrets`) and `OPS_REPO` (default `~/homelab-ops`) from the env.

| Script | What it asserts | Host / cwd | Read-only? | What a failure looks like |
| --- | --- | --- | --- | --- |
| `run_all.sh` | Runs every script below in order; one line each; aggregates the worst rc. | nexus, any cwd | yes | `rc=1`/`rc=2` in the summary table |
| `cluster_snapshot.sh` | Every node condition *type* with its own status; Argo apps all `Synced`+`Healthy`; no pods outside Running/Succeeded; trading+mining pods ready; `/data/media` < 90%; firing alerts with the labels that say what they are about; failed jobs; SMART wear device attribution; halt/KILL state; GMGN feed freshness. | nexus, any cwd | yes | `[FAIL] node X Ready=False`, `apps not Synced+Healthy: [...]`, `N pod(s) not Running`, `N firing alert series` |
| `cluster_shadow_freshness.sh` | The cluster-shadow **writer is alive** (heartbeat age vs its own `interval_s`, and the owning pod is Running) and the artifact's cadence is judged on the correct clock. | nexus, any cwd | yes | `WRITER STALE: heartbeat N min old` / `owner pod ... phase=Pending`; `[INCONCLUSIVE]` if the heartbeat or all timestamps are missing |
| `tracking_surfaces.sh` | The three fund-tracking surfaces agree: wallet feed self-report (`ok`, fetched==wallets, age vs interval) **and** non-zero `quote_amount`s; both reconcile rails fresh with `drift=0`, and their CronJobs actually fired; the `[WALLETS]` log line exists. | nexus, any cwd | yes | `ALL of the last N quote_amount values are zero`, `reconcile.jsonl drift=…`, `[WALLETS] line NOT present` |
| `lab_probe.py` | Collector `runs` is non-empty and every expected source (`trending`, `trenches`, `signal`, `sm_trades`, `kol_trades`, `watchlist`) is arriving and fresh; `trenches:near_completion` is no longer discarded; extraction-drop faults are surfaced. | nexus, any cwd | yes | `expected source X is missing from runs`, `source X last ran N min ago`, `near_completion has ZERO rows while new_creation has N` |
| `rotation_exposure_check.py` | Whether the live keys appear in the files that used to leak them, in git history, or in any off-host backup scope — with a **positive control** so zeros cannot be vacuous. | nexus, any cwd | yes (reads + `git log`) | `[FAIL] <file> still contains N key occurrence(s)`, `<label> appears in N commit(s)`, `N backup/timer file(s) reference the trading tree`; `[INCONCLUSIVE]` if the positive control fails |
| `wallet_custody_inventory.sh` | Host reachability; key-file mode/owner/size/readability+fingerprint; arm state (`exec_status.json`, `exec.env` names, KILL file); the encrypted store (reported absent-in-place off zephyr); both rails' newest row with real field names. | nexus, any cwd (the zephyr store is read over ssh, never by running anything there) | yes | `mode=0644 is readable beyond the owner`, `KILL switch file PRESENT`, `exec is ARMED` |
| `autonomy_audit.sh` | Status summary; every CronJob's `lastSuccessfulTime` age vs the cadence its own schedule implies (does it fire without me?); stray host timers; the system's own gate set; unaided activity in the last hour per artifact *with the timestamp field it used*; docs/CHANGELOG/commit freshness. | nexus, any cwd | yes¹ | `cronjob X has NEVER succeeded`, `X last success N min ago but cadence is M min`, `stray host timers present`, `gates-autonomy.sh exit=1` |
| `silent-failure-sweep.sh` | The silent-failure class: a job/collector/reporter/gate that reports success while producing nothing, or reads a stale/absent source as current. 54 CronJobs (never-succeeded, success older than 2 periods of its own schedule, `lastScheduleTime` missing while `lastSuccessfulTime` is set, suspended/impossible schedules, `failedJobsHistoryLimit: 0`); trading feed registry (mtime **and** last row `ts`); quill ingest ledger (`records == 0` while `runs > 0`); hermes cron (non-`ok` last run, late dispatch, empty output dir); backup units (`Result != success`, stalled, duplicate system+user timers); producer metrics missing from VictoriaMetrics. | nexus, any cwd | yes² | `cronjob X has NEVER succeeded`, `D4 zero-payload-ingest quill:gazette`, `D8 backup-failed media-config-backup`, `D3b no-metrics peakminer_*` |

² `silent-failure-sweep.sh` reads two things that exist only inside pods with
`kubectl exec` — the quill ingest ledger (`cat`) and the in-cluster metric/rule index
(`wget` against VictoriaMetrics/vmalert). Never `apply`/`delete`/`patch`/`scale`;
no pod is created and nothing is mutated.

¹ `autonomy_audit.sh` section B3 shells out to the trading repo's own
`scripts/gates-autonomy.sh` (the strongest available evidence), which runs pytest. It is
invoked with `PYTHONDONTWRITEBYTECODE=1 PYTEST_ADDOPTS="-p no:cacheprovider"` so it
leaves no `.pytest_cache` behind. Set `VERIFY_SKIP_GATES=1` to skip B3 entirely.

### Usage

```bash
# the whole set, from nexus
ssh nexus 'bash ~/homelab-ops/scripts/verify/run_all.sh'; echo "rc=$?"

# one at a time
ssh nexus 'bash ~/homelab-ops/scripts/verify/cluster_shadow_freshness.sh'
ssh nexus 'python3 ~/homelab-ops/scripts/verify/lab_probe.py'
# the encrypted store (on zephyr) is inventoried READ-ONLY over ssh from nexus;
# nothing is ever copied to or installed on zephyr (fleet rule: workstation only)
ssh nexus 'bash ~/homelab-ops/scripts/verify/wallet_custody_inventory.sh' 

# skip the delegated gate run in a noisy context
ssh nexus 'VERIFY_SKIP_GATES=1 bash ~/homelab-ops/scripts/verify/autonomy_audit.sh'
```

## Provenance: what each file came from (2026-09-22 /tmp scripts)

These scripts were written during one session of verifying ~20 fixes and lived only in
`/tmp` on nexus and zephyr. Collected here, de-duplicated, and hardened. The `/tmp`
copies were byte-identical on both hosts except `wallets_final.sh`, which existed only
on zephyr.

| Origin in `/tmp` | Landed as | Note |
| --- | --- | --- |
| `state_snapshot.sh`, `state_snapshot2.sh` | `cluster_snapshot.sh` | Two iterations of one snapshot; the second existed only because the first mislabelled a node-condition column. Merged, and conditions are now printed per type. |
| `check_shadow_timers.sh` | `cluster_shadow_freshness.sh` | **Corrected.** Its earlier verdict ("7.6h stale") came from reading `event_ts` — the *event* clock, which lags by design — while the writer's heartbeat was fresh. Now prints every clock, names the one it judged on, and separates writer liveness from artifact cadence. |
| `verify_tracking.sh` | `tracking_surfaces.sh` | **Corrected.** It globbed `data/*wallet*` expecting JSONL, but the feed is `wallet_feed.json`, so its wallet section printed nothing and read as clean; and it probed reconcile fields (`logged`/`onchain`/`missing`) that do not exist on the SOL rail. |
| `lab_check3.py`, `lab_check4.py`, `lab_check5.py` | `lab_probe.py` | Three fragments of one probe, each opening the same 554 MB DB. Merged into one read-only connection. |
| `rotation_case3.py` | `rotation_exposure_check.py` | Already value-based and non-leaking; hardened with a positive control and haystack guards. |
| `rotation_case.sh`, `rotation_case2.sh` | *(superseded by the above)* | **Do not reinstate `rotation_case2.sh`**: it wrote candidate key **values** into `/tmp/.k1`, `/tmp/.k2`, `/tmp/.k3` and only removed them on the happy path. `rotation_case.sh`'s file scan could report `0 matches` from an empty extractor. |
| `access_wallets.sh`, `wallets_final.sh` | `wallet_custody_inventory.sh` | The second existed because the first looked for the encrypted store on the wrong host, and it printed guessed reconcile field names (`wallet`, `balance`, `chain_id`, `head`) that exist on neither rail. Merged, field names echoed from the row actually read. |
| `status_autonomy_docs.sh` | `autonomy_audit.sh` | Also fixed a stale path: its commit count read `~/Work/Projects/homelab-ops`, the stale second checkout, instead of the canonical `~/homelab-ops`. |

No script here duplicates anything already in `homelab-ops/scripts/`:
`verify-infomarchy-fleet.sh` covers the Infomarchy desk, `preflight-check.sh` covers
local rebuild readiness, `cluster-watchdog.sh`/`watcher-watchdog.sh` are daemons that
*act*, and `tests/*` are CI tests. Nothing in the repo previously read the trading
system's ledgers or the cluster-shadow artifacts.

## Relation to the other script in this directory

`silent-failure-sweep.sh` (added independently) hunts the same underlying failure class
from the other direction: a generic sweep for jobs/gates that report success while
producing nothing, using a `verdict | section | item | signal | expected` table with
verdicts `OK` / `FINDING` / `NOTE` / `GUARD-FAIL` and exit codes **0 / 1 / 3**. The scripts
here are per-surface verifications of named artifacts (the tracking surfaces, the lab
ledger, the shadow writer, custody, exposure, the cluster snapshot). They are
complementary, not duplicates — no route, query or assertion is shared.

Two vocabularies now live in one directory, so for the avoidance of doubt:

| This set | `silent-failure-sweep.sh` | Meaning |
| --- | --- | --- |
| `[PASS]`, exit 0 | `OK`, exit 0 | evaluated and held |
| `[FAIL]`, exit 1 | `FINDING`, exit 1 | evaluated and did not hold |
| `[INCONCLUSIVE]`, exit 2 | `GUARD-FAIL`, exit 3 | could not be evaluated — never a clean pass |

Both encode the same rule: an empty input is never reported as healthy. The exit codes
differ (2 vs 3), which is worth unifying if a caller ever chains the two.

## Adding a script here

- Source `_lib.sh` (bash) or `import _probe_lib` (python) rather than re-implementing
  read-only sqlite, timestamp detection or the status vocabulary.
- Assert non-empty before any clean verdict; print field names on first read of a
  JSONL/DB; never echo a secret value (fingerprint/length instead).
- Use only `kubectl get`/`logs`, `mode=ro` sqlite, plain reads, and `git log`/`diff`.
  If a step can write, gate it behind an explicit env flag and document it in the table.
- Document it in the table above: what it asserts, host/cwd, read-only, and what a
  failure looks like.