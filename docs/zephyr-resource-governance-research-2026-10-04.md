# Zephyr resource governance + Hermes gateway multiplexing — research

Date: 2026-10-04 · Method: Hermes official docs (docs-first), upstream sources (kernel/systemd/k8s/GitHub), live probes on zephyr/nexus/sentry/forge.
Companion to kanban t_8dc62bdf (zephyr RAM compliance) and the 2026-10-04 process-isolation review.

## TL;DR
1. **Gateway multiplexing: already adopted fleet-wide** — one gateway process per host serves every profile. Nothing to migrate. Caveats: MCP registries are process-global under multiplexing (upstream-tracked); cloudflare MCP OAuth is stuck in a retry loop; trader email credential is duplicated with default.
2. **Biggest concrete win = MCP process dedup/lifecycle.** Measured ~1.4–1.5 GB of duplicative MCP processes on zephyr (gateway + 2 sessions). Knobs: `lazy: true`, `idle_timeout_seconds`/`max_lifetime_seconds`, shared HTTP instances (mcp-victoriametrics supports Streamable HTTP/SSE via `MCP_SERVER_MODE`).
3. **Coredump policy**: defaults never prune ours (2.4 GB sitting) → add a `MaxUse` cap drop-in + `LimitCORE=0` on crash-prone units. Keep external storage.
4. **Budget metric**: use `MemAvailable` (and anon/zram), not `used`/`total−free`. Alerts already key on available; the "29 GB" readouts are cache-inflated.
5. **Caps**: `MemoryHigh` on offender units is sound (throttle, never kill). oomd already covers the user session well (omarchy-tuned).
6. **k8s**: add default-*limits* LimitRanges where missing; consider guardrail quotas. OOM policy is implicit today (miners adj=999 die first) — decide it explicitly.

## Part 1 — Hermes Gateway Multiplexing

### What it is (from official docs)
- One gateway process per host serves **every profile**: adapters, secrets, sessions, cron ticks — sharing one event loop, one HTTP listener, one process lock, one status surface.
- **On by default** (`gateway.multiplex_profiles`); an unset flag is settled at boot by a preflight (keeps standalone if a secondary still runs its own gateway, duplicate bot creds, or a port-binding platform without `/p/<profile>/` ingress). `false` is **retired**; `gateway.standalone: true` is a temporary per-profile shim; fold via `hermes gateway migrate --multiplex`.
- Isolation mechanics: context-local secret scopes (`get_secret` fails closed), per-profile HERMES_HOME override (config/state.db/skills/memory/MCP startup follow), session keys `agent:<profile>:…` (default keeps `agent:main`), per-bot session lanes, intake-vs-delivery separation.
- Ops: `hermes -p X gateway stop|start|restart` = park/unpark one profile (marker `gateway.parked`; rescans every ~30 s). `hermes gateway restart` (default) restarts **the host multiplexer — every bot on the device reconnects**.
- Known limitation (upstream, tracked): **MCP discovery/tool registration is process-global** under multiplexing — the first profile to build an agent wins the discovery slot. Full per-profile MCP registries are not shipped yet.
- Sources: `docs/developer-guide/multiplexing-gateway`, `docs/user-guide/multi-profile-gateways`, `docs/reference/mcp-config-reference`.

### Fleet state (measured 2026-10-04)
| Host | Gateway | Served profiles | Notes |
|---|---|---|---|
| zephyr | `hermes-gateway.service`, up 1d2h, RSS ~1 G (peak 2.8 G), 385 tasks, **17 MCP children (446 MB)** | ~30 (all listed) | flag `true`; heavy MCP tail; cloudflare OAuth retry loop |
| nexus | same unit, up 1d2h, 652 MB, 41 tasks | many (default, analyst, backend-eng, …) | folded |
| sentry | up 7d, 433 MB, 50 tasks | 2 (default + haven-bot) | folded |
| forge | up 2d, 37 MB, 9 tasks | 1 (default) | single-profile; nothing to fold |

**Conclusion: multiplexing is done fleet-wide.** The remaining cost is MCP process duplication (Part 2 §7), not gateway topology.

### Papercuts to clean (found during this audit)
- **cloudflare MCP**: OAuth fails every ~5 min (`non-interactive environment and no cached tokens`) → run `hermes mcp login cloudflare` once interactively (or disable the server) to stop the loop.
- **trader ↔ default duplicate email credential** (list-time warning, blocks future migrate claims); `trader:email` adapter health shows `socket error: EOF`.
- **haven-bot adapter**: `python-socketio is required` warning.

## Part 2 — The brainstorm items, researched

### 1. MemoryHigh soft caps (systemd / cgroup v2)
- Kernel cgroup-v2 docs: `memory.high` = throttle + heavy reclaim; **never invokes the OOM killer**; intended for use *with an external monitor*; too-aggressive settings → gradual performance degradation (not kills).
- systemd resource-control: `MemoryHigh` / `MemoryMax` / `MemoryLow` / `MemoryMin` (+ `MemorySwapMax`) per unit/slice.
- systemd-oomd docs: recommends desktop `user@$UID` pressure limits *lower* than the 60% default (e.g. 40%); advises processes be **managed by the systemd user manager** so oomd can act on individual units (otherwise it acts on whole cgroups).
- Our state: user slice uncapped; omarchy ships a well-reasoned oomd config — `50%` pressure / `20 s` (vs 60%/30 s default), swap kill at `90%`, and **only `app.slice` is kill-eligible** (compositor in `session.slice` is structurally safe; apps launched via uwsm land in `app-*.scope` units).
- Recommendation: add `MemoryHigh` to named offender units (voxtype daemon ~2.5–3 G, hermes-gateway ~2.5 G, worker scopes via dispatcher). Keep generous; measure 24 h; never hard-`MemoryMax` a desktop app without need.

### 2. Coredumps
- `coredump.conf`: `Storage=external` default; `MaxUse` default 10% of disk; `KeepFree` 15%; `ProcessSizeMax` 32 G (64-bit). Our defaults **never prune** — 2.4 GB sitting.
- Recommendation: drop-in `/etc/systemd/coredump.conf.d/zzz-cap.conf` → `[Coredump] MaxUse=1G` (auto-vacuum of old dumps); per-unit `LimitCORE=0` on known-crashy units (k3s precedent exists). Keep external storage — today's voxtype dump proved its value.
- Source: man7 coredump.conf(5).

### 3. Metric: `free` vs `available`
- `available` = free + reclaimable cache — the honest headroom metric; `total−free` counts page cache (this is the entire "29 GB" confusion: total−free ≈ 29.8–30 G vs ~25 G used vs ~6 G available).
- Our alerts (`ZephyrMemoryAvailableLow` <6 G, `Collapse` <3 G) already use the right metric.
- Recommendation: restate the 21 G budget in available/anon terms ("available ≥ 6 G" + "anon+zram ≈ under X") in the card/docs; retire the `used<21` phrasing.
- Sources: baeldung, linuxblog.io.

### 4. Session hygiene (agent processes)
- Each extra Hermes TUI session ≈ 0.5–1.2 GB including its own MCP children (measured: 466 MB + 538 MB children across two sessions, plus their own Python/Node).
- Recommendation: convention ≤2 concurrent agent sessions; close idle ones; `hermes sessions prune` for old transcripts (disk).
- Supporting point: systemd-oomd docs' "manage via systemd user manager" advice — workers already are scopes; sessions are not (they're transient processes), so closing them is the lever.

### 5. Kubernetes quotas
- Docs/best practice: **pair `ResourceQuota` + `LimitRange`** (quota needs requests; LimitRange supplies defaults); keep headroom for scaling; alert at ~80%; LimitRange applies at admission only (running pods unaffected); violations → `403`/`Pending`.
- Our state: **no ResourceQuotas**; LimitRange `default-requests` in ~14 namespaces; heavy pods sized by convention.
- Recommendation: (a) add `default:` limits to LimitRanges; (b) guardrail quotas (~2× headroom) for mining/media/monitoring as a pilot; keep no-quota style elsewhere.

### 6. OOM scores / priority
- Kubelet sets `oom_score_adj` by QoS: Guaranteed −997; BestEffort 1000; Burstable `min(max(2, 1000−1000×req/cap), 999)`. Eviction order: lowest **Priority** first; node OOM kills highest score. `system-node-critical` → −997.
- Measured zephyr: **miners adj=999** (all four), llama-server 905, user shell ~200. So the current implicit policy is "miners absorb node-level OOM". The 10-02 fix made pod-local failure the primary defense; decide whether miners keep adj=999 as the declared fallback or get protected (Guaranteed/requests/PriorityClass). Record the decision in chart values.
- Sources: k8s node-pressure-eviction, pod-qos docs.

### 7. MCP process dedup & lifecycle — the big one
- **Hermes-native knobs** (none set in our config today): `lazy: true` (register from cached schema; spawn on first tool call), `idle_timeout_seconds` + `max_lifetime_seconds` (recycle memory-heavy stdio servers — docs' example: browser MCPs holding Chromium), HTTP transport (`url:` + headers) for shared instances, `/reload-mcp`, Dynamic Tool Discovery. Gateway also hot-reloads MCP config within ~1 min.
- **Measured duplication (zephyr)**: gateway 17 MCP children (446 MB) + each session's 14 children (~470–540 MB); `mcp-victoriametrics` runs **×3 ≈ 375 MB each** (gateway + 2 sessions).
- **Server support**: `mcp-victoriametrics` supports SSE + Streamable HTTP via `MCP_SERVER_MODE` env (upstream README) → can run **once per host**; other servers to be verified individually (grafana/k3s/comfyui/…).
- Landscape (if we ever want a wrapper layer): TBXark/mcp-proxy (aggregates behind one HTTP endpoint, holds OAuth), microsoft/mcp-gateway (k8s reverse proxy), Docker MCP Gateway (containerized lifecycle + secrets), 1mcp. Hermes' native HTTP client mode makes third-party wrappers optional for us.
- Recommendation (ranked): (1) mark idle-prone stdio servers `lazy: true` + recycle timers on heavy ones; (2) convert shareable stateless servers to one local HTTP instance per host (vm first — decide placement vs the "no new services on zephyr" rule: user unit vs run elsewhere); (3) revisit after upstream per-profile MCP registries land.

### 8. Worker caps
- Dispatcher already spawns workers as `systemd-run` scopes (verified live: `hermes-worker-kanban-t_…-run-N.scope`) → adding `-p MemoryHigh=… -p LimitCORE=0` (optionally `CPUQuota=`) is a small spawn-code change; scopes are oomd-compatible by construction.
- Recommendation: sample worker peak RSS for a day, then patch with generous headroom.

### 9. Verification rows (internal)
- Fold zephyr assertions into existing sweeps (verify-fleet / daily-oom-audit): caps present, dumps under cap, offenders bounded. No external research needed.

### 10. Pairing caps with fixes (internal)
- quickshell leak → omarchy#9897 (upstream); voxtype crash → skip-destructors PR in flight (kanban t_97180f1f). Policy: caps are tourniquets; each pairs with a root fix so the list shrinks.

## Appendix — measured values (2026-10-04, zephyr)
- `free`: total 31.26 G, used ~25 G, available ~6.0–7.6 G through the window; `total−free` ≈ 29.8–30 G (the "29"). zram: 11.6 G compressed → 3.26 G real (RAM-backed). Slab ~4.4 G total (~1.9 G btrfs_inode, ~1.3 G kmalloc-64; mostly reclaimable).
- Top RSS: voice-models pod 3.4 G · browser stack ~3 G · hermes stack ~3.3 G (gateway + 2 sessions + MCP) · voxtype daemon 1.6 G (model resident) · freebuff 1.5 G · electron app 1.1 G · llama pod 0.9 G · quickshell ~0.5 G (+swap creep).
- oomd: swap limit 90 %, pressure 50 %/20 s, kill candidates = `app.slice` only; compositor safe.
- oom_score_adj: peakminer ×4 = 999; llama-server = 905; user shell = ~200.

## Cross-link — fleet GPU allocation (2026-10-04, kanban t_03de36be)

The GPU half of this fleet's scheduling policy is recorded in
`mining-k8s/docs/GPU-SCHEDULING-RESEARCH.md` §5:

- per-card **roles** and the **headroom floors that are actually asserted**
  (`media-k8s cluster/checks/verify-fleet.sh`: sentry-agent >= 3 GiB for the
  media/VAAPI lane, nexus >= 500 MiB for inference + mining);
- the **pass-through audit** — which of privileged / runtimeClass / device-plugin
  each GPU pod really uses, and the measured proof that an unprivileged VAAPI pod
  cannot open `/dev/dri/renderD128` at all (cgroup-v2 device allowlist);
- the **decision not to enable native `nvidia.com/gpu` scheduling**, because it
  would break the deliberate miner + inference co-residency that the floors exist
  to protect.

Host-side companion: `inventory/inventory.yaml` now records sentry's media lane
(`homelab.io/gpu-class=media`) and its role as the NFS server for the media
libraries.

## Sources
- Hermes: docs/developer-guide/multiplexing-gateway · docs/user-guide/multi-profile-gateways · docs/reference/mcp-config-reference · docs/user-guide/features/mcp
- cgroup v2: https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html · systemd.resource-control(5)
- systemd-oomd: oomd.conf(5) · systemd-oomd(8) · omarchy drop-ins (`/etc/systemd/oomd.conf.d/10-omarchy.conf`, `/usr/lib/systemd/user/app.slice.d/10-oomd.conf`)
- coredump: coredump.conf(5) — https://www.man7.org/linux/man-pages/man5/coredump.conf.5.html
- k8s: resource-quotas · limit-range · node-pressure-eviction · pod-qos (kubernetes.io)
- MCP: github.com/TBXark/mcp-proxy · github.com/microsoft/mcp-gateway · github.com/docker/mcp-gateway · github.com/1mcp-app/agent · github.com/VictoriaMetrics/mcp-victoriametrics
- Metric: baeldung.com/linux/free-available-cached-memory · linuxblog.io/free-vs-available-memory-in-linux

## Decisions needed (j_kro)
1. MCP lazy/idle rollout (config-only, reversible) — approve as a small pass?
2. Shared HTTP MCP instance placement given the no-new-services-on-zephyr rule.
3. Coredump `MaxUse=1G` drop-in — approve?
4. Worker caps patch (after a peak sample).
5. k8s LimitRange default-limits + quota pilot namespace.
6. Miner OOM policy: keep adj=999 as declared fallback, or protect?
