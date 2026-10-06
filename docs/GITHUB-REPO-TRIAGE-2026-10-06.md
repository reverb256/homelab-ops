# reverb256 GitHub account triage — 2026-10-06

Read-only sweep of the `reverb256` account. Every number below comes from `gh` output, not
eyeballs. Findings live here, not in memory (per `github-account-audit`).

## Headline numbers

| metric | value |
|---|---|
| repos owned | **102** |
| public / private | 70 / 32 |
| forks | 32 (**17** live, 15 archived) |
| already archived | 17 |
| open PRs | **112** — 103 `dependabot`, 9 ours |
| open issues (owned repos) | **179** |
| open issues authored by reverb256 (anywhere) | 263 |
| PRs merged by reverb256 | 500 |
| repos with no description | 17 |
| last-push age | >7d: 78 · >30d: 46 · >90d: 26 · >180d: 6 · >365d: 3 |

## The 24 active repos (pushed ≤7d)

ComfyUI-TRELLIS2 · Reverb-OS · ai-content-pipeline · ai-inference-gateway · astral-key ·
coreflame-protocol · freebuff-flake · helm-media-servarr · hermes-plugins · hermes-skills ·
hermes-skills-live · homelab-ops · llama-cpp-turboquant · media-k8s · memlawb-for-hermes ·
mining-k8s · nixos-config · ops-log · site-agency · sites-k8s · solana-ai-trader ·
trading-k8s · trovesandcoves · voxtype

**Caution:** this bucket is poisoned by dependabot. `Reverb-OS` and `nixos-config` both read
"active (age 0)" while **neither has an authored commit in weeks** — dependabot branches keep
`pushed_at` fresh. Filter on the last *authored* commit, not `pushed_at`.

## Dead-but-not-archived (the real triage target)

Non-fork, non-archived, dormant or abandoned:

| repo | last authored activity | open issues | disposition |
|---|---|---|---|
| AstralVibe.ca | 474d | — | archive candidate |
| QuantumRhythm | 406d | — | already archived — fine |
| AstralDev | 261d | — | archive candidate |
| synapse | 206d | — | archive candidate |
| **Reverb-OS** | **2026-09-20** (dependabot since) | 1 (#12) | **see below — finish its own decommission plan** |
| Frostbite-Gazette | 147d | 12 | has *assigned* issues — decide revive vs archive |
| vllm-turboquant | 140d | — | also firing failed-CI notifications |
| kelos-infra | 137d | 8 | decide |
| void-config | 126d | — | archive candidate |
| **nixos-config** | dependabot-only | **40** | **target of Reverb-OS#12 "decommission"** |

Two repos are being kept nominally alive by a bot while their own plans say they are done.

## Fork farm (17 live)

**Keepers — carry patches or serve the fleet:**
`helm-media-servarr` (own push 10-05, source of the media-stack charts) ·
`voxtype` (10-04, upstream PRs #820/#821 open) · `ComfyUI-TRELLIS2` (10-03, PR #151) ·
`Haven` (09-23) · `omarchy` (09-23, PR #13055) · `infomarchy` (09-21) ·
`awesome-mcp-servers` (09-18) · `flea` (09-13) · `hermes-agent` (09-12)

**Mirrors with no local commits in 30–90d** — cheap to keep, but they are account clutter:
`omastream` · `hermes-agent-self-evolution` · `lix` · `ScopeBuddy` · `comfyui-nix` ·
`secretspec` · `mcp-canada`

**Stale mirror:** `codebuff` (parent `CodebuffAI/freebuff`, own push 97d)

All 15 archived forks are correctly disposed of.

## Are we using Reverb-OS at all? — **No.**

Evidence, strongest first:

1. **Nothing consumes it.** A grep of every `flake.nix` under `~/Work/Projects` finds Reverb-OS
   referenced in exactly one place: **its own** `flake.nix`
   (`url = "git+https://github.com/reverb256/Reverb-OS?dir=pkgs/gitlawb"` — a self-reference for
   its own package). No sibling repo takes it as an input.
2. **No host runs it.** There have been no NixOS machines since 2026-09-17, and its sibling
   `nixos-config` is itself the decommission target.
3. **Its CI is disabled.** Commit `2026-09-20` — *"docs(ci): all workflows disabled — target
   nonexistent NixOS self-hosted [runner]"*. The 20 files under `.github/workflows/` are inert;
   the "active" push dates are dependabot.
4. **Its own plan stalled.** Last authored commits (`2026-09-19` → `2026-09-20`):
   *"P1 done; **P2 reframed — no NixOS workflow porting**"* — i.e. the migration it existed to
   carry out was re-scoped and it stopped.
5. **Its self-description is false.** `docs/current-state.md` (Last Verified **2026-08-20**)
   still says *"The live cluster is still NixOS."* That has not been true for ~3 weeks. **This is
   the most dangerous artifact in the repo** — an agent or a human reading it would be actively
   misled about fleet reality.
6. Open work on it is bot noise: **11 stale dependabot PRs** (all from 2026-09-17) plus issue
   **#12 "Path B: decommission nixos-config — rehome → repoint → archive"**.

**Residual value to preserve before archiving:** the `pkgs/gitlawb` package (its own flake's
`?dir=pkgs/gitlawb` target — nothing else points at it, so it needs an explicit new home), the
`modules/home-manager/ported/*.nix` modules, and the design docs under `docs/plans/`.

**Recommendation:** finish its own issue #12 — (1) rehome `pkgs/gitlawb` and any ported module
still wanted, (2) delete or rewrite the false `docs/current-state.md`, (3) close the 11
dependabot PRs, (4) archive. 17 repos are already archived, so the practice is established.

## Actions taken (2026-10-06)

Archived at j_kro's instruction — **9 repos**, taking the account from 17 archived to
**26 archived / 76 live**:

`AstralVibe.ca` · `AstralDev` · `synapse` · `Frostbite-Gazette` · `vllm-turboquant` ·
`kelos-infra` · `void-config` · `Reverb-OS` · `nixos-config`

All nine verified `archived=true` by a fresh read after the write.

### Follow-up pass — completed (same day)

Archiving froze **78 open items** (61 issues + 17 PRs). A second pass, on instruction,
unarchived → exported → closed → re-archived all four repos:

- **Exported first:** every item's title, labels and body is preserved live in
  [`ARCHIVED-REPO-BACKLOG-EXPORT-2026-10-06.md`](ARCHIVED-REPO-BACKLOG-EXPORT-2026-10-06.md)
  (130 KB, all 61 issue bodies).
- **Closed:** 61 issues + 17 PRs (PR branches deleted), each carrying a comment pointing at the
  export and stating that reopening is possible.
- **Re-archived:** all four verified `archived=true` with **0 open items** remaining.

**Unresolved, and the important part — 36 of the 61 issues were labelled `agent-ready` / `p0` /
`p1` / `security` / `critical`.** They are live work that died with its tracker, not dead-repo
noise. Four are security items:

| item | title |
|---|---|
| nixos-config #306 | migrate: replace sops-nix/agenix with secretspec across all projects (`p1, security`) |
| nixos-config #464 | `ai-inference-gateway-secrets` contains placeholder keys (autoapplied) (`security, k8s`) |
| nixos-config #466 | re-add maplespike billing/JWT secrets to secretspec (`security`) |
| kelos-infra #6 | rotate exposed credentials and enforce RBAC at AIG level (`agent-ready, security, critical`) |

Also live: `Frostbite-Gazette` #8/#9/#10/#11 (`p1`/`p0` — MapleSpike MCP migration, SEDAR+/CRTC
modules, UN/WEF/SDG integration, test-coverage dogfood pipeline) and the `kelos-infra` #1–#8
pi-pipeline set. **These need a home in a live tracker** — the export is preservation, not a plan.

## Loose ends worth closing in the same pass

- **9 of ours open PRs** outside quill: `ai-content-pipeline#1` (09-02), `nixos-config#706–709`
  (08-18, for a repo being decommissioned), `trovesandcoves#32` (07-24),
  `secretspec-provider-sops#2/#3` (07-23), `ai-inference-gateway#47` (05-20) — all stale.
- **179 open issues in owned repos**, 40 of them on the decommission target `nixos-config` and
  35 on `ai-inference-gateway`.
- **17 repos have no description**, including actively-used ones (`trading-k8s`, `sites-k8s`,
  `homelab-ops`, `hermes-skills`).
- Not covered by this pass: deploy keys, webhooks, branch protection, identity surfaces — that is
  the `github-account-audit` steps 3–8 sweep, still outstanding.
