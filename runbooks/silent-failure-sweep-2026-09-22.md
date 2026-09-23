# Silent-failure sweep — 2026-09-22

**The one class this hunts:** a job, collector, reporter or gate that reports
**success while producing nothing**, or that **reads a stale / absent source as if
it were current**.

Four instances of it were found today by looking at specific things (a GMGN feed
with `ok=1 items=0` for 413 runs, a watchdog with no CronJob, a release-gate input
69 h stale, a wallet feed serving a 6-day cache behind a live-looking counter).
This sweep is the systematic pass: *apply the class as a rule, across every
namespace, and leave the rule behind as a script.*

Re-runnable:

```bash
# on nexus (canonical repo checkout)
/home/j_kro/homelab-ops/scripts/verify/silent-failure-sweep.sh          # cluster + nexus
/home/j_kro/homelab-ops/scripts/verify/silent-failure-sweep.sh --hosts  # + ssh host probes
```

Read-only. Exit `0` = OK, `1` = at least one `[FAIL]`, `2` = **INCONCLUSIVE** (a guard
failed: an empty input is never reported as clean, which is the whole point). Worst-wins,
same vocabulary and codes as the rest of `scripts/verify/`, and it is registered in
`scripts/verify/run_all.sh`.

**Never install or schedule this on zephyr** — zephyr is a workstation (fleet rule).
The canonical checkout is nexus.

---

## 1. The detection rule

| # | Rule | Signal | A finding looks like |
|---|------|--------|----------------------|
| D1 | never-succeeded | `CronJob.status.lastSuccessfulTime` absent, job older than 2 periods | a scheduled producer that has never once produced |
| D2 | stale-success | `lastSuccessfulTime` older than 2 periods (per its own schedule) | a green status that no longer means anything |
| D3 | stale / absent producer | file mtime **and** last-row `ts` older than 2× cadence | a feed frozen while its writer exits 0 |
| D3b | no metrics, no rule | producer has 0 series in VictoriaMetrics | a workload whose death is invisible |
| D4 | zero-payload ingest | run counter advances, `records == 0`, `failures == 0` | "found 41, ingested 0, ✅ complete" |
| D5 | schedule-missed / smoke-job | `lastScheduleTime` missing while `lastSuccessfulTime` is set; or scheduler 2+ periods behind | health that only a *manual* smoke job ever produced |
| D6 | suspended / hides-failures | `suspend: true` or an impossible schedule (`0 0 31 2 *`); `failedJobsHistoryLimit: 0` | a producer that cannot run, be checked, or leave a failure behind |
| D7 | scheduler row without a result | Hermes cron `ok` with an empty output dir, a non-`ok` last status, or a late dispatch | "exit 0" as a substitute for a result |
| D8 | backup failure unread | unit `Result != success`, or a stall watchdog whose unit list is shorter than the host's backup list, or the same timer in system **and** user scope | a backup nobody can restore, reported by nobody |

The script prints these field names on every line so the vocabulary is visible
when it runs:
`verdict | section | item | signal | expected`   (`verdict` = `PASS | FAIL | NOTE | INCONCLUSIVE`).

Two controls prove the sweep itself is not vacuous: with `TRADING_DATA=/nonexistent` it
exits `2` / `INCONCLUSIVE` instead of clean, and the quill/backup/metric sections each
carry a positive and a negative fixture in `tests/test-backup-failure-visibility.sh`.

---

## 2. Sweep results (including the clean rows — coverage, not just alarms)

### k3s CronJobs — 54 total, every namespace

| verdict | item | signal |
|---|---|---|
| OK (46) | all `trading/*` jobs except the notes below; `maplespike/quill-ingest-*` (7); `media/jellyfin-backup`; `longhorn-system/daily-snapshot`, `weekly-backup`; `activepieces/activepieces-postgres-backup` | `lastSuccessfulTime` within 2 periods of its own schedule |
| NOTE D5 | `activepieces-postgres-backup`, `longhorn-system/weekly-backup`, `trading/trading-gmgn-portfolio`, `trading/trading-weekly-report` | `lastSuccessfulTime` set, `lastScheduleTime` **absent** = a manual `create job --from=cronjob` smoke run. The status field is not proof the scheduler works. |
| NOTE D6 | `media/dedup-sweep`, `media/trash-reclaim`, `trading/trading-recal` | never ran; created *after* their weekly slot — first fire is due, not missing |
| NOTE D6 | `trading/trading-image-build`, `trading/trading-image-import` | `suspend: true` + schedule `0 0 31 2 *` (Feb 31) — manual-only by design; can never fail or alert |
| NOTE D6 | `longhorn-system/daily-snapshot`, `weekly-backup` | `failedJobsHistoryLimit: 0` — a failed run evicts its own Job and leaves no trace |

### Host-level schedulers (nexus, system + user scope)

| verdict | item | signal |
|---|---|---|
| OK | 13 Hermes cron jobs (model-health-daemon, rate-limit-watcher, watcher-watchdog, media-mcp-health, oncall-responder, shadow-verdict-alert, k3s-arr-stack-heal, model-chain-daily-probe, model-chain-weekly-audit, stack-sentinel, trading-digest, pipeline-driver) | last run `ok`, dispatch on time, non-empty output |
| NOTE D7 | `consolidate-lessons` | never due yet (weekly, no output dir contents) — no verdict until first run |
| OK | `s3-freshness.timer` (k3s etcd snapshots → Garage), `canary-watch.timer`, `rhc-canary-watch.timer`, `fleet-verify.timer`, `smartmon-textfile.timer`, `oracle-idle-watch.timer` (sentry), `backup-stall-watchdog.timer` | last trigger within its interval |
| OK | `trading-refresh.timer` (weekly research refresh), `btrfs-scrub.timer` | weekly/monthly: next elapse in the future, last run present |

### Data producers — content, not just exit codes

| verdict | item | signal |
|---|---|---|
| OK | 9 trading feeds (`gmgn_flow/track/sec/portfolio`, `curve_watch`, `rhc_prices`, `equity_curve`, `portfolio_series`, `owner_queue`) | mtime **and** last-row `ts` inside 2× cadence (equity 0.2 m, gmgn_track 2.0 m) |
| OK | `trading_last_cycle_timestamp` (VictoriaMetrics, job `trading-daemon`) | 97 s old |
| OK | `quill:ngo-influence-rss` (94 records/91 runs), `quill:probe-cos` | records advancing |
| OK | `media/jellyfin-backup` → `jellyfin-config-*.tar.gz`, keep 4 | last archive written by the 09-20 run |
| OK | 302 vmalert rules | `health: ok` for all; 6 firing (Watchdog, DiskSpaceLow, NodeDiskIOSaturation, SmartWearHigh, RecordingRulesNoData, InfoInhibitor-family) |
| **FINDING** | **5 quill ingest modules** | see §3.1 |
| **FINDING** | **mining fleet metrics** | see §3.2 |

### Coverage that does not exist (the point of the exercise)

| verdict | item | signal |
|---|---|---|
| FINDING | `ai-inference` namespace | **empty** — the namespace AGENTS.md lists as key holds no workloads at all |
| NOTE | 3 of 302 alert rules use `absent()` | "no data" is health for every producer except kube-apiserver, etcd and SMART |
| NOTE | no alert rule references any backup, any ingest pipeline, or any miner | those producers cannot fail loudly by construction |

---

## 3. Findings (new instances, with evidence)

### 3.1 `quill` ingest reports `✅ complete` while persisting zero records — **data-integrity, public surface**
MapleSpike's public data platform ingests on 7 CronJobs, all green. Five of the eight
ledger modules persist **0 records** and the ledger itself says `failures: 0`:

```
quill:{committees,corporate,gazette,influence,oversight}  records=0  failures=0  lastSuccess fresh
quill:real-time-feeds                                     records=5  runs=44
```
Live job logs (the same runs):
- `committees` — `meetingsFound:41, meetingsIngested:0, interventionsIngested:0, speakersFound:0`, `errors:["Meeting #39: Could not find XML export link in evidence HTML…"]`
- `gazette` — `recordsFound:0 recordsIngested:0 errors:["Gazette I: HTTP 404 fetching https://gazette.gc.ca/rp-pr/p1/index.rss"]` (dead source URL)
- `corporate` — `recordsFound:0 recordsIngested:0 errors:["HTTP 403 fetching monthly reports"]`, `globenewswire.com` 400 ×17 in 5 min
- `influence` — `actorsFound:34, connectionsFound:145, fundingFlowsFound:0`, `search.open.canada.ca 404 ×35 in 5 min`
- DB (`/data/quill/maplespike.db`, read-only via `node:sqlite` in the pod): `committee_meetings` 917 rows newest **2025-09-24**, `entity_mentions` 16 534 newest 2025-09-24, `oversight_investigations` **0**, `oversight_recommendations` **0**, `government_funding` **0**.

**Verdict:** the ingest CLI exits 0 and the ledger records success on a run that
writes nothing, so a year-long source-format break reads as healthy. The signature
to fix is `found > 0 && ingested == 0` (and `records == 0` with `runs > 0`).
**Left to the pipeline owner** (see §5.1) — the fix is in the quill repo's ingest
CLI and needs the ingest contract, not a cluster change. Now detected on every
sweep run (D4).

### 3.2 The GPU mining fleet has no metric, no rule and no freshness signal — **money**
5 `peakminer-*` Deployments run across nexus/forge/zephyr (≈ 22–84 TH/s each).
VictoriaMetrics' metric index holds **2 965 names and not one matching
`peakminer_|miner_|hashrate|xmrig`**; the 302-rule set has no miner rule. A miner
that stops submitting shares is invisible everywhere: no scrape, no alert, no row.
**Left (see §5.2)** — needs a scrape target + a share-rate/stale alert; I did not
invent an exporter.

### 3.3 `media-config-backup` failed and nothing read it — **data-integrity — FIXED (live)**
`media-config-backup.service` sat `Result=exit-code`, `ActiveState=failed`,
`ExecMainExitTimestamp=Tue 2026-09-22 12:38:57 CDT` — **10 h unread**. The journal
shows `sync attempt 1…30 failed (…→ s3://media-config/current/); retrying in 90s`
then `Failed with result 'exit-code'`. The stall watchdog deliberately never touches
`failed` units ("mask a real failure"), and nothing else reads failures.
**Fixed by making failure visible** (3.4). The 12:38 failure itself is explained in
`runbooks/control-plane-io-stall-2026-09-22.md`; the next scheduled run is the 04:38
timer, after which the watchdog will report success or failure on its own.

### 3.4 `backup-stall-watchdog` covered 3 of 7 backups by hand-written list — **FIXED, tested**
`UNITS=(stampede-backup media-config-backup haven-backup)` — `memlawb-backup`,
`activepieces-backup`, `trading-backup`, `gitlawb-backup` (sentry) had no stall
detection at all, and a failed unit had no reader.
**Fix:** discovery-based (`systemctl list-units --all --type=service` + `*.backup*`
name match) for both the stall scan and the failure scan; failure reporting with
`Result`/timestamp/restarts; a `BackupNotRestorable` alert pushed to the fleet feed
(`nexus:9799`, the receiver vmalert and verify-fleet already use); non-zero exit so
the watchdog's own unit shows `failed`. Proven live on nexus:
```
ALERT: [BACKUP-FAILED] media-config-backup.service (system) Result=exit-code since=Tue 2026-09-22 12:38:57 CDT restarts=0
watchdog: scanned 7 discovered backup unit(s), killed 0 stalled, reported 1 failed
(posted to the fleet alert feed)   EXIT=1
```
Installed to `/usr/local/bin/backup-stall-watchdog` (old copy kept at
`/usr/local/bin/backup-stall-watchdog.bak-2026-09-22`).
Test: `tests/test-backup-failure-visibility.sh` → **23/23 PASS** (PATH-shimmed
systemctl/curl/kubectl; positive, negative, stall and empty-discovery controls).

### 3.5 Two divergent copies of the fleet regression suite — **FIXED, verified**
`nexus` ran the suite twice per 15 min from two different revisions:
- system `fleet-verify.timer` → `/home/j_kro/media-k8s/cluster/checks/verify-fleet.sh` (14 205 B, 09-22)
- user `fleet-verify.timer` → `/home/j_kro/bin/verify-fleet.sh` (9 796 B, 09-21) — **stale**, missing 9d (MetalLB keepalived-VIP ownership), 9e (controller placement) and 9f (SMART telemetry)
Both logged a verdict, so "PASS" meant two different things on the same host.
**Fix:** `~/bin/verify-fleet.sh` is now a shim to the repo copy (original kept as
`verify-fleet.sh.stale-2026-09-22`). Verified: the user unit now logs the three
missing groups (`MetalLB controller off krash3/zephyr PASS`, `SMART telemetry
fresh+healthy 4 hosts, 11 disks`). Redundancy remains (both timers); see §5.4.

### 3.6 The clone that runs every 15 minutes is 40 commits behind — **open**
`/home/j_kro/media-k8s` (the script source the system timer executes) is
`0 ahead / 40 behind origin/main` (`git rev-list --left-right --count HEAD...origin/main`
→ `0  40`). The suite that gates the fleet is not the suite in git — the same drift
class as 3.5, one level up. Not fast-forwarded here: pulling 40 commits changes what
the fleet checks mid-flight and can start failing checks that need host work first.

### 3.7 `mining-scheduler.sh` operated on nothing while reporting success — **FIXED, tested**
The host→deployment map named `xmrig-nexus`, `xmrig-sentry`,
`gpu-miner-forge-amd-0/1`, `gpu-miner-forge-nvidia-0/1`. **None exist** — the fleet is
`peakminer-<host>-<gpu>` Deployments in ns `mining`. `pause` resolved an empty set,
scaled nothing, and printed `✓ Miners paused. State saved to /tmp/mining-paused`.
**Fix:** the cluster is the source of truth (`kubectl get deploy -n mining`, prefix
`peakminer` — never `llama-*`, that is inference); scale is read back and verified;
an empty discovery exits `2` with `no miner Deployments discovered` and no success
line. Covered by the same test file (empty-discovery, non-empty, status).

### 3.8 The build-time mining-pause gates assert retired host units — **open**
`tests/test-local-build-mining-pause.sh` and `...-distributed-builds-mining-pause.sh`
(homelab-ops, Reverb-OS and nixos-config copies) probe `lolminer-nvidia` / `xmrig`:
```
nexus|forge|zephyr: Unit lolminer-nvidia.service could not be found.
nexus|forge|zephyr: Unit xmrig.service could not be found.
```
`compute-workload-monitor` — the mechanism they were testing — also no longer exists.
The scripts exit 0 on `BUILD_EXIT` (the nix build's code) and *suggest* the reader
"check the output above"; a missing unit reads as `stopped`, which is what the test
wants to see. So the gate cannot fail and tests nothing — the same shape as gate G8
asserting the pre-cutover state. **Left** (see §5.5): repoint at
`kubectl get deploy -n mining` replicas during a build, or retire the pair.

### 3.9 A `CronJob` cannot tell a smoke test from a scheduled run — **labelled**
`lastSuccessfulTime` present + `lastScheduleTime` absent = a manually created Job
(`kubectl create job --from=cronjob/...`) that the status counts as a success. 4 jobs
carry it today (§2 table). A gate reading `lastSuccessfulTime` as freshness can be
fooled by the very smoke test used to verify it. The sweep prints it as `NOTE D5`;
nothing else changed.

### 3.10 `ai-inference` namespace is empty — **open**
`kubectl get all -n ai-inference` → *No resources found*, while `Projects/AGENTS.md`
lists it as a key namespace and `ai-inference-gateway` is a maintained repo with a
model-routing contract. Either the workloads moved or the repo is undeployed; a
reader of the docs would believe inference is running.

---

## 4. Clean, deliberately (so the coverage is visible)

- **54 CronJobs**: only the 8 NOTE rows above are not "fresh success within 2 periods"; no never-succeeded job anywhere.
- **Trading**: 9/9 registered feeds fresh by mtime *and* last row ts; `trading-daemon` metrics 97 s old; `trading-*` Hermes jobs and `canary-watch`/`rhc-canary-watch` timers on time; no failure streak reported by `stack-sentinel`.
- **Backups**: memlawb, haven, stampede, activepieces, trading, gitlawb all `Result=success`; `s3-freshness.timer` has both a content check (bucket non-empty) and a freshness check (12 h).
- **media**: all 25 Deployments 1/1; `jellyfin-backup` archives present and pruned to 4; `dedup-sweep`/`trash-reclaim` are pending their first Sunday, not broken.
- **monitoring**: 302/302 rules `health=ok`; only 6 firing, all explained (Watchdog, DiskSpaceLow, NodeDiskIOSaturation, SmartWearHigh on the 96 % NVMe, RecordingRulesNoData).
- **maplespike**: `ngo-influence-rss` and `real-time-feeds` advance every run (the latter thin — 5 records/44 runs, noted).

---

## 5. Human decisions (ranked by blast radius)

1. **quill ingest zero-record path (3.1)** — the fix is in the quill repo: make the
   CLI exit non-zero (or emit a structured non-ok) when `found > 0 && ingested == 0`,
   and repair the broken source adapters (Gazette RSS URL, ourcommons XML export,
   globenewswire 400s, open.canada.ca 404s). Data on the public site is ~1 year stale
   in `committee_meetings`/`entity_mentions`. *Money/data-integrity; owner = quill.*
2. **Mining visibility (3.2)** — a scrape target plus a share-rate/stale alert for the
   `peakminer-*` fleet; decide the exporter (peakminer API on 21550–21554 is already
   consumed by the Omarchy panel). *Money.*
3. **`media-config-backup` (3.3)** — confirm the next scheduled run (04:38) restores a
   green state; if it fails again, the Garage sync path needs attention. Now visible
   either way. *Data-integrity.*
4. **Two fleet-verify owners (3.5) and a 40-commits-behind source (3.6)** — decide
   whether the system timer or the user timer is canonical (the suite's own header
   says the user unit; the installed system unit runs the repo copy), then
   fast-forward `/home/j_kro/media-k8s` from `origin/main`. *Fleet-wide gate integrity.*
5. **Retired-unit gates (3.8)** — repoint the mining-pause tests at miner replicas in
   k3s, or delete them; three repos carry the same vacuous pair. *Gate integrity
   (these are the gates that were supposed to protect builds from GPU contention).*
6. **`ai-inference` (3.10)** — confirm whether the namespace is intentionally empty and
   fix `Projects/AGENTS.md`, or deploy the gateway. *Documentation vs reality.*
7. **Alerting for producers (D3b)** — only 3 of 302 rules are absence-aware. Adding
   `absent()`-style rules for the ingest/backup/mining producers is what turns "no
   data" from health into an alert. *Systemic; the highest-leverage change here.*

## 6. Residuals deliberately left

- `longhorn-system/*` `failedJobsHistoryLimit: 0` — Job eviction is a real trade-off
  (etcd thrash on the control plane); left as a NOTE for the storage owner.
- The 4 `smoke-job-not-schedule` CronJobs (D5) — the status field cannot be fixed
  without a k8s change; the sweep labels them instead.
- `trading/trading-image-build|import` (`Feb 31`, suspended) — documented manual-only
  by design; note only.
- `media/dedup-sweep`, `media/trash-reclaim`, `trading/trading-recal` — pending first
  fire; no action. Their code paths are unexercised (cf. the weekly-report latent
  failure found earlier today), so the first run deserves a look.
- `quill:real-time-feeds` 5 records/44 runs — reported as a NOTE; the threshold that
  would call it a defect belongs to the quill owner.
- No alert rule, timer, or threshold was **disabled** anywhere in this pass; no
  breaker/arming/ledger state was read-modified; nothing was moved to zephyr.