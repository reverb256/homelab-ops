# Nexus storage — ownership ledger (2026-09-23)

**OWNER:** CoS session (default profile), acting for j_kro. This ledger takes over the stalled
`runbooks/bcache-cache-reattach-20260923/` plan and the interrupted `/data/nvme1` migration.
One owner per failure mode: until this is closed, storage changes on nexus route through here.

## Owned scope
1. `/data/media` prune — the owner-authorised reclaim of measured leftovers.
2. `/data/nvme1` migration — **cancelled by owner decision**; the destination tier cannot hold 161 G.
3. `bcache0` cache re-attach — the existing gated plan (G1–G6), executed **after** the prune.
4. The storage-truth record so no future agent re-derives it.

## Phases and gates (each states an outcome that can fail)
| Phase | Gate | Check | Evidence |
|---|---|---|---|
| P1 prune | live re-verification per candidate | nothing active in qBittorrent, nothing hardlinked, nothing library-referenced | `/home/j_kro/prune-20260923/verify.jsonl` |
| P1 prune | deletion | one ledger row per item, allocated bytes; `df` before/after; library spot-check | batch ledger |
| P1 prune | stop conditions | halt under 100 G free or on a hung read | `df` series |
| P2 hygiene | migration cancelled | unit inactive, zero `nvme1-migrat[e]` processes, source intact on root | `systemctl is-active`, `pgrep`, `du` |
| P2 hygiene | partial copy removed | spot-checked as a subset first; source still 145,650 files | file counts |
| P2 hygiene | hold tree identified | 85 G `_fast-hold-20260923` vs a 27 G `/data/fast` — explained or flagged | inventory |
| P2 hygiene | Kingston retired | 96 % wear, 338,309 error-log entries, unmounted, not reused | SMART + `findmnt` |
| P3 cache re-attach | G1–G6 of the existing plan | media workloads stopped, ArgoCD self-heal suspended **and announced**, tier copied, sdb repartitioned, cache registered writearound | the plan's own `verify.mjs` |
| P4 record | storage truth committed | 4-device table, corrections, cancelled migration, reclaimed total with method | `homelab-ops` commit |

## Decisions on record (auditable)
- **Prune authorised** by j_kro ("go ahead with all recs") — scoped to the measured leftovers only.
- **Migration cancelled** — it is not data protection: `/data/nvme1` lives on `/dev/mapper/root`
  (WDC SN550, 10 % wear, **0 media errors**), and the worn Kingston is unmounted. Cancelling risks nothing.
- **Cache attach sequenced after the prune** — it needs `/data/fast` unmounted and the media stack
  paused; running it during a 600 GB deletion on a host that already wedged once is how you get a second wedge.
- **Kingston not reused** — 96 % worn is end-of-life, not spare capacity.

## Incident: the cancelled migration was relaunched by a non-CoS actor
At **13:11:22** a detached `rsync -aH --delete --bwlimit=20M /data/nvme1/ /data/fast/nvme1-migrate/`
appeared (PPID 1), and at **13:11:45** a transient `systemd-run` unit `nvme1-evac3.service`
("nvme1 -> EVO throttled resync") launched a second copy. Both were **minutes after** the owner's
cancellation and **while this CoS prune lane was starting work**.

- This lane did **not** start them: its live transcript contains **zero** mentions of `nvme1`
  (25 storage mentions, all prune pre-flight).
- The first `pkill` failed with `Operation not permitted` — they run as root and the operator shell is
  not root. Stopped correctly as a unit (`systemctl stop nvme1-evac3`), then the detached survivors were
  SIGKILLed. **Verified: 0 processes remain, unit inactive, `Restart=no`.**
- Nothing was lost: the source is intact at 165 G / 145,650 files on root; the destination held 78 G / 51,482.

**Standing instruction: do not relaunch this migration.** If it is believed to be protection rather than
layout, read the evidence above first: the source device is healthy and the data is not at risk.

## Notification
- **In-session:** the prune lane's completion re-enters the CoS session automatically.
- **Watchdog:** `storage-watch.sh` on a clock — script-only, prints **only** on an anomaly
  (stall, low free space, a relaunched migration, an unexpected bcache state), silent otherwise.
- **Durable record:** this ledger plus the kanban task; the board is where ownership is visible to other agents.

## Outstanding, and owner-gated
- The **maintenance window** for P3 (media stack down, ArgoCD self-heal suspended).
- The **fate of the 85 G hold tree** — needed if the tier is repartitioned, garbage if not.
- Any media deletion beyond the measured leftovers under `/data/media/downloads`.

## Contested resource: /dev/sdb (added 2026-09-23)

P3 (bcache0 cache re-attach) and FAST-TIER-PLAN.md both claim sdb and cannot both have it.
Reconciliation, evidence and recommendation are in FAST-TIER-PLAN.md; P3 is GATED on the owner
choosing replace-vs-prune for the 4 TB volume. P1 (prune) is unaffected and can proceed.
