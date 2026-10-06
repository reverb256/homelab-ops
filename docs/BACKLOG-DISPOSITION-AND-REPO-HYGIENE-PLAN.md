# Backlog disposition + repo hygiene — plan (2026-10-06)

Context: the 2026-10-06 archiving pass closed **81 items** (61 issues + 20 PRs) across
`nixos-config`, `Reverb-OS`, `Frostbite-Gazette`, `kelos-infra`. 36 of those issues carried
`agent-ready` / `p0` / `p1` / `security` / `critical` labels, which looked like live work dying
with its tracker. This plan is the response to that: **verify before rehoming, then fix the
causes rather than the items.**

---

## 1. The four security items — verified against live state

Do not rehome these by copying. Each was checked against the running system:

| # | item | verdict | evidence |
|---|---|---|---|
| `nixos-config#466` | re-add maplespike billing/JWT secrets to secretspec + k8s-secret-sync | **RESOLVED — already true** | `kubectl get secret -n maplespike` → `maplespike-secrets`, `quill-db-secret`, `quill-secrets`. `maplespike-secrets` and `quill-secrets` are **ExternalSecrets** on `ClusterSecretStore bitwarden-secretsmanager`, both `SecretSynced True` (~50m). The issue's NixOS paths (`/etc/nixos/secrets/maplespike/`, `k8s-secret-sync`) no longer exist; the modern BSM→ESO path already delivers the goal. |
| `nixos-config#306` | migrate sops-nix (64 entries) + agenix (22) → secretspec | **OBSOLETE framing; goal met** | Both are NixOS-only mechanisms; no NixOS host has existed since 2026-09-17, so both registries are retired. Secret delivery today = **BSM→ESO** (k3s), **secretspec** (Omarchy hosts), **sops** (VPS). Residual: 10 non-git files still *reference* `sops-nix`/`agenix` — `ai-inference-gateway/nix/{config-assertions,options}.nix`, `astral-key/.gitignore`, `astral-key-audit/.gitignore`, `hairathome/scripts/MODEL_DOWNLOAD_GUIDE.md`, Frostbite docs. Stale text, not a live path. |
| `nixos-config#464` | `ai-inference-gateway-secrets` holds placeholder keys | **LATENT — real, but not reachable today** | The placeholder strings (`YOUR_ZAI_API_KEY_HERE`, `default=sk-replace-with-your-actual-api-key`) still exist in **two** archived repos: `nixos-config/kubernetes-manifests/ai-inference/ai-inference-gateway-secrets.yaml` and `Reverb-OS/kubernetes-manifests/ai-inference/ai-inference-gateway-secrets.yaml`. And `kubectl get ns` shows **no `ai-inference` namespace** — the AIG/kelos/kagent stack is not deployed at all, so nothing mounts the placeholder. The autoapply mechanism that would have applied it was NixOS-side and is retired. Verdict: dead by decommission; the residual value is a **scanner rule**, not a fix. |
| `kelos-infra#6` | rotate exposed credentials + RBAC at AIG level | **UNVERIFIED — needs a decision** | The claim is a credential in `kelos-infra/.git/objects/`. The repo is **private**, archived, 21 KiB, last push 2026-05-21. AIG is not deployed, and auth has since migrated (`ai-inference-gateway#79` — "Migrate authentication middleware to astral-key" is open). Two halves: the *rotation* half is unverifiable without identifying the key; the *RBAC/Casdoor* half is moot while AIG is undeployed. **This is the only item I will not close on inference.** |

**Net:** of four "critical/security" items, one is already satisfied, two are dead by
decommission, and one needs j_kro. The label was not evidence of liveness.

## 2. The rest of the 36 — why they were not live either

- **`nixos-config` (40 issues)** — overwhelmingly **NixOS-framed**: `#307` aspect-based module
  reorg, `#310` `git-hooks.nix` eval gate, `#311` easykubenix, `#314–#317` declaring `nim-proxy`
  in NixOS, `#341–#343` canary/disko, `#359`, `#415`, `#687`, `#702`, `#710`, `#711`, `#719`,
  `#720`. Every one targets a configuration system that no longer runs. The repo's own
  `AGENTS.md` carries a 🛑 banner: *"DO NOT START NEW WORK IN THIS REPO (2026-09-19) …
  Superseded."*
- **`Frostbite-Gazette` (12 issues)** — a journalism product backlog (API client, TS types,
  WebAuthn, MapleSpike MCP, SEDAR+/CRTC modules, UN/WEF/SDG, test-coverage pipeline). **Project
  dormant 147d.** `agent-ready` here means "an agent could pick it up", not "this matters".
- **`kelos-infra` (8 issues)** — the kelos/pi-pipeline set. **Project dormant 137d**, and its
  target stack is not deployed.

So roughly **50 of 61** were obsolete-or-dormant. The labels were aspirational, not a signal.

---

## 3. The systemic problems (fix these, not the items)

### P1 — Dependabot makes dead repos look alive
`Reverb-OS` and `nixos-config` both read `pushed_at` = today while their last **authored** commit
is weeks old. Any recency view built on `pushed_at` will miss dead repos — this is what made the
archive pass necessary rather than obvious.
**Fix:** a hygiene check that classifies on the last non-bot commit
(`git log --author=reverb256 --format=%cI -1`), reported monthly into `homelab-ops`.
*Tradeoff:* one more scheduled job; needs a place to run (nexus/sentry, not zephyr). **Recommend.**

### P2 — Dead trackers hold live work
Archiving froze 81 items with no inventory step beforehand.
**Fix:** a **pre-archive checklist** — before `archived=true`, dump every open item's title,
labels and body to a live repo, and *classify* each as obsolete / live-elsewhere / dormant-project.
The export for this pass exists as the template.
*Tradeoff:* adds a manual step to archiving; cheap and it is exactly what caught the four items.

### P3 — The redirect chain is broken and points at an archived repo
`nixos-config/AGENTS.md` says *"Route new work to reverb256/Reverb-OS (cluster) or
reverb256/homelab-ops (ops)"* — but **Reverb-OS was archived the same day**, and its own plan
stopped at *"P2 reframed"*. Anything following that pointer lands in a dead end, and both
repos are now read-only so the banner cannot be corrected in place.
**Fix:** state the live routing once, where it will actually be read — the workspace root
`AGENTS.md` and `homelab-ops` — and treat any archived repo's banner as historical.
*Tradeoff:* an unarchive→edit→re-archive cycle is possible but not worth it for a banner; fixing
the *live* pointers is what matters. **Recommend.**

### P4 — Labels lie
`agent-ready` = "an agent could start this", not "this is live work". On dormant projects it
manufactures urgency that outlives the project.
**Fix:** scope the label to *actionability on an active repo*, and add a staleness review — an
`agent-ready` issue untouched for 90 days gets the label dropped or the issue closed as
`not planned`. *Tradeoff:* needs a periodic pass; the alternative is repeating this cleanup.

### P5 — Stale mechanism references in live repos
`sops-nix` / `agenix` / `/etc/nixos/…` still appear in live repos and skills.
**Fix:** a one-pass sweep that rewrites them to the current mechanisms
(BSM→ESO / secretspec / sops) or deletes them. Mechanical, verifiable by grep.

### P6 — 103 of 112 open PRs are dependabot
Mostly on dormant or archived repos, which wastes CI and drowns the 9 real PRs.
**Fix:** tune `.github/dependabot.yml` fleet-wide — group by ecosystem, cap open PRs per
ecosystem, and **disable dependabot on archived/dormant repos** (archiving should stop it, but
`nixos-config` still opened three PRs mid-pass).
*Tradeoff:* less timely bumps on the repos that remain — acceptable; the fleet is registry-free
and pinned by digest anyway.

---

## 4. Phased execution

**Phase 0 — now (this plan).** Record the verified dispositions above.
**Phase 1 — free, mechanical.** P5 sweep; P1 hygiene check; P3 fix the live routing pointers.
**Phase 2 — one-time cleanup.** P6 dependabot tuning; P4 stale-label pass.
**Phase 3 — the durable fix.** P2 pre-archive checklist, wired into the archive step so the next
pass cannot repeat this one.

**Recommended order:** 1 → 3 → 2. Phase 1 costs nothing and removes the misleading signals;
until P1 exists, any other hygiene view is built on `pushed_at` and will lie again.

---

## 5. One open question for j_kro

`kelos-infra#6` — rotate the credential found in that private repo's `.git/objects`. The repo is
private, archived, dormant since 2026-05, and its stack is undeployed, so the exposure is
contained. But *contained* is not *rotated*, and the key was never identified.

Options: (a) rotate-blind anything that repo could have held, (b) purge its git history and
accept the risk, (c) close as accepted-risk with the reasoning recorded.
**I recommend (c) with the reasoning written down** — the key is unidentifiable, the surface is
a private archived repo, and (a) would churn live credentials for no verified benefit. If any
key from that era is still in use, (a) becomes right and only j_kro can say.
