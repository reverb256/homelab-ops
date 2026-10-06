# Open backlog exported from archived repos — 2026-10-06
These four repos were archived on 2026-10-06. Their open issues and pull requests were
frozen read-only by the archive, so every item was exported here before being closed.
Closing a GitHub issue preserves its content; this export exists so the substance also
lives in a repo that is still live and searchable.

## nixos-config
archived 2026-10-06 · 40 open issues · 6 open PRs

### Issues

#### #306 migrate: replace sops-nix/agenix with secretspec across all projects
`reverb256` · 2026-07-23 · 306 · labels: p1, security, agent-ready, secretspec

<details><summary>body</summary>

```
## Summary

Migrate all secret management from sops-nix (64 entries) + agenix (22 entries) to Cachix Secretspec across the entire homelab infrastructure. This is a multi-phase, multi-repo migration already partially scoped at ~/Projects/secretspec/.

---

## Current state

| System | Entries | Repo location |
|---|---|---|
| sops-nix | 64 | `modules/system/sops-secrets-registry.nix` |
| agenix | 22 | `modules/system/agenix-secrets-registry.nix` |
| secretspec (Phase 1) | 49 declared | `~/Projects/secretspec/secretspec.toml` |

**Current delivery:** sops-nix decrypts `.yaml` files at switch time → writes to `/run/secrets/<name>`. Broken secrets (Z.AI, vaultwarden-admin-token) block the entire switch.

**Target delivery:** Secretspec resolves from env/dotenv (Phase 1) → later from sops provider (Phase 2) → later from vault/onepassword (Phase 3). Services consume via `LoadCredentialEncrypted=` from `/etc/credstore/`.

---

## Phase 1 — Complete (already done)

- [x] All 49 secrets declared in `~/Projects/secretspec/secretspec.toml`
- [x] `.env.secrets` + `.env.secrets.example` created
- [x] CI workflow (cargo fmt → clippy → test → secretspec check)
- [x] Provider Rust crate scaffold (`provider-rust/src/secretspec.rs`)
- [x] Phase 4 deploy script (`scripts/phase4-deploy-example.sh`)
- [x] Per-profile `[profiles.*.defaults] providers` blocks added

Whats still needed to close Phase 1:
- [ ] Copy the full `secretspec.toml` from `~/Projects/secretspec/` to `/etc/nixos/secretspec.toml` (currently only has 1 secret: SAMSUNG_TV_TOKEN)
- [ ] Add `hermes skills install reverb256/hermes-infra-skills/secretspec-checkpoint` to track progress

## Phase 2 — SOPS provider (blocked upstream, unblock in-house)

**The gap:** Secretspec cannot read the existing `.age`-encrypted files because there is no SOPS provider.

**Two tracks:**

**Track A — upstream PR #58** (cachix/secretspec sops provider):
- DRAFT since Feb 2026, author `euphemism` unresponsive since Jul 1
- Domen requested "provider credentials" rework — unaddressed
- Unlikely to ship soon

**Track B — in-house crate** (`~/Projects/secretspec/provider-rust/`):
- `SopsFileProvider` scaffold written in `secretspec.rs`
- 36 tests passing
- Needs alignment with cachix/secretspec PR #98 (Secret Provider Protocol v1)
- Once aligned, this becomes a working CLI shim
- Publish as `secretspec-provider-sops`

Priority: Track B. The crate exists; it needs the final mile of protocol alignment.

- [ ] Align `SopsFileProvider` with PR #98 protocol
- [ ] Publish `secretspec-provider-sops` crate
- [ ] Wire into NixOS: add to `environment.systemPackages` on all hosts
- [ ] Wire into `/etc/nixos/pkgs/secretspec-provider-sops/` (package definition exists, hash is correct)
- [ ] Test with one real `.age` file (e.g. `secrets/context7-api-key.age`)

## Phase 3 — Per-secret provider migration

Once Phase 2 lands, migrate each secret from sops:// to its Phase 3 target provider:

| Provider target | Secrets | Notes |
|---|---|---|
| `onepassword://` | AI keys, cloud creds, storage keys, mining keys | Team-accessible |
| `vault://` (via astral-key) | K8s secrets, monitoring, self-hosting | AppRole auth |
| `keyring://` | Low-risk per-host secrets (WiFi PSK, DuckDNS) | Dev workstation only |
| `env://` | CI tokens (GitHub PAT) | CI runtime only |

See `~/Projects/secretspec/migration-matrix.md` for the full per-secret mapping.

## Phase 4 — NixOS runtime

The deploy pattern already exists as `scripts/phase4-deploy-example.sh` and `modules/services/secretspec-example.nix`. The pattern:

1. `secretspec run --profile production` resolves all secrets
2. `systemd-creds encrypt` encrypts each to `/etc/credstore/<name>.cred`
3. Services consume via `LoadCredentialEncrypted=` in their systemd unit

- [ ] Convert all services from `/run/secrets/<name>` to `LoadCredentialEncrypted=`
- [ ] Remove sops-secrets-registry.nix and agenix-secrets-registry.nix
- [ ] Remove sops-install-secrets activation script
- [ ] Clean up `secre
```

</details>

#### #307 refactor: aspect-based module reorganization — organize by feature, not by host
`reverb256` · 2026-07-25 · 307 · labels: agent-ready

<details><summary>body</summary>

```
## Problem

Current module organization is host-centric (modules/ is a flat list of 306 .nix files, hosts/ has 48 files). Adding a new feature requires editing 3-4 host configs. Result: configuration drift, copy-paste bugs, and a high barrier to understanding what each host does.

## Solution

Restructure to aspect-based (feature-based) organization where each module is organized by its function, not by which host it runs on. The community has converged on this pattern — see the "Constellation Pattern" (Alex Rosenfeld, 10+ hosts), "Deferred Module Composition" (vanixiets, 83 modules), and "Import All + Enable" (Kobi Medrish) patterns.

### Key changes:

1. **Feature directories**: `modules/nixos/ai/`, `modules/nixos/services/`, `modules/nixos/hardware/`, `modules/home-manager/shell/`, etc.
2. **Enable-by-default modules**: Each feature module has an `enable` option (default: false). Host configs just toggle features on.
3. **Auto-discovery**: Use `import-tree` or haumea to auto-discover modules instead of manual imports
4. **Host configs become minimal**: Each host config is just `{ imports = [...]; feature.X.enable = true; }` statements
5. **Consolidate module types**: NixOS, home-manager, and library modules separated at top level

### Benefits:
- Add a feature once, all hosts can use it immediately
- Host config diff becomes trivial (compare which features are enabled)
- Module count per category is visible at a glance
- Removes the "edit 4 host files" friction for every change

### Migration path:
1. Create `modules/nixos/` and `modules/home-manager/` directories
2. Wrap existing modules with `enable` options
3. Create `common-modules-list.nix` → `modules/default.nix` as the single import point
4. One host at a time: convert from direct `imports` to feature-enabled style

### References:
- https://blog.arsfeld.dev/posts/2025/06/11/constellation-pattern/
- https://infra.cameronraysmith.net/development/architecture/adrs/0018-deferred-module-composition-architecture/
- https://kobimedrish.com/posts/scaling_nixos_with_import_all_and_enable_pattern/
- https://not-a-number.io/2025/refactoring-my-infrastructure-as-code-configurations/
```

</details>

#### #310 chore: add pre-commit eval gate with git-hooks.nix (nixfmt, statix, deadnix, flake-checker)
`reverb256` · 2026-07-25 · 310 · labels: infra, agent-ready

<details><summary>body</summary>

```
## Problem

Eval errors (like the crush.nix jq syntax error `"providers":,`) currently reach the build server before being caught. The feedback loop is: edit → commit → push → nexus build → **fail 2 minutes later**. A pre-commit gate would catch these in < 1 second.

Additionally, the `.dirty` build hazard (gen 100/101 sentry crash) would be prevented by a pre-commit check that warns about uncommitted changes.

## Solution

Restore and extend the `git-hooks.nix` infrastructure (already partially present in flake.nix):

### Pre-commit checks:

1. **`nixfmt-rfc-style`** — Auto-format all .nix files on commit
2. **`statix`** — Lint Nix code for anti-patterns and unused variables
3. **`deadnix`** — Find dead code in Nix expressions
4. **`flake-checker`** — Verify flake health (unused inputs, etc.)
5. **`nix-instantiate --eval`** — Verify each host config evaluates successfully
6. **`check-git-clean`** — Reject commits from dirty trees (prevents `.dirty` builds)

### Implementation:

1. Add `git-hooks` as a flake input (already done historically)
2. Define hooks in `perSystem.pre-commit.settings.hooks`
3. Wire `pre-commit-check` into `checks` output
4. Add `nix develop` shell hook for local hook installation
5. Configure GitHub Actions to run `nix flake check` on PRs

### Benefits:
- Catch syntax errors before they reach nexus
- Enforce consistent formatting across 491 .nix files
- Prevent `.dirty` build catastrophes (like sentry gen 100/101)
- Faster feedback loop (1s pre-commit vs 2min build failure)

### References:
- https://github.com/cachix/git-hooks.nix
- https://flake.parts/options/git-hooks-nix.html

## Implementation Contract (2026-07-30 scope upgrade)

**Parent:** #333 (M0 deploy safety)

### Acceptance criteria
- [ ] Required pre-commit/evaluation checks run from a clean checkout.
- [ ] A deliberately failing Nix/evaluation fixture causes the required job to exit non-zero.
- [ ] nixfmt, statix, deadnix, flake-checker, and the repository's required flake/evaluation checks have explicit pass/fail reporting.
- [ ] Cache population, SARIF upload, and advisory documentation checks cannot mask correctness failures and are visibly non-blocking where intended.

### Dependencies
- Coordinated by #333.
- Must include the evaluated Kubernetes validation gate needed by #311, without making all migration work a prerequisite for this issue.

### Non-goals
- No broad CI platform rewrite.
- No requirement that optional cache/advisory services be available for a correct change.

### Validation gate
Run the pre-commit gate and `nix flake check` locally; verify failure injection; inspect workflow exit behavior in a disposable branch/fixture.

### Rollback
Revert the workflow/check wiring as one unit while retaining the previous visible validation commands; do not reintroduce silent `continue-on-error` for correctness jobs.

### Related
#311, #309, #308, #333
```

</details>

#### #311 migrate: replace raw K8s YAML with easykubenix NixOS modules
`reverb256` · 2026-07-25 · 311 · labels: enhancement, security, k8s, agent-ready

<details><summary>body</summary>

```
## Summary

Replace all hand-written Kubernetes YAML manifests under `/etc/nixos/k8s/` and `/etc/nixos/kubernetes-manifests/` with easykubenix NixOS modules. This gives us build-time validation against an ephemeral API server, declarative securityContext/resource transformers, kluctl-based deployment with pruning and SOPS secrets, and eliminates the recurring admission-policy fights.

## Current State

### Raw YAML manifests (Tier 1 — immediate)

| File | Issue |
|------|-------|
| k8s/mosaic-identity/deployment.yaml | PVC slow, UID 100 mismatch, admission policy blocks rollout |
| k8s/mosaic-bridges/*.yaml (x4) | Same UID/PodSecurity issues repeated |
| k8s/searxng-*.yaml (x4) | configmap, deployment, ingress, limiter |
| k8s/llama-server-deployment.yaml | Single workload |
| k8s/opencode/deployment.yaml | Single workload |

### Static manifests auto-applied on boot (Tier 2 — bulk)

39 directories under kubernetes-manifests/ applied by k8s-manifest-autoapply.nix. These work but have no build-time validation, no consistent labels, no automated securityContext.

### Hybrid NixOS modules (Tier 3 — Nix + inline kubectl)

- modules/services/mosaic-bridges.nix — declared but unused (bridges run in k8s, not systemd)
- modules/services/mosaic-identity.nix — declared but unused
- modules/services/k8s-secret-sync.nix — sops-to-k8s Secret mapping, bridge credentials never actually synced
- Various other modules that call kubectl directly

## Target Architecture

Nix flake -> easykubenix eval -> MIS module (Deployment + Service) + Bridge module (x4 deployments) + Transformers (securityContext, resources, labels -> all resources) + Secrets via kluctl SOPS -> kluctl deploy script (prune-aware, SOPS-decrypted) -> Validation (ephemeral etcd + apiserver, catches admission policy errors)

Key changes:
- Raw YAML -> NixOS module expressions (same pattern as services.k3s-cluster)
- kubectl apply -> kluctl apply --prune (adds discriminator labels, prunes stale resources)
- sops-nix secret sync -> kluctl SOPS decryption at deploy time
- Admission policy fights eliminated (validation catches at build time)
- Manual runAsUser: 100 / runAsGroup: 101 -> transformer applies to all containers

## Why easykubenix (not kubenix, not plain k3s-nix)

For our stack (NixOS + k3s + SOPS + NVIDIA GPUs), easykubenix + kluctl is the cleanest fit because:
1. It mirrors the NixOS module pattern we already use (services.k3s-cluster)
2. We already have k8s-nix-deploy.nix infrastructure — easykubenix feeds into it
3. kluctl SOPS integration replaces our fragile k8s-secret-sync.nix
4. The transformer system eliminates the runAsUser: 100 problem at source
5. No codegen needed (unlike kubenix which generates types from OpenAPI)

## Migration Plan

### Phase 1: MIS + Bridges (proof-of-concept, ~2 sessions)

1. Add easykubenix flake input
2. Write modules/easykubenix/mosaic-identity.nix — Deployment + Service + PVC (or emptyDir)
3. Write modules/easykubenix/mosaic-bridges.nix — x4 bridge deployments with BRIDGE_TYPE dispatch
4. Add securityContext transformer (runAsUser: 100, runAsGroup: 101, fsGroup: 1000)
5. Add admission-policy compat transformer (initContainers, seccomp, etc.)
6. Generate YAML via nix build, validate against ephemeral API server
7. Deploy with kubectl apply initially, then kluctl
8. Delete k8s/mosaic-identity/, k8s/mosaic-bridges/, modules/services/mosaic-bridges.nix

### Phase 2: Secrets via kluctl SOPS

1. Encrypt bridge credentials with SOPS
2. Wire kluctl preDeployScript to decrypt into k8s Secrets
3. Remove k8s-secret-sync.nix bridge entries (once bridged secrets are in SOPS)
4. Document SOPS onboarding for future secrets

### Phase 3: kubernetes-manifests/ bulk conversion

1. Add global transformers (labels, securityContext, resource limits -> ALL resources)
2. Convert highest-value directories first: ingress-system/, cert-manager/, gpu/, ai-inference/
3. Set up kluctl deploy with discriminator for pruning
4. Measure validation catch rate vs curre
```

</details>

#### #314 feat(nim-proxy): per-model AIMD rate tracking + graduated circuit breaker
`reverb256` · 2026-07-26 · 314 · labels: enhancement, agent-ready

<details><summary>body</summary>

```
## Problem

The nim-proxy currently tracks a single global RPM/TPM target. Different NIM models (GLM-5.2 vs Nemotron vs DeepSeek) have different rate limits. A 429 on GLM-5.2 should not throttle Nemotron traffic.

The circuit breaker is also binary — 5 consecutive failures and it opens for 1 hour. This is too aggressive for transient congestion.

## Required

### Per-model state
- Parse `model` from incoming `/v1/chat/completions` request bodies.
- Maintain a separate `AIMDController` per model (keyed by model ID prefix / normalized name).
- Persist per-model state in the state file.
- `/health` and `/metrics` should show per-model breakdown.

### Graduated circuit breaker
- Replace the binary "5 failures → open 1hr" with a sliding-window approach:
  - Track success/failure in a 5-minute sliding window per model.
  - Pass through at full rate while errors are < 10% of window.
  - Reduce to 50% RPM when 10-25% of requests fail.
  - Reduce to 25% RPM when 25-50% fail.
  - Open circuit (0%) when > 50% fail in the window.
  - Half-open after 5 minutes with a single probe request.
- The `/metrics` endpoint should expose `circuit_state` per model: `closed | degraded_50 | degraded_25 | open`.

## Why

- A single 429 on GLM-5.2 currently halves ALL NIM traffic (cross-model punishment).
- Removing the model thats rate-limited and letting others through gives the agent a chance to complete tasks on NIM instead of falling through the entire provider chain.

## Related
- scripts/nim-proxy.py
- Current binary circuit breaker logic in record_429()
```

</details>

#### #315 feat(nim-proxy): Prometheus metrics, cost ledger, latency tracking
`reverb256` · 2026-07-26 · 315 · labels: enhancement, agent-ready

<details><summary>body</summary>

```
## Problem

The nim-proxy has no persistent observability. Learned state survives in JSON, but there is no way to:
- See how many requests each model handled
- Know how many tokens were consumed per provider
- Track latency (TTFT) to detect NIM degradation before a 429
- Compare cost vs. the fallback chain (Kilo, opencode)

## Required

### Metrics endpoint (`GET /metrics`)
- Per model:
  - `nim_requests_total{model="..."}`
  - `nim_tokens_total{model="..."}`
  - `nim_latency_ms{model="...",quantile="p50|p95|p99"}`
  - `nim_errors_total{model="...",code="429|502|timeout"}`
  - `nim_circuit_state{model="..."} 0|1|2|3` (closed/degraded_50/degraded_25/open)

- Per-provider cost tracking (estimate):
  - `provider_cost_total{provider="nvidia|kilocode|opencode",model="..."}`
  - Cost rates should be configurable via env vars (e.g., `COST_PER_MTOKEN_NVIDIA=2.70`)

- Prometheus text format (not JSON) so a Prometheus server can scrape it.

### Why

Without metrics, you cannot answer:
- "Are we actually hitting the NIM rate limit or is there another problem?"
- "Which tasks cost the most tokens?"
- "Should we route more traffic through Kilo instead of NIM?"

## Related
- scripts/nim-proxy.py
- Hermes provider chain config on sentry
- Potential Prometheus scrape target for cluster monitoring
```

</details>

#### #316 feat(nim-proxy): SSE response streaming for /v1/chat/completions
`reverb256` · 2026-07-26 · 316 · labels: enhancement, agent-ready

<details><summary>body</summary>

```
## Problem

The nim-proxy currently buffers the entire NIM response before returning it to the client. For a long generation (2000+ tokens), the client waits for the full response before seeing any output. This degrades perceived latency (TTFT is fine, but total response time is high).

Hermes and most OpenAI-compatible clients support SSE streaming (`stream: true` in the request body). The proxy should pass through streaming responses.

## Required

- Detect `stream: true` in incoming `/v1/chat/completions` POST bodies.
- When streaming is requested:
  - Forward the request to NIM with `stream: true`.
  - Stream each SSE chunk back to the client as it arrives (do not buffer).
  - Handle connection errors mid-stream gracefully (send error event, close).
- When streaming is NOT requested (default):
  - Keep the current buffered behavior.

## Why

Streaming dramatically reduces perceived latency for the agent. A code generation task that takes 30s to produce 1500 tokens feels instant if tokens arrive as theyre generated. The proxy currently doubles the perceived wait time by buffering the entire response.

## Related
- scripts/nim-proxy.py
- OpenAI SSE format: `data: {"choices":[{"delta":{"content":"..."}}]}`
```

</details>

#### #317 refactor: declare nim-proxy + Hermes provider config in NixOS (not SSH)
`reverb256` · 2026-07-26 · 317 · labels: enhancement, agent-ready

<details><summary>body</summary>

```
## Problem

The NIM proxy (`scripts/nim-proxy.py`), Hermes provider chain (nvidia→nim-proxy→kilocode→opencode-zen→opencode-go→local-sentry), the kanban GitHub sync cron, and the auto-unblock cron were all set up via SSH directly on sentry. They will be lost on the next `colmena apply` — the only thing committed is `scripts/nim-proxy.py`.

## Required

### 1. nim-proxy as a systemd service (`modules/services/nim-proxy.nix`)
- Define `services.nim-proxy = { enable, port, host, ... }`
- Runs `scripts/nim-proxy.py` as a systemd service
- Loads `NVIDIA_API_KEY` from the existing sops/agenix secret
- The existing config at `/home/j_kro/.hermes/profiles/software-factory/` has the provider config

### 2. Per-profile `config` option in `services.hermes`
Currently `modules/services/hermes/default.nix` has per-profile `model`, `provider`, `soul`, `skills` but NOT a full `config` attrset for per-profile `config.yaml`.

The upstream NixOS module (`services.hermes-agent.settings`) supports full deep-merged config, but per-profile overrides need their own option. Add:

```nix
profiles.<name>.config = mkOption {
  type = types.attrs;
  default = {};
  description = "Per-profile config.yaml overrides (deep-merged into root settings)";
};
```

Render this to `$HERMES_HOME/profiles/<name>/config.yaml` in the activation script alongside SOUL.md and skills.

### 3. Declare the software-factory provider configuration
Once #2 exists, declare the provider chain in the Nix module:

```nix
services.hermes.profiles.software-factory = {
  config = {
    model = { provider = "nvidia"; default = "z-ai/glm-5.2"; };
    providers.nvidia.base_url = "http://127.0.0.1:8787/v1";
    providers.nvidia.key_env = "NVIDIA_API_KEY";
    providers.kilocode.base_url = "https://api.kilo.ai/api/gateway";
    providers.kilocode.key_env = "KILO_API_KEY";
    providers.opencode-zen.base_url = "https://opencode.ai/zen/v1";
    providers.opencode-zen.key_env = "OPENCODE_API_KEY";
    providers.opencode-go.base_url = "https://opencode.ai/zen/go/v1";
    providers.opencode-go.key_env = "OPENCODE_GO_API_KEY";
    fallback_providers = [ "nvidia" "kilocode" "opencode-zen" "opencode-go" "local-sentry" ];
    kanban.dispatch_in_gateway = true;
    kanban.dispatch_interval_seconds = 60;
    kanban.auto_decompose = true;
    kanban.auto_decompose_per_tick = 3;
    kanban.orchestrator_profile = "software-factory";
    kanban.default_assignee = "software-factory";
  };
};
```

### 4. Declare the cron jobs in Nix
The `sync-github-to-kanban` and `auto-unblock` crons are currently `hermes cron create` — they need to be declared in `services.hermes.cron` or migrated to the systemd timer pattern.

### 5. Wire secrets
`KILO_API_KEY`, `NVIDIA_API_KEY` are already in the sops/agenix registries. Add `NVIDIA_API_KEY` to the environment files on sentry so the nim-proxy can read `/run/secrets/nvidia-api-key`.

## Implementation order
1. nim-proxy systemd module (15 lines, trivial)
2. Per-profile `config` option in `services.hermes` (~20 lines in `default.nix` + activation script in `data.nix`)
3. Declare the software-factory provider config using the new option
4. Migrate cron jobs into the module

## Current state (SSH-only, will be LOST on deploy)
All on sentry at `~/.hermes/config.yaml` and `~/.hermes/profiles/software-factory/config.yaml`:
- nim-proxy systemd service
- nvidia→kilocode→opencode-zen→opencode-go→local-sentry fallback chain
- kanban dispatch with auto_decompose
- sync-github-to-kanban cron (every 15m)
- auto-unblock cron (every 5m)

## Related
- scripts/nim-proxy.py in this repo (already committed)
- modules/services/hermes/default.nix (profile options)
- modules/services/hermes/data.nix (activation script)
```

</details>

#### #320 epic: k3s HA cluster — join nexus/sentry/forge as control-planes
`reverb256` · 2026-07-26 · 320 · labels: enhancement, epic, blocked, needs-decision

<details><summary>body</summary>

```
k3s cluster has 1 node (zephyr) because:
1. VIP 10.1.1.100 not assigned (keepalived interface was dummy0, fixed to enp38s0 in ceaa0756)
2. k3s encryption key mismatch between nodes
3. Needs colmena deploy on nexus/sentry/forge after VIP is working

Blocks workload distribution and multi-node HA.
## Implementation Contract (2026-07-30 scope upgrade)

**Decision status:** needs an explicit architecture decision before implementation.

### Acceptance criteria
- [ ] Compare the proposed Nexus/Sentry/Forge control-plane join with #323.
- [ ] Define datastore mode, node eligibility, VIP/encryption-key handling, quorum, upgrade, and node-loss behavior.
- [ ] Decide whether this is a distinct phase after cluster formation or a duplicate proposal; link the canonical issue.
- [ ] Provide a rollback path to the current topology before any multi-control-plane change.

### Dependencies
- Blocked by the M3 topology decision; evaluate #220 only after embedded/alternative datastore requirements are known.

### Non-goals
- No control-plane join or datastore migration before the decision and recovery rehearsal.
- No assumption that every node is suitable as a control plane because it exists in the fleet.

### Validation gate
Architecture decision record, Nix/K3s evaluation, quorum/failure matrix, and non-production rehearsal plan.

### Rollback
Keep the current control-plane topology intact until a reversible migration and tested recovery path are approved.

### Related
#323, #220, #211, #213, #246
```

</details>

#### #323 epic: multi-node k3s cluster (VIP + encryption key)
`reverb256` · 2026-07-26 · 323 · labels: enhancement, agent-ready, epic, blocked, needs-decision

<details><summary>body</summary>

```
k3s cluster has only zephyr. Nexus/sentry/forge are configured as servers in Nix but cannot join because:
1. VIP not assigned (keepalived interface was dummy0, fixed to enp38s0 in ceaa0756, needs deploy)
2. Encryption key mismatch on Calico secrets
3. Needs colmena deploy on all hosts after VIP works
## Implementation Contract (2026-07-30 scope upgrade)

**Decision status:** needs an explicit architecture decision before implementation.

### Acceptance criteria
- [ ] Compare this VIP/encryption-key cluster-formation proposal with #320's control-plane HA proposal.
- [ ] Record the intended control-plane topology, node roles, VIP ownership, encryption-key lifecycle, quorum/failure assumptions, and rollback strategy.
- [ ] Select a canonical issue or explicitly define formation versus hardening phases; link #220, #211, #213, #242, and #246 as dependencies where applicable.
- [ ] Do not claim HA readiness until a non-production failure/recovery rehearsal is defined.

### Dependencies
- Blocked by the M3 topology decision; related to #320.

### Non-goals
- No implementation changes while the topology decision is unresolved.
- No external etcd deployment by implication; evaluate #220 separately.

### Validation gate
Written architecture decision, evaluated Nix/K3s plan, quorum/VIP failure matrix, and a reversible rehearsal plan.

### Rollback
Decision-only issue: preserve the current single-control-plane deployment until an approved topology and recovery path exist.

### Related
#320, #220, #211, #213, #242, #246
```

</details>

#### #324 feat(secretspec): end-to-end sops:// validator + creds on all hosts
`reverb256` · 2026-07-26 · 324 · labels: enhancement, infra, security, secretspec

<details><summary>body</summary>

```
## Summary
Wire SecretSpec end-to-end: cluster fork with sops:// provider, systemd validator on all hosts, fixed secret refs, UTF-8 k3s encryption key, working `just secretspec-check`.

## Acceptance
- [x] `secretspec check -P production` → 0 missing (with fork + age key)
- [ ] `secretspec-validator.service` active on zephyr after switch
- [ ] `secretspec-creds.service` still writes `/run/secrets/*`
- [ ] Deployed to nexus/forge/sentry
- [ ] `just secretspec-check` works from clean shell

## Notes
Validator previously failed with `Provider backend 'sops' not found` because the unit lacked SECRETSPEC_SOPS_PROVIDER_BIN, SOPS_AGE_KEY_FILE, and sops on PATH.
## Implementation Contract (2026-07-30 scope upgrade)

**Parent:** M1: Secrets & Trust

### Acceptance criteria
- [ ] All intended hosts have the declarative secretspec validator/credentials wiring.
- [ ] The `sops://` provider path is exercised end-to-end and its subprocess/fork prerequisites are explicit.
- [ ] Age-key path, provider binary, profile, and runtime secret outputs are validated on each target class.
- [ ] Failure behavior is safe: missing keys/provider failures stop activation rather than silently producing empty or fallback values.

### Dependencies
- Coordinate with #306 as the canonical migration issue.
- Resolve the M0 activation prerequisites in #280 before claiming deployment readiness.

### Non-goals
- No new secrets backend.
- No removal of compatibility code until all required consumers are proven migrated.

### Validation gate
Run the production-profile secretspec check and the local ephemeral age-key end-to-end test; inspect generated service dependencies and runtime secret permissions without printing secret values.

### Rollback
Retain the prior compatible resolver for a bounded transition; revert only the host wiring that fails while preserving encrypted source material.

### Related
#306, #280, #333
```

</details>

#### #341 P0: Canary/rolling deploys with post-switch health probe + auto-rollback
`reverb256` · 2026-08-01 · 341

<details><summary>body</summary>

```
## P0: Canary/rolling deploys with post-switch health probe + auto-rollback

### Problem
`just deploy` activates all 4 hosts simultaneously. One bad switch (e.g. the
2026-07-31 nixpkgs tcl-8_6/gettext regression or the 15-min load-75 distributed
build incident) hits every node at once with no verification between hosts.

### Goal
Deploy in a safe rolling order with automated verification and rollback.

### Acceptance criteria
- [ ] New `just deploy-canary` (or `deploy --canary`) that activates hosts in
      order: nexus → forge/sentry → zephyr (per K8s priority + build topology)
- [ ] After each host switch, run a health probe: SSH reachable + `sshd` active
      + key services up (prometheus/caddy on nexus, etc.) within N seconds
- [ ] On probe failure: log the failing host, run `nixos-rebuild rollback`
      (or `switch-to-configuration` of previous generation) automatically
- [ ] Abort remaining hosts when a probe fails (fail-stop, no cascade)
- [ ] `just deploy` (all-at-once) remains for explicitly-opted-in fast path;
      canary becomes the default for `deploy all`
- [ ] Document in justfile + knowledge.md

### Notes
- Colmena supports `--on <node>`; a wrapper script drives the sequence.
- Reuse `scripts/preflight-check.sh` (G4) before the first host.
```

</details>

#### #342 P1: Deploy provenance + drift detection (commit/lock/closure per host)
`reverb256` · 2026-08-01 · 342

<details><summary>body</summary>

```
## P1: Deploy provenance + drift detection (commit/lock/closure per host)

### Problem
We cannot answer "what is each host actually running right now?" from the repo
alone. Sentry had `.dirty` closures (`…-26.11.20260610.dirty`), and #242
documents repo-vs-disk drift. Recovery required manual `readlink` of profiles.

### Goal
Every deploy records `{commit, flake.lock hash, closure, host, timestamp}`;
`just status` / `just cluster-status` surfaces per-host truth and flags drift.

### Acceptance criteria
- [ ] Deploy wrapper writes a JSON/csv provenance record (host, commit, closure,
      lock hash, time) to a tracked or state file per host
- [ ] `just cluster-status` shows per-host: current closure, generation, commit,
      and whether it matches `origin/main` HEAD
- [ ] Drift detection: a host whose `/nix/var/nix/profiles/system` does not
      match the latest CI-built closure for its commit is flagged
- [ ] `.dirty` suffix detection: any running closure with `.dirty` → warning
      (ties into #310 check-git-clean prevention)
- [ ] Deploy job in CI uploads the provenance artifact (deploy.yml)

### Notes
- Nexus already exposes `nix-serve` (10.1.1.120:50000) — closures are queryable.
- Reuse `just generations` + `just status` primitives.
```

</details>

#### #343 P1: Declarative disk layout (disko) for all hosts + quarterly DR rehearsal
`reverb256` · 2026-08-01 · 343

<details><summary>body</summary>

```
## P1: Declarative disk layout (disko) for all hosts + quarterly DR rehearsal

### Problem
Sentry's btrfs subvolume layout (`@root`/`@nix`/`@persistent`/`@srv` +
`@home`/`@var` on the data disk) existed only on-disk. The 2026-07-31 USB
rescue required reverse-engineering `blkid`/`hardware-configuration.nix`
mid-incident. #242 tracks preservation centralization; this issue makes the
_layout itself_ declarative and testable.

### Goal
Declare every host's disk layout in-repo with `disko` (or a documented
schema), and prove the rescue path works on a schedule.

### Acceptance criteria
- [ ] `disko` config (or explicit schema) for each host: partitions, partlabels,
      subvolumes, ESP/swap — matching `hardware-configuration.nix`
- [ ] A disko VM test in `nixos-test` boots the declared layout end-to-end
      (partitions → mounts → boot) — wired into `checks`
- [ ] `docs/sentry-usb-rescue-recovery-runbook.md` updated to reference the
      declarative schema instead of manual blkid
- [ ] Quarterly DR rehearsal checklist added to justfile (`just dr-rehearsal`)
      — boot a spare host from USB, run recovery end-to-end
- [ ] LUKS/encryption policy documented per disk

### Notes
- Related: #242 (preservation module), #243 (Nexus USB rescue tooling).
- The validated recovery runbook is at
  `docs/sentry-usb-rescue-recovery-runbook.md`.
```

</details>

#### #359 Architecture map: Professional three-layer NixOS platform
`reverb256` · 2026-08-01 · 359 · labels: infra, needs-decision, wayfinder:map

<details><summary>body</summary>

```
## Destination

Produce an implementation-ready architecture specification for a professional-grade `Infrastructure → Platform → Applications/Development` system in `reverb256/nixos-config`, with clear ownership boundaries, one maintainable source of truth, reliable K3s operations, reproducible build/deploy flow, and low-friction development. The map ends when no architectural decisions remain before implementation can begin.

## Notes

Domain: NixOS fleet architecture, K3s platform engineering, deployment/build operations, and developer experience.

Consult the repository research report `docs/NIXOS-ORGANIZATION-RESEARCH-2026-08-01.md`, current `AGENTS.md`, existing NixOS/Colmena conventions, and relevant open issues. Preserve the orthogonal NixOS/Home Manager/nix-profile cadence decision already recorded in the closed three-cadence work; this map defines system ownership layers, not activation cadence.

Standing preferences: explicit and inspectable composition; one source of truth for host facts; typed options; minimal host-name conditionals; Zephyr for authoring; Nexus for builds/dispatch/storage; no imperative drift; no deployment-framework replacement during the architecture refactor.

## Decisions so far

- [Implement Phase 1A typed infrastructure inventory and capability contract](https://github.com/reverb256/nixos-config/issues/370) — canonical typed host inventory now drives NixOS and Colmena; fail-closed parity checks protect the Infrastructure boundary.

- [Research: Current K3s topology and platform boundary](https://github.com/reverb256/nixos-config/issues/360) — Infrastructure/Platform ownership is defined; live K3s topology remains gated pending installed-system verification.
- [Research: NixOS inventory and composition model for this fleet](https://github.com/reverb256/nixos-config/issues/361) — Use explicit host composition plus one validated inventory and typed capability modules.

- [Infrastructure layer contract](https://github.com/reverb256/nixos-config/issues/362) — Infrastructure owns host facts, validated inventory, networking/SSH, recovery, builders, and deployment primitives; K3s/app concerns remain outside it.

- [Platform layer contract](https://github.com/reverb256/nixos-config/issues/363) — Platform owns K3s, API/datastore, fixed endpoint, ingress, registry, storage, runtime secrets, observability, scheduling, and delivery; topology changes remain gated.

- [Applications/Development layer contract](https://github.com/reverb256/nixos-config/issues/364) — Projects own source, flakes/devShells/checks, CI, images, worktrees, and release metadata; infrastructure consumes pinned outputs and platform contracts; migration is contract-first and runtime changes remain gated.
- [Cross-layer interface contract](https://github.com/reverb256/nixos-config/issues/365) — Versioned vocabulary with typed field shapes, producer/consumer graph validation, acyclic source dependencies, explicit data exchange, canonical/external source kinds, unique ownership, and fail-closed compatibility.
- [K3s topology reconciliation evidence gate](https://github.com/reverb256/nixos-config/issues/367) — Effective host declarations are source-checked; candidate VIP/role differences, metadata endpoint drift, missing snapshot/token/readiness proof remain fail-closed blockers.

- [Home Manager three-cadence layer cleanup](https://github.com/reverb256/nixos-config/issues/357) — Shared NixOS/standalone HM leaf composition is restored, Zephyr-only Obsidian is explicit, orphaned HM modules are removed, and Layer-3 cargo remains an explicitly unmodified operational concern.

## Not yet specified

Future work: migrate remaining duplicated K3s/platform/application consumers to the inventory contract after this validator-first slice.

- Exact contracts and dependency direction between Infrastructure, Platform, and Applications/Development.
- Final K3s control-plane/storage/ingress topology and workload placement policy, after installed-system v
```

</details>

#### #378 fix(ai-inference): drop sentence-transformers from default gatewayEnv (closure bloat)
`reverb256` · 2026-08-02 · 378 · labels: bug, infra, priority:high

<details><summary>body</summary>

```
## Problem
`modules/services/ai-inference/default.nix` adds `ps.sentence-transformers` to the
default `gatewayEnv` python env. sentence-transformers transitively pulls the entire
torch stack into the NixOS system closure, causing:
- multi-hour source builds on every host that imports this env
- ROCm configure failures on AMD hosts (Sentry)
- cache misses for the whole python world (see 2026-07-31 incident research)

## Root cause
The default `gatewayEnv` backs only the `ai-inference-status` CLI. The real gateway that
needs sentence-transformers runs in K8s from a prebuilt image
(`nexus:5000/ai-inference-gateway`) using `gatewayPython` (`gateway.nix`), not this env.
The dep was added to the wrong env.

## Fix
Remove `ps.sentence-transformers` from the default `gatewayEnv` so torch stays out of
the NixOS closure. No behavior change for the status CLI.

## Acceptance
- `just check` passes
- torch no longer in the zephyr/nexus closure (`nix why-depends` clean)
- AI gateway K8s deployment unaffected (uses gatewayPython)

Closes #NNN
```

</details>

#### #409 feat(config): data-driven overhaul — host-inventory SSOT + typed service registry + profile assertions
`reverb256` · 2026-08-06 · 409 · labels: enhancement, infra, config-drift

<details><summary>body</summary>

```
## Summary

Make the cluster's configuration more **data-driven**: widen the existing data tables (`contracts/host-inventory.nix`, `kubernetes/service-ports.nix`, `kubernetes/curated-models.nix`) into true single-sources-of-truth, derive wiring (DNS, firewall, Caddy, K8s NodePorts, node profiles) from them, and add eval-time validation via NixOS `assertions`. **Explicitly NOT moving config logic into JSON/YAML** — community consensus is that the Nix module system already is the expert-system layer; external formats are for tooling-facing mirrors only (Nix in, formats out).

This issue is a **follow-up effort to the dendritic migration** (Part of #397; zephyr cutover landed on `main`, nexus/forge/sentry pending). All work here must follow the dendritic conventions locked in #397/#398: feature files self-register `flake.modules.nixos.*`, host files stay thin compositions, no `specialArgs`/`mkIf`-in-imports, registries-as-data live in feature files.

## Why now

Cluster state is declared in **three parallel copies** that can drift:
- IPs/interfaces: `contracts/host-inventory.nix` AND `modules/profiles/node-profiles.nix` defaults AND `hosts/metadata/*.json` mirror
- Service wiring: `kubernetes/service-ports.nix` (ports) vs `modules/network/cluster-dns.nix` (DNS) vs `hosts/zephyr/caddy-routes.nix` + `modules/services/cluster-services.nix` (Caddy) vs K8s manifests (NodePorts)
- Compatibility rules: none — conflicts like GPU-vendor exclusivity are unenforced (2026-07-14 audit style regressions happened precisely because nothing validated cross-file invariants)

## Current data-driven scorecard (already good, keep)

| Registry | Form | Consumed by |
|---|---|---|
| `contracts/host-inventory.nix` (schemaVersion 1) | Nix data | `flake.nix` → Colmena nodes |
| `hosts/metadata/*.json` + `tests/inventory-compliance.nix` | JSON mirror | validated against contract |
| `kubernetes/curated-models.nix` + `ai-models.toml` | Nix primary, TOML secondary | `modules/ai-models.nix` |
| `kubernetes/service-ports.nix` | Nix attrset | Caddy + DNS + K8s |
| `modules/services/mcp-server-registry.nix` | Nix registry | MCP wiring |
| `secretspec.toml` | TOML (60+ entries) | `secretspec check` |

## Plan

### Phase 1 — Host-inventory contract as the single source of host truth
- Widen `contracts/host-inventory.nix` (bump `schemaVersion`): add per-host `profile` ref, firewall ports/ranges, `disableDHCP`, tailscale flags currently hardcoded in `modules/profiles/node-profiles.nix`.
- Make `node-profiles.nix` **read** the inventory instead of re-declaring IPs/interfaces (`networking` defaults become `mkDefault` reads of the contract).
- Generate `hosts/metadata/*.json` from the contract (or delete the mirror and update `tests/inventory-compliance.nix` to eval the contract directly — kill the drift surface).
- **Acceptance:** a literal cluster IP appears in exactly one authoritative declaration; `grep 10.1.1.120` shows contract + generated output only. Adding a 5th host = 1 contract entry (already the flake.nix comment's promise).

### Phase 2 — Typed service registry generating the wiring
- Replace the flat `service-ports.nix` attrset with a typed registry (`lib.types.submodule` per service: `name`, `nodePort`, `servicePort`, `dns`, `protected`, `dependencies`, `hostTarget`).
- One `lib.genAttrs`-driven generator produces: `cluster-dns.nix` records, Caddy routes (zephyr + nexus), firewall `allowedTCPPorts`, and validates K8s manifests' NodePorts.
- **Assertions:** port uniqueness across the whole registry, DNS-name uniqueness, dependency resolution (`dependencies` names must exist).
- Backwards-compat: keep `service-ports.nix` as a thin derived view so existing importers (Helm charts, tests) keep working until migrated.
- **Acceptance:** adding a service = 1 registry entry; a duplicate port fails `nix flake check` with a readable message.

### Phase 3 — Profile compatibility assertions
- New validation module (`modules/profiles/validation.nix`, or a `generic`-cl
```

</details>

#### #415 feat(cache): enforce upstream Hydra/CUDA/ROCm/PyTorch cache compatibility
`reverb256` · 2026-08-07 · 415 · labels: enhancement, infra

<details><summary>body</summary>

```
## Goal
Design NixOS and Home Manager so evaluated derivations maximize reuse of upstream binary caches — Hydra/cache.nixos.org, cache.nixos-cuda.org, CUDA/PyTorch caches, ROCm/project caches, and relevant Cachix caches. The local `reverb-os` cache is only a fallback for intentionally custom artifacts, not the cache-hit target.

## Current problem
The repository currently mixes upstream-compatible packages with global overlays and custom package mutations. This can silently move derivations away from upstream cache paths:

- global `pythonPackagesExtensions` / `overridePythonAttrs` changes;
- global Python overrides in `overlays/python.nix` (`scipy`, `gradio`, etc.);
- global CUDA package mutation (`cudaPackages_12_4.cuda_cudart`, `cuda_compat` workaround);
- global replacement of `llama-cpp` with custom CUDA/ROCm/Vulkan builds;
- patched `webkitgtk`, `caddy`, `assimp`, `dufs`, and hardware packages;
- independently instantiated Home Manager package sets;
- inconsistent substituter/key declarations between `nix-config.nix` and `distributed-builds.nix`.

These changes may be justified, but they must be isolated and classified rather than treated as upstream-cache-compatible.

## Proposed architecture
### 1. Upstream-compatible base package set
Keep the canonical NixOS/HM package set as close as possible to the exact locked nixpkgs package set used by upstream caches:

- one pinned nixpkgs revision;
- no global overrides of protected core/Python/CUDA/ROCm packages;
- no global custom `stdenv`, compiler, glibc, Qt/GTK, or Python fixed-point mutations;
- explicit package configuration only where it does not alter protected derivations.

### 2. Explicit specialized cache package sets
Scope CUDA, PyTorch, ROCm, nix-gaming, and other community cache inputs/package sets explicitly. Document the exact nixpkgs revision, cache endpoint, expected coverage, and consumers. Do not assume that adding a Cachix URL guarantees ROCm/PyTorch coverage.

### 3. Leaf-level custom packages
Expose custom builds with distinct names/arguments such as custom llama.cpp CUDA/ROCm/Vulkan variants, Qwen TTS, faster-whisper, Niri HDR, and patched packages. They may use `reverb-os.cachix.org`, but must not replace globally cacheable packages or contaminate unrelated system/HM closures.

### 4. Lockstep Home Manager
Integrated and standalone Home Manager should use the root flake's canonical package policy and package set. Avoid independently configured HM package sets and make the external HM repository export reusable modules/functions for root-owned instantiation.

### 5. Cache provenance and auditing
Add an offline-first policy/check plus a separate network-dependent `just cache-audit` command. Classify important derivations as:

- `upstream-required`;
- `specialized-cache-required`;
- `intentional-custom`.

Report exact provenance:

- upstream Hydra/cache.nixos.org hit;
- CUDA cache hit;
- community/ROCm/project Cachix hit;
- local custom-cache hit;
- expected miss;
- undeclared miss.

The audit should fail on undeclared divergence in protected upstream-compatible paths, while allowing declared custom misses.

## Acceptance criteria
- One canonical cache/substituter/trusted-key declaration with correct priorities.
- Protected core/Python/CUDA/ROCm derivations are not globally forked by unrelated overlays.
- Custom CUDA/ROCm/PyTorch/llama.cpp variants are explicit leaf packages.
- Integrated and standalone HM use the same package policy.
- Every global override is classified with its expected cache provenance.
- Offline `nix flake check` enforces static/cache-policy invariants.
- Network `just cache-audit` probes configured caches and reports hit/miss provenance.
- Documentation explains that exact derivation identity, not local cache availability, is the objective.

## Scope
No implementation in this issue's filing step. First audit the current derivation graph and cache coverage, then implement in small validated phases.
```

</details>

#### #421 Portable USB map: a rescue/install/pinch/remote stick that drives every GPU
`reverb256` · 2026-08-09 · 421 · labels: wayfinder:map

<details><summary>body</summary>

```
## Destination

A single bootable NixOS USB that (1) rescues any cluster host without formatting (closures into real @nix, boot-entry repair — the validated runbook path), (2) installs/fresh-provisions targets, (3) works standalone as a Niri desktop with full dev tooling in a pinch or over SSH, and (4) drives every GPU on the machine it is plugged into (NVIDIA + AMD/ROCm + Mesa), with a declarative flake artifact and one-command build.

## Notes

- Domain: NixOS USB/rescue/desktop; sibling artifacts: `images/nexus-de-guest.nix` (nixos-generators proven in-repo), `scripts/rescue/*` toolkit + `docs/runbooks/nixos-usb-rescue.md` (the validated rescue path the stick must embed), disko layouts in `hosts/*/disko.nix`.
- Skills every session should consult: `nixos-usb-recovery`, `recover-nixos-host`, `nixos-usb-recovery-build-pipe`, `nixos-boot-recovery`, `nixos-hardware-config-safety`.
- Standing user requirement: **ALL GPUs on the target box usable** — driver stacking is a first-class decision.
- Source-of-truth file: `modules/profiles/portable-usb.nix` (was `portable-usb.nix` skeleton; rebuilt per #426 rot list + #425 contract). Wired as `nixosConfigurations.portable` + `packages.portable-image` in flake.nix. NOT in cluster hive.
- Built on nexus (offloaded), QEMU-boot smoke test passes (reaches `nixos login:` on ttyS0).

## Decisions so far

- [Task: portable stick rot inventory + acceptance checklist](https://github.com/reverb256/nixos-config/issues/426) — **closed 2026-08-09**: inventory verified in `portable-usb.nix` — no build wiring, no lockfile, 6 unpinned `github:` inputs (curl-42 class), nvidia/CUDA hardcoded, `canTouchEfiVariables` wrong for USB, j_kro has no login path, no device layout (explicit stub), `cache.nixos.org` missing from substituters, `scripts/rescue/*` not embedded. 8-gate acceptance checklist drafted (feeds #424/#425). No config changes — deliberate.
- [Artifact research](https://github.com/reverb256/nixos-config/issues/422) — **closed 2026-08-09**: nixos-generators archived Jan 2026 → native `nixos-rebuild build-image --image-variant` + `image.modules` is canonical. Best-fit = **systemd-repart image** (esp + btrfs root + `@nix` store partition via `storePaths`/`nixStorePrefix`), self-contained store carries rescue closures (#243) without NFS. Removable boot = `canTouchEfiVariables=false` + `/efi/BOOT/BOOTX64.EFI` fallback. Persistent > hybrid > stateless; ISO remains as bootstrap sub-artifact.
- [GPU research](https://github.com/reverb256/nixos-config/issues/423) — **closed 2026-08-09**: ONE config with nvidia+amdgpu+Mesa is normal NixOS (modalias autoload; inert on absent hardware). Use the repo's existing `hardware.gpu-compute.nix` universal module — not the zephyr-copy block. `hardware.graphics.enable` replaces legacy `opengl`. Vulkan multi-ICD works out of the box on niri; keep CUDA/ROCm libs out of the global closure unless budget is decided.
- [Decide: portable USB artifact contract](https://github.com/reverb256/nixos-config/issues/425) — **closed 2026-08-09**: decided A-persistent (systemd-repart, ext4 root labeled nixos + inline store) / minimal closure (rescue tools + niri desktop, no cluster hive) / j_kro SSH keys from `mesh-keys.nix` / systemd-boot with removable EFI fallback. Stamped via recommended defaults (user: "proceed as recommended all the way").
- [Prototype: minimal bootable USB](https://github.com/reverb256/nixos-config/issues/424) — **closed 2026-08-09** (`ad11d129`, pushed to main): `modules/profiles/portable-usb.nix` + flake wiring. Persistent systemd-repart image (9.4 GB), all 7 GPUs via gpu-compute, niri+SDDM autologin, j_kro SSH keys, rescue toolkit embedded, built on nexus, QEMU-boot verified. Boot fixes: initrd storage modules, ESP label case, serial console.

## Frontier tickets

- [VM-boot smoke test harness](https://github.com/reverb256/nixos-config/issues/427) — open; prereq so no broken image ships (now satisfied ad-hoc via QEMU; formalize as a `just`/CI check).
- [READ
```

</details>

#### #427 Task: QEMU boot smoke test harness for the portable USB image
`reverb256` · 2026-08-09 · 427 · labels: wayfinder:task

<details><summary>body</summary>

```
**Tracked prerequisite for #424/#421 (wayfinder map).**

Before any portable image can ship, the repo must be able to boot the produced image in QEMU and assert a real login/recovery surface. The repo currently has eval-only tests (`tests/*.nix`, no VM boot test).

**Acceptance:**
1. A `just portable-smoke` recipe boots the built image in QEMU (UEFI firmware, ~2G RAM) and passes if: systemd reaches a boot target, sshd/dhcp or the rescue shell appears on the serial console, and the root filesystem mounts (btrfs `@` + `@nix` visible).
2. Script lives under `scripts/rescue/` or `scripts/portable/` honoring the existing rescue-toolkit shell conventions.
3. It runs on the nexus builder host (never zephyr-local build; zephyr OOM-protected).
4. First run must execute against the #424 prototype artifact — no stub, real serial output captured.

Unblocks: acceptance gate #2 (boots on ≥2 heterogeneous hosts) via VM parity before physical USB testing.
```

</details>

#### #453 feat(zephyr): enable nix use-cgroups + idle daemon scheduling to stop OOM-killing nix builds
`reverb256` · 2026-08-12 · 453 · labels: enhancement, infra, agent-ready

<details><summary>body</summary>

```
## Summary

Zephyr is permanently at the memory edge (30/31Gi used, ~500Mi available) and earlyoom is executing nix builds as fast as something starts them — **4 nix processes SIGTERM'd in 4 minutes on 2026-08-11** (21:10–21:14), including repeated `nix build .#homeConfigurations.zephyr.activationPackage` retries from `~/Projects/home-manager-config-gpu-menu`. systemd-oomd separately marked noctalia + alacritty scopes for killing (didn't execute, luck).

Research shows the modern upstream fix is already 90% plumbed on this host and just needs enabling.

## Evidence (2026-08-11)

```
Aug 11 21:10:24 zephyr earlyoom: SIGTERM nix "nix eval --raw .#homeConfigurations.zephyr.pkgs.cudaPackages_12_8.cudaVersion"  VmRSS 321M
Aug 11 21:14:05 zephyr earlyoom: SIGTERM nix "nix build .#homeConfigurations.zephyr.activationPackage" (hm-build.fSUHfJ3sw2)  VmRSS 688M
Aug 11 21:14:25 zephyr earlyoom: SIGTERM nix "nix build .#homeConfigurations.zephyr.activationPackage" (hm-build.pbth89OWtU)  VmRSS 965M
Aug 11 21:14:45 zephyr earlyoom: SIGTERM nix "nix build .#homeConfigurations.zephyr.activationPackage" (hm-build.3kQF6ouoxg)  VmRSS 1061M
```

- Mem: 31Gi total, ~543Mi available; zram 15.6G zstd, 8.7G data → 2.4G compressed
- earlyoom: `-m12,6 -s50,25 --prefer (Web Content|Isolated Web|nix) --avoid (niri|noctalia|zen|...|hermes|...)`
- systemd-oomd: `MemoryUsedPercent=90, SwapUsedPercent=85`; root slice `ManagedOOMSwap=auto`
- GPU: NVRM `NV_ERR_NO_MEMORY` burst Aug 10 04:36 (ctxBufPoolReserve) — VRAM, separate, VRAM now free

## Root causes

1. **nix builds share the system slice with everything** — `nix-daemon.service` has `OOMScoreAdjust=0`, `Slice=system.slice`. No cgroup isolation means OOM pressure is resolved by killing the biggest process, which earlyoom's `--prefer nix` makes be the build.
2. **`use-cgroups` is not enabled** — `experimental-features = [nix-command flakes]` only. The per-derivation cgroup mechanism (nix#10374, nixpkgs#339310, nix#11412) is merged and `Delegate=yes` is **already set** on this host, but the feature is off.
3. **Builds run at normal CPU/I/O priority** — `daemonCPUSchedPolicy`/`daemonIOSchedClass` use defaults (`other`/`best-effort`); NixOS docs recommend `idle` for interactive desktops.
4. **No bound on `cores`** — `max-jobs = 6` is set, but `cores` is unset (auto → all cores per derivation → make -jN RAM blowups).

## Proposed changes (config-first, nixos-config SPOC)

### 1. Enable per-derivation cgroups (primary fix)

```nix
# modules/system/nix-settings.nix
nix.settings = {
  experimental-features = ["nix-command" "flakes" "cgroups"];
  use-cgroups = true;
};
```

With `Delegate=yes` (already present) + OOMPolicy=continue default, the OOM killer/oomd act on the **leaf derivation cgroup only** — the offending build dies, nix-daemon and the desktop survive. Verified by nix maintainers in nix#10374.

### 2. Idle scheduling for daemon builds

```nix
nix.daemonCPUSchedPolicy = "idle";
nix.daemonIOSchedClass = "idle";
```

Builds only run when nothing else needs CPU/I/O. Explicitly recommended by the NixOS module docs for interactively used computers.

### 3. Bound cores

```nix
nix.settings.cores = 8;  # alongside existing max-jobs = 6
```

Caps per-derivation parallelism (NIX_BUILD_CORES) — kills the `auto × auto` RAM explosion.

### 4. (Optional) earlyoom ignore zram swap%

```nix
services.earlyoom.extraArgs = ["-s" "100"];
```

zram compresses ~3.6:1, so `freeSwapThreshold=50` acts on a misleading signal; MemAvailable is the real one. (Validated against earlyoom manpage: `-s 100` = ignore swap usage.)

## What NOT to change (already correct)

- zram-only (zstd 50%, swappiness 180, page-cluster 0, zswap disabled) — matches nixpkgs#351002 / NixOS wiki guidance
- earlyoom `--avoid` desktop list + gaming slice (`MemoryMax=6G`, `ManagedOOMSwap=off`, `ManagedOOMPreference=avoid`, `OOMScoreAdjust=-1000`) — the 2026-08-03/06 lessons
- unbound `OOMScoreAdjust=-1000`
- GC age+count capping (new nix-gc-prune)

## Ac
```

</details>

#### #463 fix(ai-inference): qdrant StatefulSet blocked 2d14h by require-resources-and-security admission policy
`reverb256` · 2026-08-13 · 463 · labels: bug, infra, k8s

<details><summary>body</summary>

```
## Summary

The `qdrant` StatefulSet in `ai-inference` has never started (2d14h, 0/1). Every pod creation is rejected by the `require-resources-and-security` ValidatingAdmissionPolicy (applied from `kubernetes-manifests/security/require-resources-and-security.yaml`):

```
ValidatingAdmissionPolicy 'require-resources-and-security' with binding
'require-resources-and-security-binding' denied request: All containers must
run as non-root (securityContext.runAsNonRoot: true)
```

## Evidence

- `kubectl get events -n ai-inference` → `FailedCreate` on `qdrant-0`, denial message above
- `kubernetes-manifests/ai-inference/qdrant-deployment.yaml` has `resources.requests` but **no `resources.limits`** and **no `securityContext.runAsNonRoot: true`** — exactly the policy's three requirements (limits, requests, non-root, no privilege escalation)
- PVC `qdrant-storage-qdrant-0` stuck `Pending` (`fast-local-ssd`, WaitForFirstConsumer — first consumer never created)

## Root cause

The qdrant manifest predates the security admission policy. The policy landed (autoapplied from `kubernetes-manifests/security/`), and qdrant was never updated to satisfy it. This is the same drift class as the nix-csi/device-plugin issues found 2026-08-13: manifests written before policies, never reconciled.

## Fix

Add to the qdrant container spec in `kubernetes-manifests/ai-inference/qdrant-deployment.yaml`:

```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
resources:
  requests: { cpu: "200m", memory: "256Mi" }
  limits:   { cpu: "500m", memory: "1Gi" }
```

Qdrant runs as UID 1000 in its official image, so `runAsNonRoot: true` is satisfiable without a custom user.

## Acceptance

- [ ] `kubectl get sts qdrant -n ai-inference` → 1/1
- [ ] `kubectl get pvc qdrant-storage-qdrant-0 -n ai-inference` → Bound
```

</details>

#### #464 security: ai-inference-gateway-secrets contains placeholder keys (autoapplied)
`reverb256` · 2026-08-13 · 464 · labels: bug, security, k8s

<details><summary>body</summary>

```
## Summary

The `ai-inference-gateway-secrets` secret in `ai-inference` namespace is autoapplied from `kubernetes-manifests/ai-inference/ai-inference-gateway-secrets.yaml` and contains **placeholder keys**, not real credentials:

```
zai-api-key = "YOUR_ZAI_API_KEY_HERE"        (base64 WU9VUl9aQUlfQVBJX0tFWV9IRVJF)
api-keys    = "default=sk-rep...-key\n"       (base64 ZGVmYXVsdD1zay1yZXBsYWNlLXdpdGgteW91ci1hY3R1YWwtYXBpLWtleQo=)
```

## Evidence

- Live decode 2026-08-13: `kubectl get secret ai-inference-gateway-secrets -n ai-inference -o jsonpath="{.data}"` decodes to the placeholder strings above
- The YAML file itself says `# API keys for gateway authentication (one per line, format: key-name=sk-xxx)` — it was written as a template
- The file is in the `ai-inference/` autoapply directory and is NOT excluded by the `k8s-manifest-autoapply` filename filter (it matches no `test-|old-|draft-|forge` pattern)

## Impact

Any gateway deployment that mounts this secret authenticates against a fake key. Today the gateway deployments (`gateway-deployment*.yaml`) are not live (only `qdrant` STS exists in the namespace), so this is latent — but the next deploy that brings the gateway up will run with placeholder auth. Additionally two HPAs (`ai-inference-gateway-hpa`, `vllm-inference-hpa`) already target non-existent deployments and emit `FailedGetScale` — see related issue for orphaned HPAs.

## Fix (declarative)

1. Provision real keys via sops/secretspec (`/run/secrets/...`), not base64 in a committed YAML
2. Reference them via `secretKeyRef` + a sops-managed secret, or mount from the secretspec path
3. Add a guard: the file should fail apply (or be excluded) while values are placeholders

## Acceptance

- [ ] `kubectl get secret ai-inference-gateway-secrets -n ai-inference -o jsonpath="{.data.zai-api-key}"` does not decode to `YOUR_ZAI_API_KEY_HERE`
- [ ] No committed YAML contains `YOUR_` / `sk-xxx` / `sk-rep...` placeholders
```

</details>

#### #466 feat(quill): re-add maplespike billing/JWT secrets to secretspec + k8s-secret-sync (removed 2026-08-08, never re-added)
`reverb256` · 2026-08-13 · 466 · labels: infra, security, secretspec

<details><summary>body</summary>

```
## Summary

The MapleSpike/Quill Stripe + JWT secret wiring in `k8s-secret-sync` and `secretspec-creds` was removed on 2026-08-08 and **never re-added**. Two comment sites document the intent:

- `hosts/nexus/secretspec-creds-wiring.nix:57`:
  `# Re-add these entries + the k8s-secret-sync mappings once the real secrets exist under /etc/nixos/secrets/maplespike/ (source: quill repo).`
- `hosts/nexus/services.nix:258`:
  `# Re-add here + in secretspec-creds-wiring.nix once the real secrets are committed under /etc/nixos/secrets/maplespike/.`

## Evidence

- `ls /etc/nixos/secrets/maplespike/` → `No such file or directory` (verified 2026-08-13)
- The k8s-secret-sync unit (fixed 2026-08-13 to ensure namespaces) still has zero maplespike secret mappings
- Quill repo has the actual secretspec source (quill owns image + secret delivery per AGENTS.md)

## Impact

Any quill billing/JWT secret that should sync into k8s does not. If quill deployments rely on these secrets via `k8s-secret-sync`, they get missing-secret errors. This is a follow-up to the 2026-08-08 removal that was explicitly marked "re-add later" and never actioned.

## Fix

1. Provision the maplespike secrets from the quill repo's secretspec into `/etc/nixos/secrets/maplespike/`
2. Re-add the `MISSION_CONTROL_*` / billing / JWT entries in `secretspec-creds-wiring.nix`
3. Re-add the corresponding `k8s-secret-sync` mappings in `services.nix`
4. Verify the sync unit pushes them to the `automation`/`orchestration` namespaces

## Acceptance

- [ ] `/etc/nixos/secrets/maplespike/` exists with real secret files
- [ ] `systemctl start k8s-secret-sync.service` on nexus exits 0 and the mapped secrets exist in the target namespace
```

</details>

#### #642 chore(k3s): post-outage hardening — Casdoor removal, forge secretspec wipe fix, quorum alerting
`reverb256` · 2026-08-15 · 642 · labels: infra, priority:high

<details><summary>body</summary>

```
Follow-ups from the 2026-08-15 cluster outage (etcd quorum loss → fresh empty etcd → recovered from Aug 14 snapshot).

## 1. Drop Casdoor (user decision — "we are dropping casdoor too")
Casdoor is absent from the restored cluster (no namespace/pod). Config still references it:
- `auth.lan` DNS (`modules/network/cluster-dns.nix`), Caddy routes (`hosts/zephyr/caddy-routes.nix`, `hosts/nexus/services.nix` → 127.0.0.1:32556)
- `central-auth.service` (oauth2-proxy, `modules/services/central-auth.nix`) crash-loops: `OIDC discovery 502` (2199+ restarts) — needs disable or replacement (decide: no SSO / Authelia / Keycloak)
- `modules/services/oauth2-proxy-config.nix`, `modules/services/cluster-services.nix` `protected = true` registry, ai-inference `MIDDLEWARE__JWT_AUTH__JWKS_URL`/ISSUER, glance monitor entry, `kubernetes/modules/oauth2-proxy.nix`
- Stale secrets in repo: `k8s/casdoor-hermes-jwt`, casdoor apps in secretspec

## 2. forge /run/secrets wiped by deploys (root cause of the outage trigger)
Evidence: forge's `secretspec-creds.service` wrote 8 secrets at 05:47; after the 06:31 deploy only `storage/` remained (mtime 06:31) — `k3s-cluster-token` gone → k3s `--token-file` missing → crash loop (47 restarts, started Aug 14 ~20:00, same wipe pattern). Nexus unaffected (its k3s unit lacks `--token-file`).
Fix: make `secretspec-creds` re-run after switches (restartTriggers / drop RemainAfterExit pattern) + find what clears the dir.

## 3. nexus k3s unit missing `--token-file`
nexus's deployed k3s.service has NO token flag (relies on generated `server/token`); forge's HAS `--token-file /run/secrets/k3s-cluster-token`. If nexus loses `server/token`, agents cannot rejoin. Make symmetric.

## 4. Quorum-loss alerting
Nodes were `Unknown` for hours; nexus down Aug 11→15 largely unnoticed. Add monitoring (node Ready alert, etcd health, k3s service NRestarts) to the existing Prometheus/Grafana stack.

## 5. Pre-existing cluster issues (observed post-restore, NOT caused by the recovery)
- `local-path-provisioner` CrashLoopBackOff (510 restarts)
- `mosaic-*` pods ImagePullBackOff (orchestration ns)
- `nix-csi` namespace stuck Terminating; `nix-store-hostpath-test` Pending (kube-system)
```

</details>

#### #653 fix(tailscale): consolidate scattered config into one role-based module + harden tailnet
`reverb256` · 2026-08-16 · 653 · labels: enhancement

<details><summary>body</summary>

```
## Problem

Tailscale config is scattered across 5 files with contradictions:

- `modules/services/services.nix:85` sets `TS_ADVERTISE_ROUTES=10.1.1.0/24` globally, but
  `hosts/nexus/configuration.nix:598` + `hosts/nexus/services.nix:131` override to `""` —
  live state shows NOTHING advertised (routes are inert).
- `hosts/sentry/configuration.nix:368` has a legacy `tailscale.enable = true` (pre-module)
  conflicting with `modules/system/tailscale.nix`.
- No tags (`AdvertiseTags: None`) → cannot write role-based ACLs; user-auth nodes have
  expiring keys (headless servers will drop off).
- No auth key → joins were interactive, not declarative.
- `NoStatefulFiltering: True` live → tailscale packet filter OFF, flat trust.
- ACL policy is default-allow — every tailnet device (incl. 2 Android phones) reaches everything.
- `modules/services/ai-inference/auth/tailscale.nix` has dead code: hardcoded `100.64.0.1`
  gateway + disabled nginx block (replaced by caddy).

## Desired

One `services.tailscale-cluster` module (options: `role`, `advertiseRoutes`, `authKeyFile`,
`acceptDns`, `ssh`) + per-host wiring (zephyr=workstation, nexus/sentry=server,
forge=mining, ssh off). sops-managed tagged auth key for declarative non-expiring joins.
`TS_DEBUG_FIREWALL_MODE=nftables` + `trustedInterfaces=[tailscale0]`. Versioned ACL policy
at `docs/tailscale-acl.json` (default-deny, mining=egress-only, phones=no access).

## Acceptance

- `tailscale status` shows each host tagged (`tag:workstation`/`tag:server`/`tag:mining`)
- `tailscale debug prefs` shows NoStatefulFiltering=false, AdvertiseRoutes correct per host
- Forge cannot reach cluster hosts; phones reach nothing; zephyr/nexus/sentry inter-host OK
- New host joins declaratively via sops auth key
- Sentinel legacy `tailscale.enable` + old `TS_` env blocks removed

Plan: `.hermes/plans/2026-08-16_tailscale-hardening-magicdns.md`
```

</details>

#### #655 feat(reverb-os): Omarchy UX on NixOS + HDR Niri at 100% parity
`reverb256` · 2026-08-17 · 655 · labels: enhancement

<details><summary>body</summary>

```
## Summary

Reverb-OS adopts the full Omarchy experience on NixOS with HDR Niri, at 100% feature/theme/plugin parity. Upstream `basecamp/omarchy` is consumed as a pinned flake input; all adaptation lives in `nixos-config/modules/omarchy/`. The shell is Omarchy's own Quickshell QML ported onto Quickshell's native `Quickshell.Niri` plugin (≥ 0.3.0). **iNiR is not used.**

## Architecture

- `inputs.omarchy = { url = "git+https://github.com/basecamp/omarchy"; flake = false; }` — files imported by path interpolation (matches the `home-manager-config` "no modules output" pattern).
- All adaptation under `modules/omarchy/` (`niri-shim/`, `pkg-shim/`, verbatim tiers). Upstream sync = bump the `omarchy` flake.lock rev. No fork, no vendored copy, no divergence to rebase.
- Reverb-OS remains a full secret-stripped mirror of nixos-config (no repo-boundary change).

## Compatibility tiers

| Tier | Surface | Treatment |
|------|---------|-----------|
| 1 | 22 themes, plugin registry/manifest, Hyprland-free plugins, `omarchy` router, `dots` sync, `applications/*.desktop`, manual | verbatim port |
| 2 | 5 QML files (`Quickshell.Hyprland` → `Quickshell.Niri`) + `Style.qml` hyprctl rounding/gaps, ~75 `hyprctl` commands + 25 `omarchy-hyprland-*`, hyprlock/hyprpicker/hyprsunset | Niri re-implementation |
| 3 | `omarchy-pkg-add/drop`, `omarchy-update`, AUR helpers | Nix-backed name parity |

## Phases (one PR per phase)

- [ ] #656 — Foundation: flake input + Tier 1 verbatim + drop iNiR input
- [ ] #657 — Shell port: Omarchy shell on `Quickshell.Niri`
- [ ] #658 — Command re-target: hyprctl → `niri msg`, lock/picker/sunset
- [ ] #659 — Package parity: nix-backed pkg/update commands
- [ ] #660 — HDR validation: HDR + themes + plugins on niri-hdr fork, acceptance on Zephyr

## Non-goals

- No Arch/pacman/AUR runtime, no Hyprland runtime.
- No `Quickshell.Hyprland` shim (Niri-native only, not dual-compositor).
- iNiR and PR #620's iNiR work are retired (flake input removed).
- No changes to upstream `basecamp/omarchy`.

## Reference

- Design: `.plans/2026-08-17-reverb-os-omarchy-fork-design.md`
- Supersedes: #580
```

</details>

#### #656 feat(omarchy): Phase 1 — flake input + Tier 1 verbatim port (themes, router, plugins, dots, apps)
`reverb256` · 2026-08-17 · 656 · labels: enhancement, agent-ready

<details><summary>body</summary>

```
## Task
Add `basecamp/omarchy` as a pinned flake input and wire the Tier-1 verbatim surface (themes, `omarchy` router, Hyprland-free plugins, `dots`, apps, manual) into NixOS. Drop the `snowarch/iNiR` flake input.

## Steps
- [ ] Add `inputs.omarchy = { url = "git+https://github.com/basecamp/omarchy"; flake = false; }` to `flake.nix` + `flake.lock`
- [ ] Create `modules/omarchy/` skeleton (`niri-shim/`, `pkg-shim/`, verbatim tiers)
- [ ] Wire 22 themes (`themes/*/colors.toml`) so `omarchy theme` works
- [ ] Wire `bin/omarchy` router + Tier-1 command metadata (`GROUP_DESCRIPTIONS`)
- [ ] Wire Hyprland-free plugins: clipboard, emojis, menu, osd, polkit, reminders, background, agents, dev-gallery, image-picker
- [ ] Wire `dots` config-sync system
- [ ] Wire `applications/*.desktop` + manual
- [ ] Remove `snowarch/iNiR` flake input (retire PR #620's iNiR work)
- [ ] `just check` passes
- [ ] Smoke test: `omarchy` CLI runs, theme switch applies, on Zephyr

## Hosts Affected
- [x] Zephyr

## Workflow
- [ ] Work in worktree: `git worktree add -b issue-656-omarchy-phase1 /data/projects/own/nixos-config-656 main`
- [ ] Single PR per task; branch `issue-656-omarchy-phase1`
- [ ] Commit messages reference `(#656)`
- [ ] PR body contains `Closes #656`
- [ ] `just check` passes
- [ ] `just deploy` tested on Zephyr
- [ ] PR reviewed before merge (even solo)

## Context
Epic: #655. Tier 1 is verbatim — no Hyprland/Arch coupling — so it proves the flake-input integration model before the hard shell work. iNiR is retired.

## Reference
- Plan file: `.plans/2026-08-17-reverb-os-omarchy-fork-design.md`
- Related: #655 (epic), #580 (superseded), PR #620 (retire)
```

</details>

#### #657 feat(omarchy): Phase 2 — shell port (Omarchy shell on the qml-niri Niri plugin)
`reverb256` · 2026-08-17 · 657 · labels: enhancement

<details><summary>body</summary>

```
## Task
Port Omarchy's shell (`shell/shell.qml` + plugin registry + `shell.json` schema + IPC contract) onto Quickshell's native `Quickshell.Niri` plugin. Keep `shell.json`/`manifest.json`/IPC byte-compatible so themes, plugins, and `dots` work unchanged.

## Steps
- [ ] Package Quickshell ≥ 0.3.0 with the Niri QML plugin
- [ ] Port `shell/shell.qml` + `services/PluginRegistry.qml` to run on Niri
- [ ] Swap the 5 QML files importing `Quickshell.Hyprland` → `Quickshell.Niri`:
  - [ ] `plugins/bar/widgets/Workspaces.qml`
  - [ ] `plugins/bar/widgets/KeyboardLayout.qml`
  - [ ] `plugins/bar/Bar.qml` (focused-monitor routing)
  - [ ] `plugins/services/idle/Service.qml` (idle/lock events)
  - [ ] `Ui/PopupCard.qml` (outside-click focus-grab)
- [ ] Replace `Commons/Style.qml` hyprctl rounding/gaps with Niri equivalents; carry `Commons/Border.qml` `[hyprland]` theme keys verbatim
- [ ] Keep `shell.json` + `manifest.json` + IPC contract identical
- [ ] `just check` passes
- [ ] Smoke test: bar renders, panels summon, themes apply, on niri-hdr fork on Zephyr

## Hosts Affected
- [x] Zephyr

## Workflow
- [ ] Work in worktree: `git worktree add -b issue-657-omarchy-phase2 /data/projects/own/nixos-config-657 main`
- [ ] Single PR per task; branch `issue-657-omarchy-phase2`
- [ ] Commit messages reference `(#657)`
- [ ] PR body contains `Closes #657`
- [ ] `just check` passes
- [ ] `just deploy` tested on Zephyr
- [ ] PR reviewed before merge (even solo)

## Context
Epic: #655. Quickshell ships the Niri plugin natively, so this is a binding swap, not a from-scratch binding. iNiR is not used.

## Reference
- Plan file: `.plans/2026-08-17-reverb-os-omarchy-fork-design.md`
- Related: #655 (epic)
```

</details>

#### #658 feat(omarchy): Phase 3 — re-target hyprctl commands to niri msg
`reverb256` · 2026-08-17 · 658 · labels: enhancement

<details><summary>body</summary>

```
## Task
Re-target the Hyprland-coupled commands to Niri: ~75 `bin/` scripts touching `hyprctl`, 25 `omarchy-hyprland-*` commands, and the hyprlock/hyprpicker/hyprsunset tool replacements.

## Steps
- [ ] Inventory: 75 `hyprctl`-touching commands + 25 `omarchy-hyprland-*` commands → Niri IPC mapping table
- [ ] Re-target workspace/window/monitor commands → `niri msg` equivalents
- [ ] Replace capture/region/QR commands' `hyprpicker` freeze with a Niri-native alternative
- [ ] Replace `hyprsunset` night light with Niri/`wl-gammactl` equivalent
- [ ] Replace `hyprlock` with Niri lock
- [ ] `hyprctl` absent → clear non-zero error + pointer (no silent no-op, no stubs)
- [ ] `just check` passes
- [ ] Smoke test: workspace switch, monitor toggle, screenshot, night light on Zephyr

## Hosts Affected
- [x] Zephyr

## Workflow
- [ ] Work in worktree: `git worktree add -b issue-658-omarchy-phase3 /data/projects/own/nixos-config-658 main`
- [ ] Single PR per task; branch `issue-658-omarchy-phase3`
- [ ] Commit messages reference `(#658)`
- [ ] PR body contains `Closes #658`
- [ ] `just check` passes
- [ ] `just deploy` tested on Zephyr
- [ ] PR reviewed before merge (even solo)

## Context
Epic: #655. Depends on Phase 2 (shell). No `Quickshell.Hyprland` shim — Niri-native only.

## Reference
- Plan file: `.plans/2026-08-17-reverb-os-omarchy-fork-design.md`
- Related: #655 (epic), #657 (Phase 2)
```

</details>

#### #659 feat(omarchy): Phase 4 — nix-backed package commands (name parity)
`reverb256` · 2026-08-17 · 659 · labels: enhancement

<details><summary>body</summary>

```
## Task
Back the Arch-specific package commands with Nix, keeping command names and user-facing behavior identical.

## Steps
- [ ] `omarchy-pkg-add` / `omarchy-pkg-drop` → nix-backed (flake inputs, `nix profile`), same CLI shape
- [ ] `omarchy-update` → flake update + rebuild path
- [ ] AUR helper commands → nix equivalents (or clear errors where no equivalent exists)
- [ ] Preserve `omarchy pkg` group semantics in `GROUP_DESCRIPTIONS`
- [ ] `just check` passes
- [ ] Smoke test: add/remove a package, run update, on Zephyr

## Hosts Affected
- [x] Zephyr

## Workflow
- [ ] Work in worktree: `git worktree add -b issue-659-omarchy-phase4 /data/projects/own/nixos-config-659 main`
- [ ] Single PR per task; branch `issue-659-omarchy-phase4`
- [ ] Commit messages reference `(#659)`
- [ ] PR body contains `Closes #659`
- [ ] `just check` passes
- [ ] `just deploy` tested on Zephyr
- [ ] PR reviewed before merge (even solo)

## Context
Epic: #655. Depends on Phase 1 (router wired). No pacman/AUR runtime — Nix is the only package manager.

## Reference
- Plan file: `.plans/2026-08-17-reverb-os-omarchy-fork-design.md`
- Related: #655 (epic)
```

</details>

#### #660 feat(omarchy): Phase 5 — HDR validation (themes, plugins, acceptance on Zephyr)
`reverb256` · 2026-08-17 · 660 · labels: enhancement

<details><summary>body</summary>

```
## Task
Validate the full port on HDR Niri: HDR correctness, theme/plugin parity, and graphical acceptance on Zephyr's niri-hdr fork.

## Steps
- [ ] Verify HDR output (reference-luminance, Samsung TV stack) with the ported shell running
- [ ] Verify all 22 themes apply and propagate (GTK/Qt/terminal targets)
- [ ] Verify plugin load/summon/hot-reload across all first-party plugins
- [ ] Verify `dots` snapshot/restore/push/pull round-trips
- [ ] Run graphical acceptance suite (port upstream `test/acceptance.d` where applicable)
- [ ] Verify `omarchy` CLI routing/metadata tests (port `test/cli`, `test/shell`)
- [ ] Verify no `hyprctl`/Hyprland runtime remains in the live config
- [ ] `just check` passes; `just deploy` tested on Zephyr

## Hosts Affected
- [x] Zephyr

## Workflow
- [ ] Work in worktree: `git worktree add -b issue-660-omarchy-phase5 /data/projects/own/nixos-config-660 main`
- [ ] Single PR per task; branch `issue-660-omarchy-phase5`
- [ ] Commit messages reference `(#660)`
- [ ] PR body contains `Closes #660`
- [ ] `just check` passes
- [ ] `just deploy` tested on Zephyr
- [ ] PR reviewed before merge (even solo)

## Context
Epic: #655. Depends on Phases 2-4. Final acceptance gate for 100% parity.

## Reference
- Plan file: `.plans/2026-08-17-reverb-os-omarchy-fork-design.md`
- Related: #655 (epic)
```

</details>

#### #687 chore(nixpkgs): bump input to nixos-unstable HEAD e5bdc4a — Hydra cache hits + native noctalia beta.8
`reverb256` · 2026-08-18 · 687

<details><summary>body</summary>

```
## What
Bump the `nixpkgs` flake input from pinned rev `0954f7ee` (2026-07-05, lock `d4079514`) to **nixos-unstable HEAD `e5bdc4a41d4c072fe1e3787eaa0320a384741d44`** (2026-08-18).

## Why
1. **Build for cache hits**: nixos-unstable HEAD is what Hydra is actively building/serving, so closures are prebuilt in the public cache — big win vs compiling from source on the cluster (OOM risk on zephyr).
2. **Native noctalia beta.8**: nixos-unstable HEAD's `pkgs.noctalia` = **5.0.0-beta.8** (verified) with **libical** build dep included. The current pin (beta.6) errors "config_version 12 is newer than supported version 8" because the GUI state file is v12. A src-only override does NOT build (beta.8 needs libical); only a nixpkgs bump provides beta.8's full dep set.

## Change
- flake.nix:12: `rev=0954f7ee...` → `rev=e5bdc4a41d4c072fe1e3787eaa0320a384741d44`
- `nix flake update` to lock
- The concurrent `7d59e76a5` already removed the noctalia override (uses plain `pkgs.noctalia`) — correct once nixpkgs is beta.8.

## Verify
- `pkgs.noctalia.version` == 5.0.0-beta.8
- `nix flake check` across hosts
- daemonPackage builds (cache pull)
```

</details>

#### #702 fix(stylix-bridges): removeStaleNoctaliaThemes omits niri/noctalia.kdl — 7 orphans survive
`reverb256` · 2026-08-18 · 702

<details><summary>body</summary>

```
## Problem

`modules/desktop/stylix-bridges.nix:229` defines `removeStaleNoctaliaThemes`, but its deletion list omits `niri/noctalia.kdl`. That orphan survives every activation.

## Evidence

7 noctalia orphans found on zephyr:

| File | Removed by the activation script? |
|---|---|
| `alacritty/themes/noctalia.toml` | yes |
| `gtk-3.0/noctalia.css` | yes |
| `gtk-4.0/noctalia.css` | yes |
| `qt5ct/colors/noctalia.conf` | yes |
| `qt6ct/colors/noctalia.conf` | yes |
| `btop/themes/noctalia.theme` | yes |
| **`niri/noctalia.kdl`** | **NO — omitted from the list** |

## Fix

Add `niri/noctalia.kdl` to the deletion list in `removeStaleNoctaliaThemes`.

## Root-cause class check

Audit the whole list against what noctalia actually writes. If noctalia gained new theme targets since the script was authored, other paths may also be missing. Fix the class, not just the one reported path.

## Acceptance

- [ ] `niri/noctalia.kdl` added to `removeStaleNoctaliaThemes`
- [ ] Full list re-derived from noctalia's own theme-target set
- [ ] Zero orphans after activation on zephyr
```

</details>

#### #705 feat(boot): adopt UKI (Unified Kernel Images) on cluster hosts — atomic single-file boots + boot assessment
`reverb256` · 2026-08-18 · 705 · labels: agent-ready

<details><summary>body</summary>

```
## Task

Adopt **UKI (Unified Kernel Images)** on the cluster hosts to finish the omarchy-inspired boot-simplification direction: one self-contained EFI binary per generation (kernel + initrd + cmdline + microcode), systemd Boot Assessment (automatic rollback on bad boots), and secure-boot readiness.

## Context

- The pinned nixpkgs already ships full UKI support: `nixos/modules/system/boot/uki.nix` (`boot.uki.*`: name, version, tries, systemd Automatic Boot Assessment).
- The **portable-usb** profile already builds + installs a UKI (`config.system.build.uki` → `/EFI/Linux/<ukiFile>`, systemd-repart image) — proven machinery exists.
- All 4 cluster hosts are on classic systemd-boot today (`boot.loader.systemd-boot`, timeout=0 from boot-tuning.nix). No UKI on cluster hosts.
- Boot tuning series (2026-08-18) already removed loader timeout, quieted console, bounded journald, and decoupled CDI/network services from `graphical.target` — UKI is the next step in the same direction.

## Benefits

- **One file per generation** (`<machine>-<version>.efi`): no separate kernel/initrd/cmdline juggling; the ESP entry is atomic.
- **Automatic Boot Assessment**: `boot.uki.tries` enables boot counting — a kernel that fails to boot N times rolls back automatically (no manual generation pick).
- **Secure-boot foundation**: UKI is the required shape for signed boot (shim/MOK or lanzaboote-style) later — no rework needed if we adopt it.
- **Consistent with boot-tuning**: fewer moving parts in the boot path.

## Risks / considerations

- **ESP space**: each UKI is ~60–100 MB (kernel + initrd embedded). Multiple generations × 4 hosts — watch `boot.loader.efi.efiSysMountPoint` capacity (check with `df -h /boot`).
- **cmdline/microcode changes** require regenerating the UKI (NixOS handles this on rebuild; verify the systemd-boot `uki` wiring does it).
- **Rollback semantics**: confirm `nixos-rebuild rollback` + systemd-boot generation menu still work with UKIs (generations become UKI files).
- **Multi-GPU/quirky hosts**: verify on the least-critical host first (per boot-error-fixes history, sentry/forge have boot quirks — start with the host that has the fewest boot surprises).
- Boot-time measurement baseline exists: `systemd-analyze critical-chain` (used in #665/#690).

## Plan

1. **Measure baseline** on all hosts: `systemd-analyze blame` / `critical-chain` (record numbers in this issue).
2. **Enable UKI on one host** (candidate: forge or nexus — non-desktop, low blast radius), via the systemd-boot UKI option in the pinned nixpkgs (`boot.loader.systemd-boot.uki` / `boot.uki`), generation name + tries.
3. **Verify**: boots clean, `nix flake check` green, `systemd-analyze` before/after, rollback works, ESP fits.
4. **Roll out** to remaining hosts once one host has clean boots across 2–3 generations.
5. Optionally add secure-boot signing (separate issue) once UKI is stable.

## Acceptance criteria

- [ ] All 4 hosts boot via UKI, one EFI file per generation in `/EFI/Linux/`.
- [ ] Boot time not regressed vs baseline (recorded numbers in this issue); aim for improvement from the atomic single-file path.
- [ ] `nixos-rebuild rollback` + systemd-boot generation menu verified on a UKI host.
- [ ] `just check` + `just channel-pin-check` green.
- [ ] `boot.uki.tries` (boot assessment) enabled on at least the first host.
```

</details>

#### #710 feat(omarchy): colors.toml → base16 generator + regenerate host palettes
`reverb256` · 2026-08-18 · 710

<details><summary>body</summary>

```
Omarchy is the palette source of truth; Stylix is the render backend for the surfaces Omarchy can't reach (boot console/plymouth + the HM stylix-bridges). The two are unified by a generator, not hand-maintained mirrors.

**Design** — `docs/reference/omarchy-theme-stylix-integration.md` + the design plan's "Theme system" section.

**Tasks**
- [ ] Write the `colors.toml → base16/base24` generator (field→slot table in the reference doc), with explicit rules for `yellow` vs `bright_yellow` and `accent` (no base16 slot).
- [ ] Regenerate `modules/desktop/themes/osaka-jade.nix` — its core colors already match Omarchy, but 7 shaded slots (base01/03/04/06/07/0F + base24) are hand-interpolated and drift from Omarchy's semantic fields.
- [ ] Leave the 6 non-Omarchy host palettes (copper/ice/ember/amethyst/tangerine/slate) as-is — they're intentional per-host identities.
- [ ] Fix `home-manager-config/modules/fish.nix` hardcoding `SCHEME_FILE=/etc/nixos/modules/desktop/stylix.nix` → a generated file ref.

**Split apply path** (runtime-vs-declarative boundary): `omarchy theme set` applies the session instantly (imperative); the recorded choice re-derives the Stylix layers on the next `home-manager switch` / `just deploy` (declarative).

**Decision recorded**: feed, don't absorb — keep the HM stylix-bridges; Omarchy owns only shell + neovim + vscode.
```

</details>

#### #711 feat(omarchy): downstream fork reverb256/omarchy + channel-as-flake-input distribution
`reverb256` · 2026-08-18 · 711

<details><summary>body</summary>

```
Replace the Phase-1 `flake = false` pin + patch/shims with a downstream fork that maps Omarchy's distribution method onto Nix.

**Design** — design plan "Downstream fork + distribution method" section.

**Structure**
- `reverb256/omarchy` tracks `basecamp/omarchy` (quattro). Branch = channel: `niri-stable` / `niri-rc` / `niri-edge`.
- **Additive niri layer, not in-place patches**: upstream files stay pristine; the fork adds parallel `shell-niri/` + `bin-niri/` trees selected by `OMARCHY_COMPOSITOR=niri`.
- **The fork is a flake** — `packages.<system>.omarchy`, an `overlay`, `nixosModules.default`.

**Behavior**
- `omarchy channel set <stable|rc|edge>` = re-point the flake input + rebuild (data-only, fast) + generation rollback.
- Downstream CI builds `quickshell-niri` + lints the niri QML on every upstream merge, before the cluster consumes.

**Migration**
- [ ] Create the fork.
- [ ] Port `quickshell-niri.patch` (PR #708) + `pkg-shim/` (PR #709) into additive `shell-niri/` + `bin-niri/` trees.
- [ ] Re-point `inputs.omarchy` at the fork; collapse `modules/omarchy/{niri,pkg}-shim/` + `pkgs/omarchy.nix` into a thin enable module.
- [ ] Retire the patch files.

Depends on the Phase 1-4 PRs (#706/#708/#709) merging. Reverses the earlier "no fork" non-goal — see the design plan.
```

</details>

#### #719 fix(ci): secrets-integrity fails on all PRs — harness never passes --arg inputs (broken since 6b3a2c9b)
`reverb256` · 2026-08-19 · 719 · labels: bug

<details><summary>body</summary>

```
## Task

Fix the `secrets-integrity` CI test — it fails on **every** PR and on main's CI Test Automation / Test Suite jobs since commit `6b3a2c9b` (secrets extracted to private flake, 2026-08-18 08:48).

## Root cause (verified by local repro)

The test `tests/secrets-integrity.nix` requires `inputs.nixos-secrets` (private git+ssh flake) to enumerate the secret YAMLs. But both CI harnesses invoke it via `nix-instantiate` passing ONLY `--arg pkgs` — **never `--arg inputs`**:

- `.github/workflows/ci.yml` — Test Suite job (line ~228)
- `.github/workflows/ci-test-automation.yml` — Test Coverage job (line ~50)

So `inputs` defaults to `null` → `sopsFileNamesFromFragments = []` → all 49 referenced secrets "missing" → `allReferencedSecretsExist = false` → `passed = false`. Quick Check passes on PRs because `nix flake check` → `mkCheckWithInputs` DOES pass inputs (and the runner CAN fetch the private repo — proven by Quick Check green on #707/#708/#709).

Repro (local, no build):
- without `--arg inputs`: `totalYamlFilesInPrivateFlake = 0`, `passed = false` ✔ matches CI
- with `--arg inputs '(builtins.getFlake (toString ./. )).inputs'`: `totalYamlFilesInPrivateFlake = 74`, `passed = true` ✔

## Fix

Add `--arg inputs '(builtins.getFlake (toString ./. )).inputs'` to BOTH harness invocations (ci.yml Test Suite + ci-test-automation.yml Test Coverage). No test code change needed.

## Steps

- [ ] Add `--arg inputs '(builtins.getFlake (toString ./. )).inputs'` to the eval invocation in `.github/workflows/ci.yml` Test Suite step
- [ ] Same in `.github/workflows/ci-test-automation.yml` Test Coverage step (both the check and the result-grep invocation)
- [ ] Verify locally: the two-harness eval passes on this branch
- [ ] PR with `Closes #N`
- [ ] Confirm CI Test Suite + Test Coverage green on the PR (runners permitting)

## Why it matters

Blocks every PR (Omarchy stack #706–#709 included). Pre-existing since 2026-08-18; not caused by the Omarchy PRs.
```

</details>

#### #720 fix(ci): secret-scan gitleaks gate fails 100% of runs — 237 historical findings, no diff scoping or allowlist
`reverb256` · 2026-08-19 · 720 · labels: bug

<details><summary>body</summary>

```
## Task

The `secret-scan` workflow (`.github/workflows/secret-scan.yml`) fails on **every** run — PR and main push — with 237 leaks across 9,426 commits. The gate is effectively dead and cannot distinguish new leaks from historical ones.

## Analysis (verified locally with gitleaks 8.30.1 from the store)

- **All 237 findings are in git HISTORY; ZERO at HEAD** (`1a37894a`). Current tree is clean.
- 126 distinct finding commits; the values are a mix of:
  - **Real secrets** (now moved to the private nixos-secrets flake): `AGE-SECRET-KEY-…`/`age1…` (forge config history), GCP key `AIzaSyA…` (env-vars history), hermes API keys (`a304de1a…`) — these are in private-repo history, rotated/retired values live in the private flake.
  - **Placeholders/fixtures**: `Qwen3-4B-Wrist-On-Hermes`, `a3f1d9c7b8e04562a1b3c4d5e6f78901`, `myuser:mypassword` base64, `SOX/compliance` etc.
  - **Doc examples**: `curl … -H "Content-Type…"` README snippets (curl-auth-header rule).
- Root causes: (a) full-history scan (`fetch-depth: 0` + default config, no `.gitleaks.toml`), (b) no baseline mechanism, so the 2026-07 secrets-extraction history can never pass.

## Fix options (recommendation: 1 + 2)

1. **Scope the scan to the PR diff / recent commits** — the gate's job is "no NEW secrets". For PRs: `git diff origin/main...HEAD | gitleaks stdin` or `--log-opts="--all <base>..<head>"`. For main pushes: scan only the pushed range (`--log-opts="<prev>..HEAD"`).
2. **Add a `.gitleaks.toml`** with `[[allowlists]]` for the known fixture/placeholder values and doc-example paths (env-vars, test fixtures, README curl examples, the 6 kubernetes-modules placeholder ids), keeping real-secret detection active for anything new.
3. (Not recommended now) baseline file — commits the 237 secret VALUES into the repo, worse than the status quo.

## Steps

- [ ] Add `.gitleaks.toml` (extend default config; allowlist fixtures + doc paths by path/secret-regex)
- [ ] Update `secret-scan.yml` to scan the PR diff or pushed commit range instead of full history
- [ ] Verify: local `gitleaks` against current HEAD yields 0 findings; against a seeded fake secret yields 1
- [ ] PR with `Closes #N`
- [ ] Confirm secret-scan green on the PR and on a main push

## Why it matters

The gate fails 100% of runs, so any PR (Omarchy stack #706–#709 included) is blocked on a check that main itself fails. This fix makes the gate meaningful again.
```

</details>

#### #722 feat(hermes-serve): declare cluster-wide dashboard on :9119 for desktop Gateways
`reverb256` · 2026-08-20 · 722 · labels: infra, agent-ready

<details><summary>body</summary>

```
## Goal
Declare `hermes serve` (the dashboard backend on port 9119) as a NixOS service on nexus, sentry, and forge, so the zephyr desktop Settings → Gateways page can attach to all 3 over HTTPS (LAN-trusted, basic auth).

This is the **declarative counterpart** to the quick-start that's already running imperatively in the background today (see `~/.hermes/.env` + nohup'd `hermes serve --host 0.0.0.0 --port 9119`). The NixOS module will clobber the imperative one when `colmena deploy` runs on the affected hosts.

## Why now
- zephyr desktop Gateways page requires a running `hermes serve` with username/password on each remote (see https://hermes-agent.nousresearch.com/docs/user-guide/multi-connection-desktop)
- Today only A2A agents at port 9900 exist on the cluster — port 9119 is firewalled on nexus but **no daemon is listening** on any of the 3 homelab nodes
- We need the desktop to discover nexus, sentry, and forge as one-click "Remote gateway" connections

## Scope
- Add `modules/services/hermes-serve/default.nix` — NixOS module that wraps `hermes serve --host <ip> --port 9119` as a systemd unit
- Reads `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`, `HERMES_DASHBOARD_BASIC_AUTH_SECRET` from `~/.hermes/.env`
- User must be `j_kro` (matches existing A2A mesh pattern)
- Per-host enable: nexus, sentry, forge (zephyr = workstation-only, no service)
- Firewalls: open 9119 on the 3 hosts (already open on nexus — verify; add to sentry + forge)
- Credentials: sops-nix wiring via the existing `secretspec-creds-wiring.nix` pattern (or equivalent), so the password lives encrypted at rest
- Follow the cluster's "import credentials into `.env`" pattern used by other services

## Out of scope
- OAuth/Portal provider setup (LAN-trusted — basic auth is fine; OAuth is a future PR)
- Exposing 9119 beyond the LAN (no public ingress)
- Adding `hermes serve` to zephyr (workstation — never runs services)

## Acceptance criteria
- [ ] `just check` passes for nexus + sentry + forge targets
- [ ] On each of those hosts, `systemctl status hermes-serve` is active after `colmena deploy`
- [ ] From zephyr: `curl http://<host>:9119/api/status` returns `{"auth_providers":["basic"], "version":"..."}` (basic auth advertised)
- [ ] zephyr desktop Settings → Gateways can add all 3 with session-token auth
- [ ] Imperial quick-start daemon (started today as background) is killed by systemd activation when the NixOS unit comes up — no port collision

## Risks
- sops-nix wiring complexity for dashboard creds. Fallback: use the existing SOPS key and a dedicated sops file `modules/services/hermes-serve/secrets.yaml`
- Per-host firewall may need merge-update (already in nexus/firewall.nix)
- Session-token storage on the desktop side — out of scope (Electron safeStorage handles that)

Closes #NNN
```

</details>

### Pull requests
- **#706** feat(omarchy): Phase 1 — flake input + Tier-1 verbatim port (#656) — `706` by reverb256 (2026-08-18), branch `issue-656-omarchy-phase1`
- **#707** docs(omarchy): design plan + Phase 3 hyprctl→niri mapping (#655 #658) — `707` by reverb256 (2026-08-18), branch `omarchy-design-docs`
- **#708** feat(omarchy): Phase 2 shell wiring — qml-niri plugin + quickshell-niri (#657) — `708` by reverb256 (2026-08-18), branch `issue-657-omarchy-phase2`
- **#709** feat(omarchy): nix-backed pkg-command shims (Phase 4) (#659) — `709` by reverb256 (2026-08-18), branch `issue-659-omarchy-phase4`
- **#731** chore(deps): bump go.opentelemetry.io/otel/sdk/log from 0.19.0 to 0.21.0 in /pkgs/caddy-with-modules/src — `731` by app/dependabot (2026-09-29), branch `dependabot/go_modules/pkgs/caddy-with-modules/src/go.opentelemetry.io/otel/sdk/log-0.21.0`
- **#732** chore(deps): bump the gomod-caddy group across 1 directory with 3 updates — `732` by app/dependabot (2026-10-05), branch `dependabot/go_modules/pkgs/caddy-with-modules/src/gomod-caddy-a6fa908cde`

## Reverb-OS
archived 2026-10-06 · 1 open issues · 11 open PRs

### Issues

#### #12 Path B: decommission nixos-config — rehome → repoint → archive
`reverb256` · 2026-09-19 · 12

<details><summary>body</summary>

```
Umbrella tracker: retire `reverb256/nixos-config` — Path B (**rehome → repoint → archive**). Owner: Hermes (default profile) directly, per j_kro 2026-09-19.

Plan doc: `docs/plans/2026-09-19-nixos-config-decommission.md` (this repo).

## Why (measured 2026-09-19)

- All hosts run Omarchy. No `/etc/nixos` remains on nexus/forge/sentry; zephyr keeps a clean checkout tracking `main` (last sync: Sep 17) purely as the legacy edit loop.
- The NixOS-era deploy chain is a zombie: nexus has **no `/etc/nixos` checkout, no `/run/nixos-deploy` state, no tmux deploy sessions, no deploy logs** — and **no self-hosted runners are registered** on either repo. Cluster Status has nothing to report.
- Agents still commit to nixos-config (k3s/calico/firewall/secretspec fixes, Sep 15–17) out of muscle memory; every legacy skill + AGENTS.md still points there.
- Live code-level consumer of nixos-config: Reverb-OS's `pkgs/gitlawb` flake input only — and Reverb-OS already carries its own `pkgs/gitlawb` copy (the input is redundant).
- `home-manager-config` (Layer 2) is already self-declared transitional; no `~/.config/home-manager` exists on any host.

## Phase checklist

- [x] **P0** Freeze + audit + redirects: this issue, plan doc, banners on nixos-config README + AGENTS.md.
- [ ] **P1** Kill the last code dependency: drop the `gitlawb` input in Reverb-OS (use local `pkgs/gitlawb`); verify with flake eval on nexus; PR.
- [ ] **P2** Port live ops → `homelab-ops`: workflows (CI Doctor, Cluster Status — rewrite for Omarchy reality; runners are gone, decide re-register vs hosted), `scripts/ci-doctor.sh`, monitoring/backup helpers that remain relevant.
- [ ] **P3** Port live pkgs → Reverb-OS: `caddy-with-modules`, `nix-cache-proxy`, `secretspec/`, `memlawb.nix`, `peakminer.nix`, images (ai-inference-gateway, switchyard, llama-server, kb-mcp, claude-code, opencode) — each with a who-consumes check + eval/build verify.
- [ ] **P4** Repoint consumers + doc sweeps: `hermes-skills-live` (nixos-* skills → current reality), local skills, `infrastructure-docs`, `site-agency/profiles`, AGENTS.md files, `memlawb-for-hermes` refs.
- [ ] **P5** Drop `home-manager-config` input from Reverb-OS; archive `home-manager-config`.
- [ ] **P6** Archive `nixos-config` (read-only; history preserved); final report.

## Ground rules

- Never touch the live Omarchy layer or the running k3s cluster as part of this project.
- Confirm the applied reality of the Sep 15–17 calico/firewall changes (imperative + oplog?) before archiving; port anything still needed into the Omarchy ops flow — do not resurrect the zombie deploy chain.
- Do not archive until Reverb-OS evaluates clean with zero nixos-config inputs.
```

</details>

### Pull requests
- **#3** Bump peter-evans/create-pull-request from 6.1.0 to 8.1.1 — `3` by app/dependabot (2026-08-16), branch `dependabot/github_actions/peter-evans/create-pull-request-8.1.1`
- **#4** Bump gitleaks/gitleaks-action from 2 to 3 — `4` by app/dependabot (2026-08-16), branch `dependabot/github_actions/gitleaks/gitleaks-action-3`
- **#5** build(deps): bump google.golang.org/grpc from 1.82.1 to 1.83.1 in /pkgs/caddy-with-modules/src — `5` by app/dependabot (2026-09-02), branch `dependabot/go_modules/pkgs/caddy-with-modules/src/google.golang.org/grpc-1.83.1`
- **#6** chore(deps): bump the actions group across 1 directory with 5 updates — `6` by app/dependabot (2026-09-07), branch `dependabot/github_actions/actions-c379f311be`
- **#7** build(deps): bump go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc from 0.19.0 to 0.21.0 in /pkgs/caddy-with-modules/src — `7` by app/dependabot (2026-09-17), branch `dependabot/go_modules/pkgs/caddy-with-modules/src/go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc-0.21.0`
- **#8** build(deps): bump go.opentelemetry.io/otel/exporters/otlp/otlptrace from 1.43.0 to 1.45.0 in /pkgs/caddy-with-modules/src — `8` by app/dependabot (2026-09-17), branch `dependabot/go_modules/pkgs/caddy-with-modules/src/go.opentelemetry.io/otel/exporters/otlp/otlptrace-1.45.0`
- **#9** build(deps): bump go.opentelemetry.io/otel/sdk from 1.43.0 to 1.45.0 in /pkgs/caddy-with-modules/src — `9` by app/dependabot (2026-09-17), branch `dependabot/go_modules/pkgs/caddy-with-modules/src/go.opentelemetry.io/otel/sdk-1.45.0`
- **#10** build(deps): bump go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc from 1.43.0 to 1.45.0 in /pkgs/caddy-with-modules/src — `10` by app/dependabot (2026-09-17), branch `dependabot/go_modules/pkgs/caddy-with-modules/src/go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc-1.45.0`
- **#11** build(deps): bump go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp from 1.43.0 to 1.45.0 in /pkgs/caddy-with-modules/src — `11` by app/dependabot (2026-09-17), branch `dependabot/go_modules/pkgs/caddy-with-modules/src/go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp-1.45.0`
- **#14** chore(deps): bump go.opentelemetry.io/otel/sdk/log from 0.19.0 to 0.21.0 in /pkgs/caddy-with-modules/src — `14` by app/dependabot (2026-09-29), branch `dependabot/go_modules/pkgs/caddy-with-modules/src/go.opentelemetry.io/otel/sdk/log-0.21.0`
- **#15** chore(deps): bump the gomod-caddy group across 1 directory with 3 updates — `15` by app/dependabot (2026-10-05), branch `dependabot/go_modules/pkgs/caddy-with-modules/src/gomod-caddy-a6fa908cde`

## Frostbite-Gazette
archived 2026-10-06 · 12 open issues · 0 open PRs

### Issues

#### #1 Add API client library
`reverb256` · 2026-05-16 · 1 · labels: agent-ready

<details><summary>body</summary>

```
## Context\nPROJECT-STATUS.md:112\n\nFrontend src/lib/ needs an API client for real API connections.\n\n## Task\n- Create API client for Cloudflare Worker\n- TypeScript types for requests/responses\n- Error handling\n- Rate limiting support\n\n## Priority\np2\n\n## Estimate\n2h\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

</details>

#### #2 Add TypeScript types
`reverb256` · 2026-05-16 · 2 · labels: agent-ready

<details><summary>body</summary>

```
## Context\nPROJECT-STATUS.md:113\n\nFrontend src/types/ needs TypeScript type definitions.\n\n## Task\n- Article types\n- API response types\n- Config types\n- Shared types with worker\n\n## Priority\np2\n\n## Estimate\n1h\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

</details>

#### #3 Phase 0.5: Connect frontend to real API
`reverb256` · 2026-05-16 · 3 · labels: agent-ready

<details><summary>body</summary>

```
## Context\nPROJECT-STATUS.md:161-167\n\nConnect frontend from mock data to Cloudflare Worker API.\n\n## Task\n- Connect frontend to real API\n- User authentication (Clerk)\n- Real-time voting\n- Search functionality\n- Article detail pages\n- Source management UI\n\n## Priority\np1\n\n## Estimate\n2d\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

</details>

#### #4 Phase 1.0: AI Insights and transparency
`reverb256` · 2026-05-16 · 4 · labels: agent-ready

<details><summary>body</summary>

```
## Context\nPROJECT-STATUS.md:169-175\n\nPost-MVP features for production.\n\n## Task\n- AI Insights\n- Transparency dashboard\n- Email digests\n- Mobile optimization\n- Performance monitoring\n- Error tracking (Sentry)\n\n## Priority\np2\n\n## Estimate\n3d\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

</details>

#### #5 Implement WebAuthn signature verification
`reverb256` · 2026-05-16 · 5 · labels: agent-ready

<details><summary>body</summary>

```
## Context\ncloudflare/worker/src/auth.ts:21\n\nWebAuthn signature verification is not yet implemented.\n\n## Task\n- Implement WebAuthn signature verification\n- Test with real passkeys\n- Add to auth flow\n\n## Priority\np2\n\n## Estimate\n2h\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

</details>

#### #6 Docs-to-Issues Migration — COMPLETE (5 issues)
`reverb256` · 2026-05-16 · 6 · labels: agent-ready

<details><summary>body</summary>

```
## Summary

TODOs from PROJECT-STATUS.md and code migrated to GitHub Issues.

## Issues Created (#1-5)

### Core Infrastructure (2 issues)
- #1: Add API client library (PROJECT-STATUS.md:112)
- #2: Add TypeScript types (PROJECT-STATUS.md:113)

### Phase 0.5 — API Integration (1 issue)
- #3: Connect frontend to real API, auth, voting, search, detail pages (PROJECT-STATUS.md:161-167)

### Phase 1.0 — Production Features (1 issue)
- #4: AI Insights, transparency dashboard, email digests, mobile optimization (PROJECT-STATUS.md:169-175)

### Security (1 issue)
- #5: Implement WebAuthn signature verification (cloudflare/worker/src/auth.ts:21)

## Cross-Repo References

MapleSpike ROADMAP.md Phase 7 tracks Frostbite Gazette integration points as issues #53-58.

**Migration Date:** 2026-05-16
**Co-Authored-By:** Claude Opus 4.7 <noreply@anthropic.com>
```

</details>

#### #7 Use @maplespike/pipeline-core as dependency (replace local ingestion)
`reverb256` · 2026-05-18 · 7 · labels: agent-ready

<details><summary>body</summary>

```
## Context
Migrate from local ingestion code to @maplespike/pipeline-core shared library.

## Background
MapleSpike's pipeline-core package now covers all the data sources FG currently ingests locally. Using it as a dependency eliminates duplicated fetcher/parser code and keeps FG in sync with the latest data sources.

## Tasks
- [ ] Add @maplespike/pipeline-core as dependency in package.json
- [ ] Replace local fetchers with pipeline-core imports
- [ ] Wire story generation to read from pipeline-core public API
- [ ] Test data flow end-to-end
- [ ] Remove redundant local ingestion code
- [ ] Update docs

## Moved from
Originally filed as reverb256/maplespike#54 — FG is the right repo for this work.
```

</details>

#### #8 [MAJOR REFACTOR / DOGFOOD] Full MapleSpike MCP + SDK Migration – Sovereign Data Layer First-Class Consumer
`reverb256` · 2026-05-19 · 8 · labels: refactor, dogfood, maplespike, p1, agent-ready

<details><summary>body</summary>

```
**Ops Manager Directive: Sprint-to-Live Dogfood Phase**

Frostbite Gazette must become the canonical first-class consumer of MapleSpike as **Canada's Sovereign Data Layer — the only one you'll ever need**.

## Background
- MapleSpike now has 50+ MCP tools, Engine (entity resolution/graph/briefs), new modules (SEDAR+, SEDI, CRTC, Bank of Canada, CIPO, UN/WEF/SDG #292, scientific/GeoMet #293, etc.)
- FG currently duplicates some ingestion (see #7). Time for full refactor.

## Acceptance Criteria
- [ ] Replace ALL local fetchers with @maplespike/sdk + MCP calls (use dev namespace endpoints)
- [ ] Wire story/brief generation to MapleSpike Engine briefs + new MCP tools (`sdg_brief`, `sedar_brief`, `narrative_brief`, etc.)
- [ ] Update frontend to consume real-time MapleSpike data (build on #3)
- [ ] Add MapleSpike provenance hashes + citation links in every article
- [ ] Dogfood new corporate/influence/scientific/UN layers in daily curation
- [ ] Remove redundant local code; update PROJECT-STATUS.md
- [ ] Full e2e tests against dev.maplespike.lan

## Ties to MapleSpike
- Closes reverb256/maplespike#304 (test coverage enforcement)
- Leverages #292–307 corporate/UN/scientific modules

**Priority**: p0 · **Labels**: refactor, dogfood, maplespike, p1 · **Milestone**: FG v1 Sovereign Integration
```

</details>

#### #9 [DOGFOOD / CORPORATE] Integrate SEDAR+/SEDI/CRTC/CIPO Deep Modules for Investigative Journalism
`reverb256` · 2026-05-19 · 9 · labels: dogfood, maplespike, p1, corporate, agent-ready

<details><summary>body</summary>

```
**Ops Manager Directive: Corporate Warfare Dogfood**

Directly dogfood MapleSpike's new sovereign corporate modules (from reverb256/maplespike#293, #301, #305–307).

## Scope
- SEDAR+ filings + SEDI insider trades
- CRTC ownership/media concentration
- CIPO patents/trademarks
- Bank of Canada economic signals

## Acceptance Criteria
- [ ] New curation pipelines using MapleSpike MCP tools (`sedar_brief`, `sedi_brief`, etc.)
- [ ] Auto-generate 'Corporate Influence Signals' section in daily briefs
- [ ] Entity graph cross-refs (lobbying ↔ filings ↔ media ownership)
- [ ] Test coverage enforced per MapleSpike #304
- [ ] Public articles showcase sovereign depth vs paid platforms

**Priority**: p1 · **Labels**: dogfood, corporate, maplespike, journalism · **Ties**: reverb256/maplespike#301–307
```

</details>

#### #10 [DOGFOOD / GLOBAL] UN/WEF/SDG + Scientific Data Integration for Narrative Tracking
`reverb256` · 2026-05-19 · 10 · labels: dogfood, maplespike, p1, un-wef-sdg, scientific, agent-ready

<details><summary>body</summary>

```
**Ops Manager Directive: Global Influence + Scientific Moat Dogfood**

Dogfood MapleSpike's UN SDG/WEF + scientific layers (#292, #293, #305).

## Scope
- UN SDG indicators + Canada mappings
- WEF Strategic Intelligence + narrative briefs
- GeoMet climate, OSDP cumulative effects, CSA space data

## Acceptance Criteria
- [ ] MCP-driven `sdg_brief` + `narrative_brief` in story generation
- [ ] New 'Global Agenda Signals' and 'Climate/Scientific Context' sections
- [ ] Full provenance + citation hashing in FG output
- [ ] Test suite for new data flows (enforce #304)

**Priority**: p1 · **Labels**: dogfood, un-wef-sdg, scientific, maplespike
```

</details>

#### #11 [TEST / INFRA / P0] Enforce Comprehensive Test Coverage + CI Dogfood Pipeline for All MapleSpike Integrations
`reverb256` · 2026-05-19 · 11 · labels: dogfood, maplespike, test, infra, p0, agent-ready

<details><summary>body</summary>

```
**Ops Manager Directive: No Untested Dogfood Ever**

Direct child of MapleSpike #304.

## Acceptance Criteria
- [ ] 100% test coverage on all MapleSpike SDK/MCP calls (unit, integration, e2e)
- [ ] CI workflow that runs against dev.maplespike.lan before deploy
- [ ] Smoke tests for new modules (SEDAR+, SDG, GeoMet, etc.)
- [ ] Automated dogfood reports in PROJECT-STATUS.md

**Priority**: p0 · **Labels**: test, infra, dogfood, maplespike
```

</details>

#### #12 chore: Add agent-ready labels to actionable issues for Kelos autonomous pipeline
`reverb256` · 2026-05-19 · 12 · labels: agent-ready

<details><summary>body</summary>

```
## Context

Kelos workspace `frostbite-gazette` now exists in the cluster. For Kelos to pick up issues, they need the `agent-ready` label.

This issue labels actionable open issues in the Frostbite-Gazette repo with `agent-ready` so Kelos's autonomous agents can start implementing them.

If an issue has this label, Kelos will:
1. Clone the repo to the workspace
2. Configure OpenCode with the gateway-routed model config
3. Implement the fix/feature
4. Open a PR

This is a tracking/labeling issue — no code changes.

## Checklist

- [ ] Label actionable issues with `agent-ready`
- [ ] Ensure issue descriptions are crisp enough for autonomous agents
- [ ] Add acceptance criteria where missing
```

</details>

## kelos-infra
archived 2026-10-06 · 8 open issues · 0 open PRs

### Issues

#### #1 feat: integrate pi-pipeline TDD chain and enforcement guards into kagent/kelos
`reverb256` · 2026-05-20 · 1 · labels: agent-ready, certified-ready

<details><summary>body</summary>

```
## Task
Integrate the `pi-pipeline` TDD chain and enforcement guards into `kagent/kelos` to create a self-improving, quality-guaranteed autonomous development system.

## Context for Agent
- **Source of Truth:** The implementation must mirror the patterns in `/data/projects/own/pi-pipeline/`.
- **Core Mechanism:** The system relies on a `.pipeline-state.json` file in the working directory to track the state of the current contribution.
- **Agent Rigor:** Agents must follow the rigid RED-GREEN-REFACTOR cycle. No agent is allowed to "skip" a phase.
- **What to inspect first:** 
  - `pi-pipeline/agents/*.md` for the prompt templates.
  - `pi-pipeline/extensions/pre-code-guard/index.ts` for the `tool_call` and `tool_result` interceptors.
  - `pi-pipeline/extensions/pre-push-guard/index.ts` for the TDD cycle detection and diff-noise logic.
- **What NOT to touch:** Do not modify the macro Issue $\rightarrow$ Branch $\rightarrow$ PR workflow of the main Kelos orchestrator.

## Background
Kelos currently manages the high-level workflow, but the micro-execution lacks the rigor needed to prevent "AI slop". By integrating the `pi-pipeline`'s TDD chain and enforcement gates, we ensure that every change is backed by a failing test, verified at runtime, and reviewed against a strict checklist.

## Scope
### In scope
- **Agent Persona Definitions**: Implementation of the 6 pipeline agents (`scout`, `test-writer`, `implementer`, `refactorer`, `reviewer`, `submitter`) as `.md` personas in `.kelos/agents/`.
- **Chain Orchestration**: A chain definition in `.kelos/chains/contribution-pipeline.md` that enforces the sequential handover between agents.
- **Hard Enforcement Gates**:
  - `pre-code-guard`: Blocks `edit`/`write` until dev environment is active and AI policy checked.
  - `pre-push-guard`: Blocks `push`/`PR` until TDD cycle (FAIL $\rightarrow$ PASS) is detected, formatter ran, and runtime verification is evidenced.
- **Memory Architecture**: Implementation of a three-tier memory system (Working/Recall/Archival) with a consolidation job on session shutdown.
- **Model Routing**: A phase-aware model router that selects the most cost-effective model for the current phase (e.g., cheaper for `refactorer`, high-reasoning for `reviewer`).

### Out of scope
- Modifying existing agent skills.
- Changing the root repository configuration.

## Dependencies
- **Blocks on:** `pi-pipeline` core logic stability.
- **Related issues:** N/A

## Required changes
1. **Persona Implementations**: Create the 6 `.md` files in `.kelos/agents/` using the prompts from `pi-pipeline`.
2. **Chain Definition**: Create `.kelos/chains/contribution-pipeline.md` mapping the output of one agent to the input of the next.
3. **Guard Extensions**: 
   - Implement `pre-code-guard` (intercept `tool_call` for `edit`/`write`).
   - Implement `pre-push-guard` (intercept `tool_call` for `git push`/`gh pr create`).
4. **Memory System**: 
   - Implement the three-tier store in `.kelos/brain/`.
   - Build the `consolidation-job.ts` for session-end learning.
5. **Model Router**: Implement `index.ts` in `.kelos/extensions/model-router/`.

## Acceptance Criteria
- [ ] **TDD Enforcement**: Agent cannot modify code without first producing a `test-result.md` showing a failure.
- [ ] **Runtime Verification**: `impl-result.md` must contain evidence of execution against a real runtime.
- [ ] **Guard Block**: Attempting to edit a file before `nix develop` (or equivalent) is called results in a `BLOCKED` notification.
- [ ] **Push Block**: Attempting to create a PR without a detected RED-GREEN cycle results in a `BLOCKED` notification.
- [ ] **Memory Loop**: Success/Failure of a contribution is automatically written to the "Recall" tier of the brain.

## Reference
- Pattern: `pi-pipeline` TDD Chain.
- Guards: `pre-code-guard` and `pre-push-guard` logic from `pi-pipeline/extensions/`.
```

</details>

#### #2 Configure NVIDIA NIM as primary provider with correct model mapping
`reverb256` · 2026-05-20 · 2 · labels: enhancement, agent-ready

<details><summary>body</summary>

```
## Background
Research on NVIDIA Nemotron 3 Nano 30B A3B model completed.

**Model Specifications:**
- Architecture: Mamba-Transformer Mixture-of-Experts (MoE)
- Parameter Count: 30 billion total, ~3.6 billion active parameters
- Context Length: 1 million tokens (1M)
- Reasoning: ON/OFF switchable with configurable budgets (RLHF-refined, SFT + RLVR + RLHF)
- Open-Source: Weights, training data, and recipes under Open Model License (OML)
- Primary Use-Case: Efficient, low-latency reasoning for agentic AI workloads

**Source:** https://huggingface.co/blog/nvidia/nemotron-3-nano-efficient-open-intelligent-models

## Action Items
- [ ] Update `opencode.json` → `"model": "auto"`, `"enabled_providers": ["nvidia"]`
- [ ] Remove `vercel` provider entry mapping to `nemotron-3-super-120b-a12b`
- [ ] Verify AIG `ai-models.toml` maps `nvidia` → correct NIM model
- [ ] Mask Google models from NIM (set `enabled_providers: ["nvidia"]`)
- [ ] Update sub-agent model references (explore, librarian, etc.)

## Labels
- [ ] `enhancement`
- [ ] `agent-ready`

---
*Created as part of comprehensive model configuration audit*
```

</details>

#### #3 Update sub-agent model references to use available NVIDIA NIM models
`reverb256` · 2026-05-20 · 3 · labels: enhancement, agent-ready

<details><summary>body</summary>

```
## Background
Current sub-agent configuration uses incorrect or unavailable model references including `nvidia/nemotron-3-nano-30b-a3b` (may be unavailable) and `nvidia/gpt-5.4-mini-fast` (non-existent).

## Requirements

**Model Routing Strategy:**
- **Primary:** NVIDIA NIM (`nvidia/nemotron-3-nano-30b-a3b-reasoning`)
- **Fallback:** Google Gemini (only when NIM quota exhausted)
- **Local:** Qwen, Gemma (when external quota unavailable)

**Sub-Agent Model Assignments:**
- **Explore:** `nvidia/nemotron-3-nano-30b-a3b-reasoning` (needs long context for codebase analysis)
- **Librarian:** Fast model (e.g., `gemma-4-e4b-it` or local Qwen)
- **Implementer:** `nvidia/nemotron-3-nano-30b-a3b-reasoning`
- **Refactorer:** Fast model (Tier 1)
- **Reviewer:** `nvidia/nemotron-3-nano-30b-a3b-reasoning` (anti-pattern detection)
- **Submitter:** Fast model (Tier 1, git operations)

## Action Items
- [ ] Update `opencode.json` model configuration
- [ ] Verify AIG `ai-models.toml` routing
- [ ] Test each sub-agent with assigned model
- [ ] Document model selection rationale in `.kelos/agents/` configs

## Labels
- [ ] `enhancement`
- [ ] `agent-ready`

---
*Related: #2 (NVIDIA NIM configuration)*
```

</details>

#### #4 Integrate pi-pipeline TDD chain with context isolation and enforcement extensions
`reverb256` · 2026-05-20 · 4 · labels: enhancement, agent-ready

<details><summary>body</summary>

```
## Background
Integrate pi-pipeline's context-isolated TDD chain into the kagent/kelos workflow to create a self-improving, quality-guaranteed autonomous development system.

## Core Concepts

### 1. Context-Isolated TDD Chain
Six-phase pipeline where each agent only sees what it needs:
1. **SCOUT:** Research issue + AI policy check → `scope.md`
2. **RED (test-writer):** `scope.md` only → failing test
3. **GREEN (implementer):** Test only → passing code
4. **REFACTOR:** Test+code → clean code
5. **REVIEW:** Full diff → `review.md` (APPROVE/REQUEST_CHANGES)
6. **SUBMIT:** `review.md` → PR URL

### 2. Enforcement Extensions (Hard Gates)
- **pre-code-guard:** Blocks edits until dev environment active + AI policy checked
- **pre-push-guard:** Blocks push until tests pass + runtime verified + diff clean
- **model-router:** Phase-aware model selection (Tier 1-3 based on pipeline phase)

### 3. Brain Memory System
- Three-tier architecture: working → recall → archival memory
- Memory consolidation job (dedup, decay, promote, prune)
- Web→brain auto-ingest for high-relevance results (>0.7 relevance)
- Pipeline-brain integration contracts per phase

## Action Items
- [ ] Create `.kelos/agents/scout.md` - Issue research + AI policy check
- [ ] Create `.kelos/agents/test-writer.md` - Write failing test (RED phase)
- [ ] Create `.kelos/agents/implementer.md` - Make test pass (GREEN phase)
- [ ] Create `.kelos/agents/refactorer.md` - Clean up implementation
- [ ] Create `.kelos/agents/reviewer.md` - Verify correctness + anti-patterns
- [ ] Create `.kelos/agents/submitter.md` - Format, commit, push, create PR
- [ ] Define `.kelos/chains/contribution-pipeline.md` with 6-phase chain
- [ ] Build enforcement extensions in `.kelos/extensions/`
- [ ] Enhance brain memory system in `.kelos/brain/`
- [ ] Configure phase-aware model routing
- [ ] Validate with end-to-end test on `agent-ready` issue

## Expected Outcomes
1. **Zero Context Pollution:** Agents solve tests, not prompts
2. **Objective Completion:** PRs only created when all pipeline phases succeed
3. **Hard Quality Gates:** Cannot push broken code or skip verification
4. **Continuous Improvement:** System learns from every success/failure via brain memory
5. **Cost Efficiency:** $0/day using local models + free tier APIs
6. **Optimal Resource Usage:** Right model for each pipeline phase

## Validation Criteria
- [ ] `.kelos/agents/` contains all 6 pipeline agents with proper I/O contracts
- [ ] `.kelos/chains/contribution-pipeline.md` defines the 6-phase TDD chain
- [ ] `pre-code-guard` blocks file edits until dev environment is active and AI policy checked
- [ ] `pre-push-guard` blocks git push and gh pr create until tests pass and runtime verified
- [ ] `model-router` selects appropriate model tier for each pipeline phase
- [ ] Brain system uses three-tier architecture with temporal decay
- [ ] Pipeline phases appropriately write to and read from brain
- [ ] End-to-end test passes on a real `agent-ready` issue
- [ ] PRs are only created when all pipeline phases succeed and verification is complete

## Labels
- [ ] `enhancement`
- [ ] `agent-ready`

---
*Related: #2 (NVIDIA NIM configuration), #3 (sub-agent model references)*
*Skill: `pi-pipeline-integrator`*
```

</details>

#### #5 Deploy three-tier brain memory system with consolidation and auto-ingest
`reverb256` · 2026-05-20 · 5 · labels: enhancement, agent-ready

<details><summary>body</summary>

```
## Background
Three-tier brain memory system needs to be implemented to enable continuous learning from pipeline outcomes.

## Requirements

### Memory Tiers
1. **Working Memory:** Volatile, per-session (`.pipeline-state.json` + chain outputs)
2. **Recall Memory:** Medium-term (`~/brain/daily/*.md` + `CORE.md`)
3. **Archival Memory:** Long-term (Qdrant with temporal decay)

### Features
- Memory consolidation job (dedup, decay, promote, prune)
- Web→brain auto-ingest for high-relevance results (>0.7 relevance)
- Pipeline-brain integration contracts per phase
- Nightly consolidation cron job

### Integration Points
- SCOUT phase: Query brain for similar issues/patterns
- TEST-WRITER: Log test patterns to working memory
- IMPLEMENTER: Record successful patterns
- REVIEWER: Store anti-patterns and corrections
- SUBMITTER: Archive final outcome (success/failure)

## Action Items
- [ ] Design three-tier memory architecture in `.kelos/brain/`
- [ ] Implement working memory (`.pipeline-state.json`)
- [ ] Implement recall memory (daily logs + CORE.md)
- [ ] Implement archival memory (Qdrant integration)
- [ ] Create nightly consolidation cron job
- [ ] Enable web→brain auto-ingest (>0.7 relevance)
- [ ] Define pipeline-brain integration contracts per phase
- [ ] Test memory retrieval and consolidation
- [ ] Validate learning from success/failure outcomes

## Labels
- [ ] `enhancement`
- [ ] `agent-ready`

---
*Related: #4 (pi-pipeline TDD chain integration)*
```

</details>

#### #6 Security hardening: Rotate exposed credentials and enforce RBAC at AIG level
`reverb256` · 2026-05-20 · 6 · labels: agent-ready, security, critical

<details><summary>body</summary>

```
## Background
Credential observed in `./kelos-infra/.git/objects/e6/[REDACTED]` must be redacted or rotated. Plaintext keys should not be stored in Git.

## Security Issues
1. **API Key in Git:** Credential found in `.git/objects/` - needs immediate rotation
2. **Runtime Injection:** Should use NixOS secrets or HashiCorp Vault
3. **RBAC Enforcement:** Casdoor-backed JWTs must be enforced at AIG level
4. **MCP Protocol:** Client-side vs server-side role confusion causing deadlocks

## Action Items

### Immediate (Security Critical)
- [ ] Rotate exposed API key immediately
- [ ] Remove credential from Git history (`git filter-branch` or BFG Repo-Cleaner)
- [ ] Audit all repos for similar credential leaks

### RBAC Hardening
- [ ] Ensure Casdoor-backed JWTs enforced at AIG level
- [ ] Verify `ScopeEnforcer` middleware rejects requests missing valid `model` field
- [ ] Verify `ScopeEnforcer` rejects incorrect provider prefix
- [ ] Test RBAC with invalid/expired tokens

### MCP Protocol Fix
- [ ] Identify client-side vs server-side role confusion
- [ ] Confirm Hermes sends `model` field in all requests
- [ ] Update MCP handler to expect `model` field
- [ ] Test MCP handshake with corrected protocol

## Labels
- [ ] `security`
- [ ] `critical`
- [ ] `agent-ready`

---
*Related: All infrastructure issues (security is foundational)*
```

</details>

#### #7 End-to-end validation of pi-pipeline integration on real agent-ready issue
`reverb256` · 2026-05-20 · 7 · labels: agent-ready, testing

<details><summary>body</summary>

```
## Background
Comprehensive end-to-end validation of the pi-pipeline integration on a real `agent-ready` issue.

## Test Plan

### Pre-Conditions
- [ ] All 6 pipeline agents created in `.kelos/agents/`
- [ ] Contribution pipeline chain defined in `.kelos/chains/`
- [ ] Enforcement extensions implemented (`pre-code-guard`, `pre-push-guard`, `model-router`)
- [ ] Brain memory system deployed and operational
- [ ] SPOC context loading verified (`spoc-state.json` exists)
- [ ] Model routing configured for all pipeline phases

### Test Execution
1. **Select Test Issue:** Find or create a real `agent-ready` issue
2. **Dispatch to Pipeline:** Label issue `agent-ready` and trigger pipeline
3. **Monitor Execution:**
   - SCOUT phase: Verify `scope.md` created with AI policy check
   - TEST-WRITER phase: Verify failing test created (context-isolated)
   - IMPLEMENTER phase: Verify test passes with minimal code
   - REFACTOR phase: Verify code cleaned up
   - REVIEWER phase: Verify `review.md` with APPROVE/REQUEST_CHANGES
   - SUBMITTER phase: Verify PR created only after all phases succeed
4. **Validate Gates:**
   - Confirm `pre-code-guard` blocked edits until dev environment active
   - Confirm `pre-push-guard` blocked push until tests passed
   - Confirm model selection matched phase requirements
5. **Verify Brain Integration:**
   - Check working memory updated per phase
   - Verify recall memory logged outcomes
   - Confirm archival memory stored in Qdrant

### Success Criteria
- [ ] PR created only when all 6 phases succeed
- [ ] No context pollution (each agent saw only what it needed)
- [ ] Hard gates prevented bypassing verification
- [ ] Brain memory captured learnings for future use
- [ ] Model routing optimized per-phase performance
- [ ] Total execution time within acceptable bounds (<30 min for simple issue)

## Action Items
- [ ] Select or create test issue
- [ ] Execute pipeline
- [ ] Document results and any failures
- [ ] Iterate on pipeline configuration based on findings
- [ ] Update documentation with lessons learned

## Labels
- [ ] `testing`
- [ ] `agent-ready`

---
*Related: #4 (pi-pipeline TDD chain), #5 (brain memory), #6 (security)*
```

</details>

#### #8 Deploy updated kagent/kelos state to all 4 cluster nodes via hsync
`reverb256` · 2026-05-20 · 8 · labels: agent-ready, infrastructure, deployment

<details><summary>body</summary>

```
## Background
After successful merge of pi-pipeline integration, the updated kagent/kelos state must be propagated across all four NixOS cluster nodes.

## Cluster Nodes
- **Nexus:** Primary node (AI Inference Gateway, Qdrant, SearXNG)
- **Sentry:** Secondary node (local inference, GPU mining)
- **Forge:** Tertiary node (GPU mining, workload distribution)
- **Zephyr:** Workstation node (Hermes SPOC, browser, light dev)

## Synchronization Process

### Pre-Sync Checklist
- [ ] All PRs merged to main branch
- [ ] Git history clean (no merge conflicts)
- [ ] NixOS config passes evaluation (`nix eval .`)
- [ ] K8s manifests validated (`kubectl --dry-run=client`)

### Execution Steps
1. **Pull Latest Changes:**
   ```bash
   cd /etc/nixos && git pull origin main
   ```

2. **Build on All Nodes:**
   ```bash
   colmena build --target '(nexus|sentry|forge|zephyr)'
   ```

3. **Deploy to All Nodes:**
   ```bash
   colmena apply --target '(nexus|sentry|forge|zephyr)'
   ```

4. **Sync K8s Manifests:**
   ```bash
   kubectl apply -f kubernetes-manifests/
   ```

5. **Verify Deployment:**
   ```bash
   kubectl get pods -n ai-inference
   kubectl get deployments -n ai-inference
   ```

6. **Test Pipeline:**
   - Trigger a test issue through the pipeline
   - Verify all nodes can access shared state (NFS)
   - Confirm model routing works from all nodes

### Post-Sync Validation
- [ ] All nodes running latest config
- [ ] AI Inference Gateway healthy on all nodes
- [ ] Qdrant accessible from all nodes
- [ ] NFS mounts active and synchronized
- [ ] Pipeline executes successfully on test issue

## Action Items
- [ ] Merge all related PRs (#2-#7)
- [ ] Run `hsync --all` to propagate state
- [ ] Verify cluster health
- [ ] Document any node-specific issues

## Labels
- [ ] `infrastructure`
- [ ] `deployment`
- [ ] `agent-ready`

---
*Related: All previous issues (final deployment step)*
```

</details>
