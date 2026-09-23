<!-- DRAFT — NOT APPLIED. Proposed replacement for /home/j_kro/Work/Projects/AGENTS.md.
     Provenance: grown from the 2026-09-22 refresh draft parked on zephyr
     (Projects/.refactor-drafts/agents-md-refresh-20260922.md), then re-verified against
     LIVE state from the canonical nexus checkouts on 2026-09-23 and tightened.
     The real file is hook-protected: applying it is j_kro's explicit decision and is NOT
     done here. Nothing reads this draft as instructions.
     Owner rule in force (2026-09-22): nothing new may be WRITTEN to zephyr at all, so
     applying this means editing the EXISTING file in place on zephyr, by hand — it must
     not be "deployed" as a new artifact. -->

# Projects — Homelab Workspace

> **Last verified: 2026-09-23 ~04:10 UTC** — re-verified from the canonical **nexus** checkouts (the 2026-09-22 pass ran on zephyr); see "Re-verify" at the bottom for the exact commands.
> Treat any dated claim here as stale after ~7 days. Where a claim below could not be verified live, it says so — do not upgrade it to fact by repetition.

Multi-repo workspace (77 top-level entries: 74 directories, 3 files as of 2026-09-23 — 58 of the directories are git repos; counts drift within hours, so re-run the Re-verify block instead of trusting this number). Not a git repo itself. Each subdirectory is its own repository (unless noted `non-git`). Run `git config --global --add safe.directory '*'` once if editing these as root — files are owned by `j_kro`. Workspace root for all paths below is `/home/j_kro/Work/Projects` (not `~/Projects` — that is a separate, smaller directory).

> **Correction pass 2026-09-22.** Earlier revisions of this file described a NixOS/Colmena fleet, `krash3` as a cluster node, a local `nexus:5000` image registry, and memlawb behind an MCP bridge. All four were false and all four produced wrong premises. See **Stale premises — do not repeat** before trusting anything you remember from this file.

## Change rules (hard) — how state is allowed to move

These are the rules most often broken by *following a stale doc*, so they are stated as
rules rather than described as practice.

1. **Cluster state is GitOps-only.** k8s objects change by commit → **ArgoCD**; the repo
   (`trading-k8s`, `media-k8s`, `sites-k8s`, `haven-k8s`, `mining-k8s`, …) is the source.
   Never `kubectl apply|edit|patch|set image` a live object. Never hand-mount a host path
   into a pod "just for now": an out-of-git `kubectl patch` handed the `trading-alerts`
   CronJob the whole `~/.hermes` directory (provider keys included) and had to be removed
   with `Replace=true`, because a server-side-apply sync leaves the other field manager's
   entry in place; a manifest check now fails a build that reintroduces it. Verify with
   the ArgoCD Application **and** the running pod — not with a process's own claim.
2. **Host state is commit + `apply.sh`, never a hand-edited live file.** The source is
   `homelab-ops/omarchy/<host>/`; the applier is that host's `apply.sh`. There is **no
   ArgoCD Application tracking `homelab-ops`** (verified: 0 matches) — a commit alone
   deploys nothing host-side.
3. **The canonical checkout is on nexus; zephyr holds a read-only mirror.** The trading
   repo's push path on zephyr is set to `DISABLED-read-only-mirror` and the mirror is
   fast-forwarded by hand. Never commit or push from the mirror, and never treat its HEAD
   as a revision.
4. **Workstation law (tightened 2026-09-22): nothing new may be written to zephyr.** No
   draft, copy, backup, artifact or new config file — zephyr runs interactive sessions
   only and its cron store holds zero jobs. Repository work happens in the canonical
   checkouts on nexus (`~/homelab-ops`, `~/Work/trading`, `~/Work/trading-k8s`). Reading
   zephyr is fine; landing anything on it is a deliberate j_kro action, not an agent step.
5. **Secrets: never print a value — fingerprint only.** The store is
   `~/Work/Projects/nixos-secrets` (sops+age; its `.sops.yaml` is the authoritative
   recipient list); `homelab-ops/SECRETS.md` is the consumer-and-gap map. Runtime
   credentials are rendered from the store into host env files by the house tooling
   (`homelab-ops/scripts/provider-key-render.py`, `--check` mode) — never hand-placed,
   because a hand-placed key rots silently when the store's copy rotates (that is exactly
   how the on-call responder ended up answering `Invalid credential`).
6. **Anything that touches money needs an explicit instruction.** No live trades, no
   arming, no cap/threshold/breaker-state/kill-switch change, no funds movement — and a
   guardrail is never widened to make a task easier. Arming is a single-purpose change
   with its own proof and drills.
7. **Every problem becomes a test.** A fix not pinned by a check (repo test, gate,
   workflow step, verifier script) is a fix that regresses silently. This fleet has
   produced several "green but blind" failures — a monitor reporting success while the
   thing it watched wrote nothing — so the check must assert the artifact the system
   actually consumes, not that a command ran.

## Infrastructure

**Cluster**: k3s `v1.37.0+k3s1`, **4 nodes, all Omarchy (Arch)** — there is no NixOS anywhere in the fleet.

| node | roles | address | notes |
|---|---|---|---|
| `nexus` | control-plane, etcd | 10.1.1.120 | main worker: memlawb, garage, trading daemons, image build + containerd store; Quill pods pin here |
| `forge` | control-plane, etcd | 10.1.1.130 | mining GPUs |
| `sentry-agent` | control-plane, etcd | 10.1.1.140 | `oracle-idle-watch`, alerting for the Oracle VPS |
| `zephyr` | agent | 10.1.1.110 | workstation; **cordoned** (`SchedulingDisabled`, `spec.unschedulable=true`) — only a node-exporter DaemonSet lands here |

- **`krash3` is not a cluster member.** It was removed from the cluster on 2026-09-22 (Windows box per `Reverb-OS/` inventory; its WSL2 pod network could not carry cross-node pod traffic in either direction). Live check: `kubectl get nodes` lists exactly forge, nexus, sentry-agent, zephyr — no krash3, no pods scheduled there. *(The removal decision itself is not re-derivable from the cluster; `homelab-ops/runbooks/krash3-pod-reachability-2026-09-22.md` documents the failure mode and proposed a tailnet subnet-router fix, and predates the removal — treat the "why" as ops record, not live evidence.)*
- **No NixOS machines remain.** `nix`, `nixos-rebuild`, and `colmena` are absent from PATH and `/nix` does not exist on zephyr. `/etc/nixos` is a **symlink to `~/Work/Projects/nixos-config`** — legacy reference only. That repo's own `AGENTS.md` says: **DO NOT START NEW WORK IN THIS REPO (retired 2026-09-19)**; route cluster work to `reverb256/Reverb-OS` and ops work to `reverb256/homelab-ops`.
- **KUBECONFIG trap.** The environment exports `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`, which **does not exist** → `kubectl` fails with `The connection to the server localhost:8080 was refused`. Always use the live kubeconfig:

```bash
export KUBECONFIG=/home/j_kro/.kube/config   # server https://10.1.1.120:6443, context `default`
kubectl get nodes -o wide
kubectl get pods -A | grep -v -E '(kube-system|calico|monitoring)'
```

**Namespaces (live, 2026-09-22)**: `argocd`, `astral-key`, `activepieces`, `chatterbox`, `cloudflared`, `haven`, `longhorn-system`, `maplespike`, `media`, `media-reverse-proxy`, `metallb-system`, `mining`, `monitoring`, `pihole`, `sites`, `trading`, `voice-models`, plus `calico-*` / `tigera-operator` / `kube-system` / `tailscale` / `system-upgrade` / `version-checker` / `default`. The old list here (`ai-inference`, `nixkube`, `mcp`, `orchestration`, `cert-manager`) is **wrong — none of those namespaces exist**.

**Container images — there is no image registry.** No registry Service exists anywhere in the cluster (no `registry`/`harbor`/`zot`, nothing on :5000), and no live manifest references `nexus:5000`. `nexus:5000` survives only in NixOS-era runbooks under `homelab-ops/runbooks/` (e.g. `resolution-plan-2026-07-16.md`, `apply-order-astral-key.md`). Today's mechanism:

- Images are built **on nexus** with `docker`, imported into **nexus's k3s containerd store** (`k3s ctr -n k8s.io images import`), and referenced **by content digest** with `imagePullPolicy: Never`, with the pod pinned to the node that holds the store. Live example: `quill-api` runs `docker.io/library/quill-api@sha256:961354ec…`, `pullPolicy: Never`.
- Quill's contract is `quill/scripts/pin-images.sh` + gate `A3-IMAGEPIN` (issue #755) + `quill/docs/IMAGE-PINNING.md`: `charts/quill/values-prod.yaml` names `images.<svc>.digest` (the pin) and `.tag` (provenance only, stamped on the pod as `quill.maplespike.ca/image-build-tag`). Check with `node scripts/gates/check-image-pins.mjs --values charts/quill/values-prod.yaml --live`.
- **Discipline is not uniform**: `trading-cluster-shadow` / `trading-*` still run `docker.io/library/trading-jobs:local` (a mutable tag), and `media-reverse-proxy` runs `nginx:1.29-alpine`. *(Note: an earlier claim in this file's lineage said images are "pinned by TAG" and that a `tag@sha256` ref will not resolve under `pullPolicy: Never` — that is not what the live cluster shows; the Quill and astral-key refs are digests and they run.)*
- Git is the source of truth for what should be deployed; the containerd import is the manual, non-reconciled step.

**Secrets**: SOPS + age, ciphertext-only store at **`~/Work/Projects/nixos-secrets`**. The authoritative recipient list and decrypt rules live in that repo's **`.sops.yaml`** (5 recipients, OR-semantics: `cluster_age`, `zephyr_age_v2`, YubiKey Nano, YubiKey NFC, offline break-glass). The age key material used on zephyr is **`~/.config/sops/age/cluster-age-key.txt`** (0600); note `~/.config/sops/age/keys.txt` also exists — per `.sops.yaml`, that file is the YubiKey identity-stub file, so read `.sops.yaml` before assuming which is which. Consumers, delivery paths, and known gaps are inventoried in **`homelab-ops/SECRETS.md`** (read it before wiring a new secret). Never print a value; fingerprint only.

**Memory**: cross-session memory is a **Hermes MemoryProvider**, not an MCP bridge. The `memory` tool is the interface. The memlawb backend runs as a **systemd unit on nexus** (`homelab-ops/omarchy/nexus/systemd/memlawb-server.service`, store on the bcache pool at `/data/hermes/memlawb-data`), served on **:8080 over the tailnet only** — `http://100.76.105.73:8080` (nexus's tailnet IP). Namespace `user:j_kro`. Client wiring is per profile: **`memory.provider: memlawb` + `memory.memlawb.url`** in `~/.hermes/profiles/<name>/config.yaml` (18 profiles, e.g. `researcher`, `coo`, `editor`, `reviewer-*`). **The default profile on zephyr is different**: `~/.hermes/config.yaml` sets `memory.provider: omh` (the file-backed omh provider), so "memory is memlawb" is not universally true — check the profile you are in with `hermes config get memory.provider` (and `hermes --profile <name> config get memory.provider`). **Re-verified 2026-09-23:** `systemctl status memlawb-server` → `active (running)` on nexus; the store lives at `/data/hermes/memlawb-data` on the bcache pool; `memlawb-backup.timer` syncs it to garage S3 daily 04:00 (`Persistent=true`); `curl -s -o /dev/null -w '%{http_code}' http://100.76.105.73:8080/health` → `200`; `grep -rl 'provider: memlawb' ~/.hermes/profiles/*/config.yaml | wc -l` → `18`; zephyr's default `~/.hermes/config.yaml` contains **zero** occurrences of the string `memlawb`. The retired MCP-era instruction still reads textually in `homelab-ops/omarchy/nexus/README.md` (`mcp_servers.memlawb.env.MEMLAWB_URL`) — it is stale; the provider config is the mechanism.

**Monitoring**: VictoriaMetrics k8s stack in the `monitoring` namespace (`vmsingle`, `vmagent`, `vmalert`, `vmalertmanager`, `vmauth`, `vlsingle`, Grafana, kube-state-metrics, node-exporter on all four nodes, `blackbox-exporter`) + **`alertmail-relay`** (branded alert email; its degraded state is now watched by VMProbe `alertmail-relay-configured` and alert `AlertMailDeliveryDegraded` — see `homelab-ops/SECRETS.md` rule 2). Host-level: watchdog scripts committed in `homelab-ops/scripts/` (`watcher-watchdog.sh` = dead-man switch for the self-healing watchers, `cluster-watchdog.sh`, `rate-limit-watcher.sh`, `fleet-desk-watch.sh`) and **`oracle-idle-watch` on sentry** (`homelab-ops/omarchy/sentry/bin/oracle-idle-watch`) which owns spend + instance-lifecycle alerting for the Oracle VPS (100.64.0.2). The Oracle VPS deliberately has **no metrics stack** — the LAN Prometheus cannot reach it (different tailnets), so one owner per failure mode. **Scheduling, verified 2026-09-23:** zephyr's cron store holds **zero** jobs *by design*. The 22 job definitions that lived there (including the supervision class) were retired on 2026-09-22, with the full set snapshotted at `deploy/hermes-crons/zephyr-jobs.json` (trading repo) and the restore path in `deploy/hermes-crons/README.md`; see `docs/AUTONOMY-ROADMAP.md` M2. So **if a job runs, it runs on nexus or another host** — check per host with `hermes cron list --all`. A job that is "missing" on zephyr is not a finding.

## How state is delivered today

The distinction that caused real confusion today: **k8s is reconciled from git; host-level config is not.**

| Layer | Mechanism | Reconciled automatically? |
|---|---|---|
| k8s workloads | Git → **ArgoCD** (`argocd` ns, ~100 Applications) rendering **Helm** charts from `media-k8s`, `trading-k8s`, `mining-k8s`, `sites-k8s`, `haven-k8s`, `activepieces-k8s`, `astral-key`, `quill`, plus upstream chart repos (longhorn, victoriametrics, media-servarr, tailscale, pihole, metrics-server) | **Yes** — ArgoCD syncs from git and surfaces drift (`argocd-self` was `OutOfSync` at verification time) |
| Container images | build on nexus (docker) → `k3s ctr images import` → digest pin committed in git → ArgoCD rolls it out | **No** — the import/pin is a manual scripted step (`quill/scripts/pin-images.sh`) |
| Host-level state (Omarchy hosts) | committed tree + idempotent `apply.sh` per host in **`homelab-ops/omarchy/<host>/`** (nexus, zephyr, sentry, oracle-vps) | **No** — *no ArgoCD Application tracks `homelab-ops` (verified: 0 matches for that repoURL)*. Edit → commit → someone runs `apply.sh` on the host. Never hand-edit the live files. |
| Cluster-adjacent repos | `Reverb-OS` (cluster), `nixos-config` (retired legacy), `nixos-secrets` (secret store) | n/a — no deploy pipeline for Reverb-OS; `nixos-config` is retired |
| Secrets | SOPS + age store `nixos-secrets` → per-consumer render (k8s Secret, host env file, process env) | **Partly** — k8s secrets are applied per project; Oracle VPS files and several host scripts are hand-placed (gaps listed in `homelab-ops/SECRETS.md`) |
| Memory | memlawb MemoryProvider plugin → nexus systemd unit, tailnet-only :8080 | n/a — plus `memlawb-backup.timer` (daily 04:00 → garage S3) |
| Observability | VictoriaMetrics stack + alertmail-relay + sentry's oracle-idle-watch + host watchdog scripts | k8s: yes (ArgoCD). Host scripts: **no** (installed by hand / `apply.sh`) |
| Scheduled agent jobs | `hermes cron` (per profile/host) | **No** — not centralised; verify per host with `hermes cron list` |

## Stale premises — do not repeat

| Do not say | Live reality (verified 2026-09-22) |
|---|---|
| "k3s on 4 NixOS nodes" / "krash3 is a node" / "krash3 is a NixOS builder" | 4 nodes, all **Omarchy**: nexus/forge/sentry-agent (control-plane+etcd) + zephyr (agent, cordoned). krash3 is not in the cluster at all. |
| "Host OS: NixOS (Lix). Config at `/etc/nixos`, deployed via Colmena" | No NixOS hosts remain; no `nix`/`colmena` binaries; `/nix` gone. `/etc/nixos` is a symlink into the retired `nixos-config` repo. |
| "Registry: `nexus:5000` (local); images pushed there" | No registry exists. Images are imported into nexus containerd and referenced by digest with `pullPolicy: Never`. |
| "Nix flakes are the source of truth" | Git is. k8s comes from ArgoCD+Helm; host state comes from `homelab-ops` commits + `apply.sh`. |
| "Secrets: decryption keys at `/etc/nixos/.age/`; Yubikey required" | Store is `~/Work/Projects/nixos-secrets`; key material on zephyr at `~/.config/sops/age/cluster-age-key.txt`; 5 recipients (2 YubiKeys + offline break-glass) per the store's `.sops.yaml`. Two YubiKeys are needed for *treasury* keys specifically, not for the store generally. |
| "Cross-session memory is memlawb via `mcp__memlawb__*` MCP tools; front-end `memory` tool disabled" | The MCP bridge is gone (no memlawb entry in `~/.hermes/config.yaml`; the provider package landed 2026-08-26). Memory is a **MemoryProvider**: the `memory` tool is the interface. Per-profile: 18 profiles use `provider: memlawb` at `http://100.76.105.73:8080`; zephyr's **default** profile uses `provider: omh`. |
| "Server: nexus `100.64.11.114:8090`" | Dead. Live is `http://100.76.105.73:8080` (tailnet-only). `100.64.11.114:8090` and the plugin's old `10.1.1.140:8080` both refuse connections. |
| "maplespike exposed via Cloudflare Tunnel + `*.maplespike.lan` through **Traefik**" | No Traefik anywhere. Tunnel lives in the `cloudflared` namespace and maps `quill.maplespike.ca`, `api.maplespike.ca`, `mcp.maplespike.ca`; LAN names are `quill.lan` / `api.quill.lan` / `mcp.quill.lan` served by **`nginx-rp` in `media-reverse-proxy`** (live ingress classes: `nginx`, `tailscale`). The `maplespike` namespace has **no Ingress** — services are NodePort. |
| "Rollout: `kubectl rollout restart deployment/quill-<svc>`" | Rollout = commit the digest pin → ArgoCD app `quill` (repo `reverb256/quill`, path `charts/quill`) syncs. A restart alone changes nothing when the image is digest-pinned. |
| "`hsync --all` after merge" | `hsync` does not exist anywhere on zephyr. Drop it. |
| "Worktrees under `/data/projects/own/`" | `/data` does not exist on zephyr. Use a worktree next to the repo (e.g. `~/Work/Projects/<repo>-NNN`). |

## Repository Index

Verified shapes (2026-09-23): **77 top-level entries — 74 directories, 3 files (`AGENTS.md`, `knowledge.md`, `mise.toml`), 58 git repos.** `knowledge.md` (sibling doc) was last written 2026-08-27 and still carries the retired NixOS/krash3 premises — trust this file over it for infrastructure.

**Infra / GitOps repos (what actually runs the fleet):**

| Repo | Role | Live evidence |
|------|------|---------------|
| `homelab-ops/` | Host-level source of truth: per-host `omarchy/<host>/{apply.sh,systemd/,…}`, `scripts/`, `runbooks/`, `SECRETS.md`, `tests/`, `cloudflare/`, `mcp/` | remotes: `origin https://github.com/reverb256/homelab-ops.git` + `gitlawb`. **No ArgoCD app tracks it.** |
| `media-k8s/` | Main ArgoCD chart home: cluster addons (`argocd-self`, `calico-tigera`, `cloudflared`, `metallb-*`, `system-upgrade-controller`, `monitoring-rules`, `media-reverse-proxy`, `default-requests`, `voice-models`), media apps, longhorn jobs, nginx-rp configmap | ~35 ArgoCD apps point at it |
| `trading-k8s/` | The `trading` namespace: daemons + ~40 `py-job`/`py-svc` Applications | app-of-apps (`helm/apps`) |
| `mining-k8s/` | peakminer + llama-server/llama-swap GPU workloads | apps: `peakminer-*`, `llama-*` |
| `sites-k8s/` | `sites` namespace static site serving | apps: `sites-helm`, `sites-static` |
| `haven-k8s/` | Haven in k8s (also answers at `haven.lan`) | app: `haven` |
| `activepieces-k8s/` | Activepieces automation on k8s | app: `activepieces` |
| `quill/` | MapleSpike product; **ArgoCD app `quill` renders `charts/quill` + `values-prod.yaml` into `maplespike`** | Synced/Healthy |
| `astral-key/` | Rust auth microservice + `charts/astral-key`; digest-pinned `docker.io/library/astral-key@sha256:…` | app: `astral-key` |
| `nixos-secrets/` | sops+age ciphertext store (`.sops.yaml` = authoritative recipient list) | 90 secrets (per `homelab-ops/SECRETS.md`) |
| `Reverb-OS/` | Successor to `nixos-config` for cluster config | repo active; **no deploy pipeline** |
| `nixos-config/` | **RETIRED 2026-09-19** — historical reference only | symlinked from `/etc/nixos` |
| `memlawb-for-hermes/` | Hermes MemoryProvider plugin (`memlawb_provider/`) + server | symlinked at `~/.hermes/plugins/memlawb` |

**Product / project repos:**

| Repo | Tech | Purpose |
|------|------|---------|
| `quill/` | pnpm monorepo, TS, Astro | Canadian public data platform (MapleSpike). 14 packages, **207 modules / 184 MCP tools** per its `docs/metrics.json` + runtime registry (the old "175 tools" figure is stale). Has its own AGENTS.md — read it first. |
| `ai-inference-gateway/` | Python FastAPI | AI gateway with model routing, circuit breaker, RAG (Qdrant), MCP broker. Has own AGENTS.md. |
| `maplespike-brand/` | Astro | MapleSpike brand/landing site + consolidated video assets (`media/`). |
| `maplespike-relay/` | TS (pnpm) | Cross-posting content bridge. |
| `maplespike-workers/` | TS (Cloudflare Workers) | Edge API workers. |
| `reverb256.github.io/` | Astro | Personal portfolio site. Has own AGENTS.md. |
| `reverb256/`, `reverb256.dev/` | — | Catch-all personal repo; personal domain site. |
| `hairathome/` | Hugo→Astro | Winnipeg mobile hair stylist site. Has own AGENTS.md. |
| `infrastructure-docs/` | — | Homelab infrastructure documentation. |
| `llama-cpp-turboquant/` | C++ | LLM inference. Has own AGENTS.md. |
| `trovesandcoves/` | React+Vite+TS | Crystal-jewelry showcase (trovesandcoves.ca) → GitHub Pages. |
| `haven/` | — | Self-hosted Discord-alternative chat product (reverb256/Haven). NOT an auth provider. |
| `coreflame-protocol/` | — | AI-consciousness research project. NOT an auth provider. |
| `canada-data-middleware/` | non-git | Canada data middleware (pyproject + src + k8s). Not under version control. |
| `hermes-skills/`, `hermes-infra-skills/`, `hermes-plugins/`, `hermes-profiles/`, `hermes-workspace/`, `hermes-agent-self-evolution/`, `hermes-agent/` | mixed | Hermes skills, infra skills, plugins, profile definitions, workspace fork, self-evolution, and the Hermes source checkout. |
| `comfyui-mcp/`, `evolution-mcp/` | TS/Python | MCP servers. |
| `Frostbite-Gazette/` | TS | RSS/AI journalism platform. The canonical Gazette project. |
| `Local-Cleaning-Service/` | — | Local cleaning service site. |
| `the-genesis-machine/` | — | AI game/simulation project (was `Game/`). |
| `secretspec/`, `secretspec-core/` | Rust (cargo) | Declarative secrets-spec tooling; upstream SecretSpec workspace fork. |
| `site-agency/` | Python (uv) | Lead-sourcing + AI site-generation agency pipeline. Has own AGENTS.md. |
| `helix/` | Nix | Agentic engineering-loop harness. Has own AGENTS.md. |
| `freebuff-flake/` | Nix | Nix flake packaging Freebuff Desktop (AppImage wrapper). |
| `colmena/`, `lix/`, `omarchy/`, `omarchy-migrate/`, `ops-log/`, `cluster-ops/`, `arr-*`, `media-arr-stack/`, `chatterbox-tts/`, `VoxCPM*`, `Wan2.2`, `MMAudio`, `ace-step/`, `fbt-pipeline/`, `fleet-deck/`, `game-overlay/`, `xodus-gaming/`, `roguelite-project/`, `solana-ai-trader/`, `Mosaic/`, `reference-pipelines/`, `research-tmp/`, `self-iteration-engine/`, `trigger-bridge/`, `arr-fix-2026-09-17/`, `_untracked-backup/` | — | Present at top level; purposes not re-verified this pass. **Do not assume a purpose from a name alone** — open the repo (its `AGENTS.md`/`README.md`) before acting. `colmena/` and `lix/` are legacy-NixOS-era checkouts. |

## Workflow (from `/home/j_kro/AGENTS.md` and `/home/j_kro/Work/AGENTS.md`)

**Issue-Driven Pipeline** applies to every repo:
1. Check for an existing issue: `gh issue list --repo reverb256/REPO --label agent-ready --limit 20`
2. No issue? Create one with `gh issue create --label agent-ready` following the `task.md` template.
3. Branch: `git worktree add -b issue-NNN-desc <path>/REPO-NNN main` — pick the worktree path per repo; there is no `/data/projects/own/` on these hosts.
4. PR body must contain `Closes #NNN`. Single PR per task.
5. After merge: nothing to sync — k8s picks it up via ArgoCD if the repo is an ArgoCD source; host changes need `homelab-ops/omarchy/<host>/apply.sh` run on that host. (There is no `hsync`.)

**No Stubs Rule**: full implementations only. Never `pass`, `...`, `TODO`, `NotImplementedError`. Verify with execution.

## Developer Environment

```bash
pnpm build           # TS packages (quill, relay, …)
pnpm test
cargo build / cargo test   # Rust (astral-key, secretspec) — system rustc 1.98.1
uv run pytest        # Python projects
```

**Available on zephyr** (measured 2026-09-22): `gh` 2.101.0, `node` v26.8.2, `just` 1.58.0, `kubectl` 1.37.0, `helm` 4.2.1, `uv` 0.12.17, `cargo` 1.98.1, `docker` 29.8.1, `rg` 15.2.0. **`nix` is not installed** — any `nix develop` / `nix build` instruction you find in repo docs is NixOS-era and will fail here. `pnpm` resolves through mise's shim (`mise ERROR No version is set for shim: pnpm` if the version is not pinned; use the repo's `mise.toml`/`packageManager`).

**Config system**: `.hermes-profile` files in repo roots (single-line profile name). 7 exist: `quill`, `homelab-ops`, `nixos-config`, `Reverb-OS`, `maplespike-brand`, `infrastructure-docs`, `canada-data-middleware`.

**OpenCode**: plugin-only config at `~/.config/opencode/opencode.json` — loads `oh-my-openagent@latest`. No repo-local `opencode.json` except `quill/opencode.json`.

## Cluster Deployments — `maplespike` (live 2026-09-22)

- Workloads, all 1/1: `quill-api`, `quill-mcp`, `quill-portal`, `quill-redis` (`public.ecr.aws/docker/library/redis:8.2.3-alpine`), plus `quill-ingest-*` CronJobs. All pods are pinned to **nexus** (required: the containerd store is per node).
- Images: `docker.io/library/quill-{api,mcp,portal}@sha256:…` with `imagePullPolicy: Never`. The live digests match `quill/charts/quill/values-prod.yaml` (`images.<svc>.digest`). Third-party images are version/digest-pinned.
- Rollout: change → commit (`values-prod.yaml` or chart) → **ArgoCD app `quill`** (repo `reverb256/quill`, path `charts/quill`) syncs automatically. Verify: `kubectl -n argocd get app quill`. For a new build: run `quill/scripts/pin-images.sh` **on nexus**, commit the printed block. Never `kubectl set image`.
- Portal runtime: Python `server.py` on `python:3.13-slim` (not nginx) — unchanged and still true.
- Exposure: **Cloudflare Tunnel** — `cloudflared` Deployment 2/2 in the `cloudflared` namespace, tunnel ingress `quill.maplespike.ca` / `api.maplespike.ca` / `mcp.maplespike.ca` (+ `activepieces.reverb256.dev`, `sites.reverb256.dev`). **LAN**: `quill.lan`, `api.quill.lan`, `mcp.quill.lan` resolve to 10.1.1.120 / 10.1.1.100 and are served by `nginx-rp` in `media-reverse-proxy` (`nginx:1.29-alpine`, TLS secret `media-tls`). There is **no Traefik** and no Ingress object in `maplespike`; the namespace's services are NodePort.
- Public spot-check this pass: `https://quill.maplespike.ca/` → 200; `http://quill.lan/` → 301 (redirect to https).

## Important Paths

| Path | What |
|------|------|
| `/home/j_kro/AGENTS.md` | Global project rules (no stubs, issue-driven workflow, verification gate) |
| `/home/j_kro/Work/AGENTS.md` | Workspace-level rules, tooling inventory, GATES quick reference |
| `/home/j_kro/.config/opencode/opencode.json` | OpenCode config |
| `/home/j_kro/.kube/config` | **The** working kubeconfig (context `default`, server https://10.1.1.120:6443) — `$KUBECONFIG` points at a nonexistent `/etc/rancher/k3s/k3s.yaml` |
| `/home/j_kro/Work/Projects/homelab-ops/` | Host-level source of truth (`omarchy/<host>/apply.sh`, `scripts/`, `runbooks/`, `SECRETS.md`) — applied by hand, not by ArgoCD |
| `/home/j_kro/Work/Projects/nixos-secrets/` | sops+age secret store; `.sops.yaml` = authoritative recipients |
| `/home/j_kro/.config/sops/age/cluster-age-key.txt` | Age key material on zephyr (0600). `keys.txt` alongside it is the YubiKey identity-stub file per `.sops.yaml` |
| `/etc/nixos` → `/home/j_kro/Work/Projects/nixos-config` | **Legacy** symlink; retired NixOS-era config, historical reference only |
| `/home/j_kro/.hermes/config.yaml` | Hermes default-profile config (`memory.provider: omh`) |
| `/home/j_kro/.hermes/profiles/<name>/config.yaml` | Per-profile config; memlawb memory wiring (`memory.provider`, `memory.memlawb.url`) lives here |
| `/home/j_kro/Work/Projects/.archive/` | Archived originals of repos merged during the 2026-07-16 sprawl cleanup |

## Per-Repo AGENTS.md Files

Several repos have their own AGENTS.md with repo-specific guidance. Always check the subdirectory for one; note that several are **stale about the fleet** (they still describe NixOS, Colmena, Traefik, or `nexus:5000`):
- `quill/AGENTS.md` — large; current on image pinning + ArgoCD, **stale** on cluster topology (says "single-node control plane (NixOS, k3s v1.36.1)" and `imagePullPolicy: IfNotPresent`).
- `ai-inference-gateway/AGENTS.md` — model routing, Kelos integration.
- `astral-key/AGENTS.md` — Rust auth microservice structure & commands.
- `reverb256.github.io/AGENTS.md` — portfolio structure (prefer the repo root one over any `astro-portfolio/` variant).
- `hairathome/AGENTS.md` — site commands.
- `nixos-config/AGENTS.md` — **retired**; its banner ("DO NOT START NEW WORK") is the useful part.
- `homelab-ops/omarchy/<host>/README.md` — per-host source-of-truth docs (nexus, zephyr, sentry, oracle-vps). `homelab-ops/SECRETS.md` — secrets control map.
- `Frostbite-Gazette/AGENTS.md`, `site-agency/AGENTS.md`, `helix/AGENTS.md`, `llama-cpp-turboquant/AGENTS.md`, `coreflame-protocol/docs/technical/AGENTS.md`.

## Memory — how to use it

Cross-session memory is provided by a Hermes **MemoryProvider**; the `memory` tool is the interface (there is no memlawb MCP server — that bridge was removed when the provider package landed 2026-08-26).

- **Recall first.** Before asking j_kro to repeat context, recall for the topic. It holds durable facts: preferences, project decisions, conventions, topology, resolved root causes.
- **Save durable facts** — preferences, decisions, conventions, resolved root causes — under namespace `user:j_kro` (markdown keys like `infra/…`, `project/…`, `user/…`). Never secrets.
- **Verify saves** with a recall round-trip.
- **Backend**: memlawb on nexus, tailnet-only `http://100.76.105.73:8080`. Configure per profile (`memory.provider: memlawb`, `memory.memlawb.url`) — **not** via `mcp_servers.memlawb.env.MEMLAWB_URL`, which is the retired MCP-era instruction still textually present in `homelab-ops/omarchy/nexus/README.md`. If it will not connect, check the tailnet route to nexus and the systemd unit on nexus — the plugin's old `10.1.1.140:8080` default is dead, and so is the older `100.64.11.114:8090`.
- Two ways to lose data permanently: rotating the passphrase, or changing the namespace — the AES key is derived from `scrypt(passphrase, sha256("memlawb:" + namespace))` with no re-encrypt tool. The passphrase file carries no trailing newline (65 bytes = 64 chars); always `tr -d '\n'`.

See the `memory/memlawb-memory` skill.

## Quick Diagnostic Commands

```bash
# Cluster health (always name the kubeconfig — $KUBECONFIG is stale)
export KUBECONFIG=/home/j_kro/.kube/config
kubectl get nodes -o wide

# What ArgoCD thinks is deployed, grouped by source repo
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.spec.source.repoURL}{"\n"}{end}' | sort | uniq -c | sort -rn

# Anything not synced?
kubectl get applications -n argocd -o json | python3 -c "
import json,sys
for a in json.load(sys.stdin)['items']:
    s=a['status']; syn=s.get('sync',{}).get('status'); h=s.get('health',{}).get('status')
    if syn!='Synced' or h!='Healthy': print(a['metadata']['name'], syn, h)"

# Pods in maplespike
kubectl get pods -n maplespike -o wide

# Portal health (direct pod, bypass tunnel)
POD=$(kubectl get pod -n maplespike --no-headers -o custom-columns=NAME:.metadata.name | grep portal | head -1)
kubectl port-forward -n maplespike pod/"$POD" 18080:8080 &
curl -sI http://127.0.0.1:18080/

# Tunnel health
kubectl logs -n cloudflared -l app=cloudflared --tail=30 | grep -i 'error\|timeout'

# Image actually in use (compare with quill/charts/quill/values-prod.yaml)
kubectl get pod -n maplespike -l app=quill-portal -o jsonpath='{.items[0].spec.containers[0].image}'

# Public + LAN edge
curl -sI -o /dev/null -w '%{http_code}\n' https://quill.maplespike.ca/
curl -sI -o /dev/null -w '%{http_code}\n' http://quill.lan/

# Memory backend
curl -s -o /dev/null -w '%{http_code}\n' http://100.76.105.73:8080/health   # expect 200
hermes config get memory.provider
```

## Re-verify (the commands this file was checked with)

Run these before trusting the sections above; each one is a live-state probe, not a doc:

```bash
date -u '+%Y-%m-%d %H:%M:%SZ'
kubectl --kubeconfig ~/.kube/config get nodes -o wide            # node set + OS-IMAGE (all Omarchy)
kubectl --kubeconfig ~/.kube/config get ns                        # namespace set
kubectl --kubeconfig ~/.kube/config get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.source.repoURL}{"\n"}{end}' | grep -c homelab-ops   # expect 0
kubectl --kubeconfig ~/.kube/config get svc -A | grep -iE 'registry|harbor|zot'      # expect nothing
kubectl --kubeconfig ~/.kube/config get deploy -n maplespike \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image,PULL:.spec.template.spec.containers[*].imagePullPolicy'
grep -n -A6 '^memory:' ~/.hermes/config.yaml                      # default-profile provider
grep -rn 'provider: memlawb' ~/.hermes/profiles/*/config.yaml | wc -l
grep -rn 'memlawb' ~/.hermes/config.yaml                          # expect nothing (no MCP bridge)
curl -s -o /dev/null -w '%{http_code}\n' http://100.76.105.73:8080/health   # 200
cat ~/Work/Projects/nixos-secrets/.sops.yaml                      # recipients (public keys are not secret)
grep -E '^(NAME|ID)=' /etc/os-release; ls -ld /etc/nixos; command -v nix colmena   # Omarchy; /etc/nixos is a symlink; nix absent
git -C ~/Work/Projects/homelab-ops log --oneline -3; ls ~/Work/Projects/homelab-ops/omarchy/
hermes cron list                                                  # per-host/per-profile; empty on zephyr BY DESIGN (M2 retired all 22 jobs)

# Added 2026-09-23 (the pass that produced this revision)
ls -1A ~/Work/Projects | wc -l; find ~/Work/Projects -maxdepth 1 -mindepth 1 -type d | wc -l   # entry/dir counts (counts drift)
timeout 25 ssh nexus 'systemctl status memlawb-server --no-pager | head -4'         # memlawb unit active on nexus
ssh nexus 'cd ~/Work/trading && git log --oneline -1'                               # canonical repo copy + HEAD
git -C ~/Work/Projects/homelab-ops log --oneline -3                                 # host-level source of truth
kubectl --kubeconfig ~/.kube/config get nodes                                       # 4 nodes; krash3 absent; zephyr SchedulingDisabled
```
