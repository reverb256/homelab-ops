# k3s etcd snapshots stopped reaching garage for sentry-agent (404/403 /k3s-etcd)

**Fixed:** 2026-10-05 04:03–04:06 CDT · **Card:** kanban `t_e13e4db4` · **Host:** sentry-agent
**Impact:** for 14 days (2026-09-20 → 2026-10-05) only 2 of the 3 control-plane nodes were
backed up off-host. The cluster could have been restored, but the sentry-agent member's
snapshots existed only on sentry itself.

## Symptom

Garage's journal on nexus, ~9 requests/minute that never stopped:

```
100.105.246.35  (key ********) HEAD /k3s-etcd/
error 403 Forbidden, Forbidden: No such key: ******** in response to ... HEAD /k3s-etcd/
```

`100.105.246.35` is **sentry** on the tailnet. Every other client looked healthy, which is
why this read as a sentry-side credential problem and not as a cluster outage.

## Root cause

The **2026-09-20 garage rebuild** dropped the `k3s-etcd` bucket and its access key. The
bucket and a replacement key were recreated on 2026-09-24, and **nexus and forge were
repointed at the replacement key** (`k3s-etcd-final`, `GK7791…`). **sentry-agent was
missed**: its hand-managed `/etc/systemd/system/k3s.service` still named the dead key id
`GKa75e6a7…`, so k3s could not initialise the S3 client:

```
sentry k3s: Failed to record snapshots for cluster: failed to initialize S3 client:
            failed to test for existence of bucket k3s-etcd: Access Denied.
```

k3s only logs that at INFO/WARN once per reconcile, so it never surfaced as an alert.

## Evidence (all read live, 2026-10-05)

| read | result |
|---|---|
| `garage key list` | `GKa75e6a71911a9a0d3ac6dd32` **absent** |
| `garage bucket info k3s-etcd` | RW granted only to `GK7791d022f4163caac9949962` (`k3s-etcd-final`) |
| `kubectl get etcdsnapshotfiles` | sentry-agent has ~40 `file://` snapshots (fresh, every 6h) and **zero** `s3://` ones; nexus/forge have `s3://k3s-etcd/…` |
| `aws s3 ls s3://k3s-etcd/` | only `etcd-snapshot-nexus-*` and `etcd-snapshot-forge-*` |
| nexus + forge units | `${K3S_ETCD_S3_KEY}` from `/etc/systemd/system/k3s.service.env` → working |

The trap: sentry kept taking a **local** snapshot every 6h, so any check of the form
"does this node have a snapshot?" would have passed for the entire 14 days.

## Fix (chosen: fix the node config, not resurrect the key)

`garage key import` **cannot** recreate a deleted id — the store tombstones it:

```
Error: ImportKey returned KeyAlreadyExists (409): Key GKa75e6a7… already exists in data
store. Even if it is deleted, we can't let you create a new key with the same ID.
```

So sentry was moved to the **same key nexus and forge already use**, via the same mechanism:

1. On sentry, `/etc/systemd/system/k3s.service` — the two literal credential lines became
   `--etcd-s3-access-key=${K3S_ETCD_S3_KEY}` / `--etcd-s3-secret-key=${K3S_ETCD_S3_SECRET}`
   (unit backed up first to `k3s.service.bak-20261005-040325`; unit and env file now 0600,
   where the unit had been world-readable with the secret inline).
2. On sentry, `K3S_ETCD_S3_KEY` / `K3S_ETCD_S3_SECRET` appended to
   `/etc/systemd/system/k3s.service.env` (mode 0600) — the same file nexus and forge use.
3. `systemctl daemon-reload && systemctl restart k3s` on sentry.

Declared state was then reconciled in this repo:
`omarchy/sentry/systemd/k3s.service` (env refs, secret removed from git) and
`omarchy/nexus/garage-buckets.tsv` (`k3s-etcd` → `k3s-etcd-final`, because the reconciler
mints keys **by name** and the manifest had drifted from the live key name).

**Not** done: no new key was created for sentry, so the reconciler stays consistent with a
single `k3s-etcd-final` key for all three control-plane nodes.

## Verification

- `systemctl show -p ExecStart k3s` on sentry now reads identically to nexus (both show the
  raw `${K3S_ETCD_S3_KEY}`; systemd expands it at start — proven by
  `systemd-run -p EnvironmentFile=… printenv K3S_ETCD_S3_KEY` returning `GK7791…`).
- sentry k3s journal, immediately after restart: `Reusing cached S3 client for
  endpoint="http://100.76.105.73:3900" bucket="k3s-etcd"` — no `Access Denied`.
- Garage journal: **0** requests and **0** 403s from `100.105.246.35` since the restart.
- End-to-end upload, one real object:
  `sentry-s3-verify-sentry-agent-1791191149.zip` (17,325,371 bytes) in `k3s-etcd`.
- `kubectl get nodes` 3/3 Ready, `/healthz/etcd` ok, `etcd` readiness ok.
- Backups verified afterwards: `memlawb` (6,176 objects; snapshot `20261005-040526` written
  by the 04:05 run, exit 0) and `haven` (snapshot `20261004-042501`; next run 04:29).

## Regression check

`media-k8s` PR #17 adds verify-fleet **§9z** plus
`cluster/checks/etcd_s3_snapshots.py`: per etcd node, require an ETCDSnapshotFile whose
location starts `s3://` and whose creation time is inside 12h (two missed cycles, so a node
that is genuinely powered off for one cycle does not false-page). It judges the S3 side, so
a fresh `file://` snapshot cannot mask a missing upload, and it fails closed on unreadable
input. Unit tests cover the filed state, no-s3, fresh, newest-wins and both fail-closed
cases.

## Notes / open items

- **Why it was silent for 14 days:** nothing watched the k3s-etcd bucket. The host
  `backup-stall-watchdog` covers systemd `*backup*` **units**, not k3s's own S3 uploads, and
  the `s3-freshness.timer` named in older sweep notes no longer exists. §9z is that watcher.
- **nexus rebooted cleanly at 04:00:21 CDT** during this window (k3s restarted 04:01:20;
  repeating ~03:00–05:00 pattern over the last week). Unrelated to this change, but it is
  why a live `test_monitoring_invariants.py::test_vmsingle_is_not_oomkilled` run is red on a
  live cluster right now (vmsingle restarted, `reason=Unknown`).
- The sentry unit remains hand-managed; `omarchy/sentry/systemd/k3s.service` is a
  **declaration** and must be kept in sync by hand (see `runbooks/k3s-rename-sentry-20260923/`).
