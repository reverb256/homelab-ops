# Trading recovery drill — 2026-09-23

**Scope:** prove (or disprove) that the trading system's keys, state and dead-man
path can actually be recovered. Before this drill **no restore had ever been
rehearsed**, so every claim below was an untested assumption.

**Re-runnable proof:** `scripts/verify/recovery_drill.sh [--restore]` (run on
nexus; it refuses to run on zephyr and never writes there).

**Constraints honoured:** no funds moved · nothing signed · nothing armed · no
writes to live `data/keys/` or ledger state · no secret value printed (sha256
prefixes, byte lengths and booleans only) · **nothing was written to zephyr** ·
all scratch state created on nexus and deleted (verified).

Measured during: 2026-09-23 04:00–04:10 UTC (= 2026-09-22 23:00–23:10 CDT).

---

## 1. What the backup actually contains

**Answer: no credentials leave the host today.** Verified by *name and content*,
never by printing a value.

Offsite target is the self-hosted **Garage** (`http://100.76.105.73:3900`,
bucket `trading-backups`) reached through the `aws` CLI. There is **no AWS S3
destination** — the AWS CLI is only an S3 client for Garage. nexus also keeps a
local copy at `/data/backups/trading/`. Nothing is written to zephyr.

19 objects, measured:

| Path | Contents |
|---|---|
| `db/signals-*.sqlite.gz` (+`-latest`) | gzipped SQLite signal ledgers, 5 dated + 1 pointer |
| `db/wallets-*.sqlite.gz` (+`-latest`) | gzipped wallet ledgers, 6 dated + 1 pointer |
| `state/canary_meta.json` | 707 B |
| `state/moonbags.json` | 4 B |
| `jsonl/trading-jsonl-latest.tar.gz` | 11 members, 1,309,285 B |
| `jsonl/archive/{curve_watch,gmgn_flow}-*.jsonl.gz` | 3 large-file archives |

The 11 bundle members, listed from the actual object: `gradplay_positions.jsonl`
`curve_positions.jsonl` `cluster_shadow.jsonl` `graduations.jsonl`
`grad_momentum.jsonl` `grad_ml.json` `grad_ml_model.pt` `rigor_gate.json`
`cluster_summary.json` `digest_last.md` `pumpfun_stats.jsonl`.

**Explicit answers to the questions raised earlier:**

| Asked | Answer |
|---|---|
| Is `exec.env` in the archive? | **No.** |
| Is `data/keys/*` in the archive? | **No.** No `keys/` object anywhere in the bucket. |
| Is `halt_peer.env` in the archive? | **No.** |
| Are logs in the archive? | **No.** `daemon.log` (7,157,557 B) is not published. |
| Any credential material at all? | **No.** A secret-pattern scan of every member found exactly one hit: `cluster_shadow.jsonl`'s `token` field, a 42-char `0x…` **EVM contract address** (a token address, not a credential). |

### The latent gap that was found and closed

The backup already uses an allowlist for `db/`, `state/` and the jsonl bundle —
but the **archive-on-trigger loop globbed every `data/*.jsonl` over 100 MB with
no deny-list**. Two files that have historically been written with live keys sit
in exactly that scope:

- `data/exec_log.jsonl` (592,335 B) — Alchemy key;
- `data/reconcile.jsonl` (46,151 B) — Helius key inside the `rpc` field.

Neither exceeds 100 MB today, so nothing has leaked. But a growing ledger would
have shipped a live credential to the bucket with no warning.

**Fix applied** to `trading/scripts/backup_trading_data.sh` (nexus canonical
checkout; pre-change copy kept at `backup_trading_data.sh.pre-recovery-drill-20260923`,
**not committed** — left for review):

1. a `DENY_RE` deny-list + `is_denied()` (match by name/pattern only);
2. the archive-on-trigger loop now skips denied files (`SKIP(deny): …`);
3. the jsonl bundle is name-checked **and** content-scanned (`api-key=`,
   `BEGIN … PRIVATE KEY`, `AGE-SECRET-KEY`) before upload, and the upload is
   refused if either fails;
4. a new read-only `--audit` mode that prints exactly what would leave the host
   and uploads nothing.

**Proof:** `--audit` on the live tree → `AUDIT-CLEAN`, 11 members, 0 archive
candidates; the deny-list table scores **13/13**; a synthetic bundle containing
`api-key=<value>` is **REFUSED** while a clean one is allowed; and with a
scratch tree holding a 101 MB `exec_log.jsonl` the audit reports
`archive candidate DENIED: exec_log.jsonl` for it and `would UPLOAD` for the
benign file beside it.

### Adjacent findings (out of scope, unowned)

- `haven-backup` **deliberately** ships `/data/.env` (JWT/VAPID secrets) to the
  `haven` bucket; `activepieces-backup` ships `AP_ENCRYPTION_KEY`;
  `media-config-backup` ships arr configs, which carry indexer/app API keys.
  These are intentional but they are *secrets in a bucket* — confirm they are
  meant to be there.
- `homelab-ops/scripts/backup-to-garage.sh` has a **hardcoded Garage key id** and
  tars `/etc/nixos` (which contains `.age/` key material), at a stale endpoint
  (`10.1.1.110:3900`). It is **not scheduled** on nexus — manual only. Do not run
  it as-is.
- The archive-on-trigger path **truncates the live jsonl to its newest 5 MB**
  after a successful upload. That is destructive to live state; the pre-trim
  history then exists only in Garage. Flagged, not changed.
- `data/` is not fully covered: **202 top-level files (~5.3 GB) vs 16 backed-up
  objects.** See §3.

---

## 2. Key restore — end to end, without arming

**Path used:** `trading/tools/provision-secrets.sh` run **on zephyr** (the only
host with the age identity). It decrypts `sops -d` to **stdout in RAM** and pipes
the bytes over `ssh` straight into a scratch tree on nexus. **No plaintext is
ever written to disk on zephyr** — that is the whole point of the design, and it
still holds.

**Measured wall time: 1,254 ms** for all three keypairs plus `exec.env` and the
alchemy/helius mirrors (1,337–1,343 ms on repeat runs).

Restore fidelity, by sha256 (twelve hex chars):

| File | restored | live file | byte-exact |
|---|---|---|---|
| `live.json` | `2e76ca6c6559` | `2e76ca6c6559` | **yes** |
| `rhc.json` | `838eb4018c72` | `838eb4018c72` | **yes** |
| `devnet.json` | `4956059735d5` | `4956059735d5` | **yes** |

Restored files land mode `600`.

**Working-signer proof, with nothing signed:** what matters is not that the bytes
round-trip but that they are a *usable private key*:

- SOL `live.json` → derived address **`Ghr7xwP6HqzYVeXAq7uToR7poUSQuJ9pB8dCeQqA5wmf`**
  — the live float currently in use.
- RHC `rhc.json` → derived address **`0xF898b6D2F9Aaa7736Cf6FD57E418aC1aC6a04f12`**
  — the funded RHC lane, and equal to the address declared inside the file.
- devnet → `5qUpL8vDkBANtoaFfSvCRysa8MkndJNLu1dKsHfxUPZv`.
- The Ed25519 secret half is proven to be the true preimage of the embedded
  public key (`seed → pubkey == embedded pubkey`), and the secp256k1 key derives
  the declared address. A non-functional key cannot pass either check — **no
  transaction was signed and no key was armed to establish this.**

**Verdict: key recovery works.** Losing the nexus disk does not lose the keys;
`tools/provision-secrets.sh` reproduces them byte-exactly in ~1.3 s.

---

## 3. Trading-state restore — and the honest gaps

Newest snapshots pulled from Garage into a nexus scratch dir, gunzipped, checked.

**Measured:** full fetch + decompress **4,183 ms** (1,739–2,457 ms on later runs,
warm cache). `PRAGMA integrity_check` → **ok** on both `signals` (450,404,352 B)
and `wallets` (1,921,024 B). Schema is **identical** to live (10 tables in
signals, 3 in wallets).

Row counts, restored vs live (drill time):

| Table | restored | live | lost |
|---|---|---|---|
| `signals.signals` | 144,375 | 146,972 | **−2,597 (1.8%)** |
| `signals.rejections` | 9,679 | 10,129 | −450 |
| `signals.token_socials` | 4,289 | 4,514 | −225 |
| `wallets.wallet_trades` | 3,158 | 3,635 | −477 |
| `positions` / `fills` / `journal` / `pending_marks` / `reentry_events` / `holdout_mints` / `wallets` | equal | equal | 0 |

**Recovery point measured: 325–329 min (≈5 h 25 m)** since the offsite snapshot.
The timer runs daily at 04:15 with `Persistent=true`; the newest object came from
a manual 17:38 run. So a real loss silently costs *up to a day* of signal and
wallet history, not minutes.

### What is missing or unusable after a real loss

The repo's own validation was run: `python -m pytest tests/ -q` →
**679 passed in 24.53 s**. Note what that does *not* do — **no test in the repo
validates restored data.** The only data-level checks that exist are the
`PRAGMA integrity_check` in the backup script and gate `G2` (which merely counts
files in the bundle). That is the honest gap: **the suite proves the code, not
the backup.**

Not backed up, and **not recoverable from the sops store either**:

| File | Consequence |
|---|---|
| `breakers_state.json` (75 B) | breaker state vanishes → the daemon could come up and trade **un-halted**. This is the single most dangerous gap; it is why the pager's alert text says *"do NOT resume the breaker blind"*. |
| `portfolio_breakers_state.json` (259 B) | same, portfolio level |
| `alloc_state.json` (592 B) | sleeve allocation lost |
| `alert_cursor.json` (195 B) | alert dedupe cursor lost → replay storm risk |
| `canary_status.json`, `cluster_shadow_heartbeat.json` | lane/heartbeat state lost |

Recoverable elsewhere, so **not** a gap: `keys/*` and `exec.env` (sops store,
proven in §2); `keys/alchemy.txt`, `keys/helius.txt` (store, per-key entries);
`halt_peer.env` — its 64-char peer token **is present** in
`infra/hermes-a2a-peer-tokens.yaml` (verified by hash, not printed); only its URL
field is absent, and that is regenerable.

Also worth knowing: `*.lock` files are not backed up (5 present). Losing them is
harmless in isolation, but a *stale* lock restored from a snapshot would deadlock
a writer — clear locks after any restore.

---

## 4. Dead-man pager — it fires

Live pager on the Oracle public tier (`arch@40.233.113.94`, port 8899):

- `deadman-pager.service` **active**; `GET /status` → `ok:true`,
  `heartbeat_age_s` 21–58, `stale_after_s` 900, `hb_count` 555, `halted:true`,
  `sentinel_status:ok`.
- **Unsigned `POST /hb` → HTTP 401** (verified live *and* in a scratch harness).
- Heartbeats arrive from nexus every ~60 s via `stack-sentinel-heartbeat.timer`
  — a systemd **user** timer on nexus. (The same-named timer on the VPS is
  inactive; that is correct, nexus is the sender.)

**Alerting logic proven against a deliberately stale heartbeat in a scratch
copy** (in-process on nexus, no real alert sent): 401 unsigned · 401 tampered
signature · 200 valid HMAC · 400 malformed payload · **stale heartbeat
1200 s > 900 s → alert fired and delivered in ~1.1 ms** · **fresh heartbeat but
sentinel 6000 s > 5400 s → alert fired** · re-page suppressed inside
`DEADMAN_REPEAT_S` · `RECOVERED` re-arm on recovery · all 3 alerts
`delivered=True`.

**Would the SMTP credential actually deliver? Yes — and that is the risk.** A
live AUTH-only probe (logs in, sends *no* message) returned
`AUTH-ONLY-PROBE-OK`: `smtp.gmail.com:465`, sender `snyper256@gmail.com`,
recipient `reverb256@gmail.com`, `pass_len=19`. But on the pager
**`DEADMAN_WEBHOOK_URL` is empty and `DEADMAN_A2A_PEERS` is unset — email is the
only sink.** Revoking that shared app password to silence one noisy sender
silences the entire pager, which is the one thing that notices nexus dying. That
is `deploy/deadman/OWNER-ASK.md`; it is still open and needs an owner decision
(new app password on the same account is the smallest fix).

**One operational gap found:** **nexus cannot SSH to the VPS** — the
`oci_vps_ed25519` identity lives only on zephyr, so the AUTH-only probe and the
sink inventory can only be run from zephyr. HTTP checks are host-independent and
work from nexus. If zephyr is the host that dies, VPS diagnosis needs another
path.

---

## 5. Recovery runbook

### 5a. Re-run the whole drill (safe, read-only)

```bash
ssh nexus
bash /home/j_kro/homelab-ops/scripts/verify/recovery_drill.sh            # checks only
bash /home/j_kro/homelab-ops/scripts/verify/recovery_drill.sh --restore  # + full restore rehearsal
```
Expect `RECOVERY-DRILL-OK` (16 checks). Any `FAIL`/`EMPTY INPUT` line is real —
the script refuses to report clean on empty input. Run the SMTP step from zephyr.

### 5b. Real loss of a signing key

1. Confirm the loss; do **not** arm anything. Keep `EXEC_ARMED` unset and the
   KILL file in place.
2. From **zephyr** (never from nexus — nexus cannot decrypt the store):
   ```bash
   cd ~/Work/trading      # zephyr mirror
   TRADING_REPO_REMOTE=/tmp/restore-check bash tools/provision-secrets.sh
   ```
3. Verify before trusting it — replace the store values only if the derived
   address matches: `live.json` → `Ghr7xwP6HqzYVeXAq7uToR7poUSQuJ9pB8dCeQqA5wmf`,
   `rhc.json` → `0xF898b6D2F9Aaa7736Cf6FD57E418aC1aC6a04f12`.
4. Install only when the addresses match: re-run with the real target
   (`TRADING_REPO_REMOTE` unset) — it refuses to overwrite an existing key, so
   remove/rename the broken file first.
5. Re-run `bash scripts/verify/recovery_drill.sh`. Do not arm until it is green.

### 5c. Real loss of trading state

1. Fetch the newest snapshots:
   ```bash
   aws --endpoint-url http://100.76.105.73:3900 --region garage \
       s3 cp s3://trading-backups/db/signals-latest.sqlite.gz .
   aws … s3 cp s3://trading-backups/db/wallets-latest.sqlite.gz .
   aws … s3 cp s3://trading-backups/jsonl/trading-jsonl-latest.tar.gz .
   ```
2. Gunzip, then `PRAGMA integrity_check` — accept only `ok`.
3. Restore the DBs **into the live path only after** the integrity check passes.
4. **Rebuild by hand what was never backed up** — this is the step people will
   forget: `breakers_state.json`, `portfolio_breakers_state.json`,
   `alloc_state.json`, `alert_cursor.json`. Decide the breaker state
   deliberately; do not let the daemon start from an empty file and resume
   trading un-halted.
5. Clear stale `*.lock` files.
6. Recover `exec.env`, `keys/*`, `halt_peer.env` via `provision-secrets.sh`
   (`--exec-env` for the byte-exact file, which also carries the arming flags).
7. Expect to lose up to ~24 h of signals (measured RPO 5 h 25 m at drill time).
8. Reconcile against chain (`tools/reconcile.py`, `tools/reconcile_evm.py`)
   before re-enabling anything.

### 5d. Dead-man pager

- Health: `curl -s http://40.233.113.94:8899/status`.
- Alerting is email-only today — keep `snyper256@gmail.com`'s app password alive,
  or give the pager its own credential (OWNER-ASK).
- Prove the owner-facing path without waiting for a real outage:
  `ssh zephyr '… sudo /usr/bin/python3 /opt/deadman/deadman_pager.py check --force'`
  (emails the owner once, rate-limited by `DEADMAN_REPEAT_S`).

---

## 6. Verdict

| Question | Answer |
|---|---|
| Do backups ship secrets? | **No** — proven by name and content. A latent unguarded glob existed; it is now blocked and proven blocked. |
| Does a signing key restore to a working signer? | **Yes** — byte-exact in ~1.3 s, deriving the exact on-chain addresses, without signing. |
| Does trading state restore? | **Yes** — integrity `ok`, schema identical, but **stale up to ~24 h** and missing breaker/alloc/cursor state that must be rebuilt by hand. |
| Does the dead-man pager fire? | **Yes** — live 401 on unsigned POST; alert logic fires on both staleness conditions in ~1 ms; email delivers. But it is a **single-sink** design. |

**Biggest residual risks, in order:** (1) breaker state has no backup — a
restore could resume trading un-halted; (2) the pager depends on one shared
Gmail app password; (3) offsite RPO is a day, not minutes; (4) no test in the
repo validates restored data — only this drill does.
