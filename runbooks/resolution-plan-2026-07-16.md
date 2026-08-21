# Resolution Plan — MapleSpike Auth + Cluster Gaps (2026-07-16)

> Status: PLAN ONLY. Nothing here is executed yet. Each phase has a verification gate;
> a phase is "done" only when its live check passes. Deploy steps require explicit
> user go-ahead (user rule: no redeploy without permission). All image builds use
> `podman --format docker` + push `--tls-verify=false` to `nexus:5000`, and we
> PIN BY DIGEST (never trust `:latest` + IfNotPresent — that is what broke the
> previous attempt: identical digest `sha256:3b2f6fc1…`, no code shipped).

## Scope of "the rest of all these issues and gaps"

Open GitHub issues: #778 (GitHub OAuth CA), #779 (Astral proxy DNS), #780 (Astral .lan origin), #781 (cluster nodes Unknown), #782 (portal /signin 404).
Plus HEY.md drift: struck "Completed" claims that are FALSE on live (all nodes Ready; auth chain done).

## Coordination constraints (from /hey)
- Other agent: quill `main` working tree is now CLEAN (no uncommitted). Do not assume their
  edits are deployed — verify live digest before claiming anything fixed.
- My astral-key artifacts are uncommitted (config.rs, web3.rs, k8s/astral-key-deployment.yaml).
  They are the source of truth for #780; they are NOT yet built/pushed/applied.
- quill repo mandates OpenSpec. Any quill code change goes through `openspec propose → apply → archive`.

────────────────────────────────────────────────────────────────────────────
## PHASE 0 — HEY.md truth-sync (prereq, no deploy)
────────────────────────────────────────────────────────────────────────────
Goal: stop the repo's HEY.md from asserting false "Completed" state.
Actions:
- Mark "All nodes Ready" as FALSE (live: only nexus Ready; forge/sentry/krash3 Unknown).
- Mark "Auth chain done" as FALSE (GitHub token-exchange broken; Astral .lan live).
- Add a "RESOLUTION PLAN 2026-07-16" pointer to this file.
Verification: `grep -c "Unknown" hey.md` reflects live; no false "Completed" claims remain.
Owner: hermes-auth-audit. No cluster touch.

────────────────────────────────────────────────────────────────────────────
## PHASE 1 — GitHub OAuth CA bundle (#778)  [BLOCKER for login completion]
────────────────────────────────────────────────────────────────────────────
Root cause (verified): running quill-api image has NO CA bundle → `fetch failed` to
api.github.com → token exchange 502. The "fix" was attempted via rebuild but used cached
layers (digest unchanged) → no-op.

Plan (config-first, quill repo):
1. OpenSpec change `fix-api-ca-bundle` in quill repo:
   - proposal/spec/design/tasks per openspec-propose.
   - Change: Dockerfile.api (or container overlay) must COPY a CA bundle to
     `/usr/local/share/ca-certificates/ca-bundle.crt` and the container start command
     must `export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/ca-bundle.crt`.
   - Parameterize via `CA_CERT_PATH` env (default that path); do NOT hardcode a
     /etc/nix/store path.
2. Build: on a builder host (nexus or zephyr-dispatch), `podman build --format docker
   --no-cache -t nexus:5000/quill-api:fix-ca-<sha7> -f Dockerfile.api .`
   (use --no-cache so the CA COPY layer is fresh, not from a stale cache).
3. Push: `podman push --format docker nexus:5000/quill-api:fix-ca-<sha7> --tls-verify=false`.
4. Capture PUSHED digest:
   `MANIFEST_DIGEST=$(curl -sS -D - -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
     http://nexus:5000/v2/quill-api/manifests/fix-ca-<sha7> | grep -i Docker-Content-Digest | awk '{print $2}')`
5. Rollout (declarative deploy path per homelab-k8s-app-deploy):
   - Update the quill Deployment manifest (quill/k8s/maplespike/quill-api-deployment.yaml OR
     easykubenix module) image to `nexus:5000/quill-api@sha256:<digest>` (digest-pinned).
   - `kubectl apply -f ...` OR `kubectl set image deploy/quill-api -n maplespike \
     api=nexus:5000/quill-api@sha256:<digest>` + `kubectl rollout restart`.
6. VERIFY (the gate — real behavior, not pod Running):
   - `kubectl exec -n maplespike <pod> -- node -e "fetch('https://api.github.com/user').then(r=>console.log('GH',r.status)).catch(e=>console.log('ERR',e.message))"`
     → must print `GH 200` (or 401, not `fetch failed`).
   - Real OAuth: perform a full browser login via github.com → callback → JWT cookie.
     If no browser: at minimum confirm callback no longer 502s on a valid-ish code path
     (token exchange reaches GitHub). The earlier `OAUTH_INVALID_STATE` on bogus state is
     expected; the TLS `fetch failed` must be gone.
Gate: GH fetch from pod = 200/401 (not fetch failed). Without this, Phase 1 fails.

────────────────────────────────────────────────────────────────────────────
## PHASE 2 — Astral .lan / Web3 localhost (#780)  [passkey + SIWE broken]
────────────────────────────────────────────────────────────────────────────
Source of truth already written (astral-key repo, uncommitted):
- k8s/astral-key-deployment.yaml (correct env names: FIDO2_ORIGINS plural, ASTRAL_WEB3_DOMAIN)
- src/config.rs (Web3Config.domain from ASTRAL_WEB3_DOMAIN, default maplespike.ca)
- src/api/handlers/web3.rs (reject spoofed request.domain; use configured domain)
All hostnames derive from QUILL_DOMAIN — parameterized, not hardcoded.

Plan:
1. Verify Rust compiles: on a host with cargo, `cargo check` in astral-key. (NOT done yet —
   cargo absent on zephyr; must run on a builder or `nix develop`). Gate before build.
2. OpenSpec NOT required in astral-key (no OpenSpec dir there) — commit directly with
   conventional message referencing #780.
3. Build astral-key image: `podman build --format docker -t nexus:5000/astral-key:fix-origin-<sha7> .`
   (Cargo release build; may be slow — background+notify).
4. Push + capture digest (same pattern as Phase 1).
5. Apply manifest: `kubectl apply -f astral-key/k8s/astral-key-deployment.yaml` (this replaces
   the imperative localhost/astral-key:latest object with the declarative one, correct env).
   Set image to the digest-pinned new build.
   NOTE: manifest uses `imagePullPolicy: IfNotPresent` + a moving tag → set to the digest pin
   OR `Always` to avoid the staleness trap. I will pin by digest.
6. VERIFY:
   - `kubectl get deploy -n astral-key astral-key -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"="}{.value}{"\n"}{end}'`
     → FIDO2__RP_ID=maplespike.ca, FIDO2__ORIGINS contains https://quill.maplespike.ca,
       ASTRAL_WEB3_DOMAIN=maplespike.ca. NO .lan, NO localhost.
   - Web3 nonce: `curl -s -X POST https://api.maplespike.ca/v1/astral/web3/nonce -d '{"address":"0x1...","chainId":1}'`
     → message_template must show `quill.maplespike.ca wants you to sign in... URI: https://quill.maplespike.ca`,
       domain field = maplespike.ca. NOT localhost.
   - Astral health: `curl -s https://api.maplespike.ca/v1/astral/health` → 200 (proxy reaches astral).
Gate: no .lan/localhost in env; nonce domain = maplespike.ca; /astral/health 200.

────────────────────────────────────────────────────────────────────────────
## PHASE 3 — Astral proxy 502 on forge pod (#779)  [intermittent 502]
────────────────────────────────────────────────────────────────────────────
Root cause (verified): forge-scheduled api pod cannot resolve DNS (EAI_AGAIN) → proxy to
astral 502. Likely the SAME fault as #781 (forge node Unknown / kubelet). Do NOT fix in
isolation — fixing #781 (node health) likely resolves #779. If after #781 forge still has
broken pod DNS, then:
- Add `dnsPolicy: ClusterFirst` + optional `DNS_SERVER` env (default kube-dns 10.43.0.10) to
  quill-api Deployment.
- Add pod anti-affinity (preferredDuringScheduling) so api replicas spread across
  nexus+sentry (healthy nodes), not both land on a broken node.
Verification: both api pods resolve `astral-key.astral-key.svc.cluster.local` AND
`/v1/astral/health` returns 200 from BOTH pods consistently.

────────────────────────────────────────────────────────────────────────────
## PHASE 4 — Cluster nodes Unknown (#781)  [forge/sentry; nexus already Ready]
────────────────────────────────────────────────────────────────────────────
SCOPE NOTE: krash3 is EXCLUDED. It is a standalone Windows PC (RTX 4060 passthrough),
NOT part of the NixOS/K3s cluster. Its `Unknown`/`SchedulingDisabled` state is expected and
out of scope — do not "fix" it. Only `forge` and `sentry` are in scope (both currently
Unknown; nexus already Ready).

This is HOST-OS / kubelet health → governed by nixos-declarative-only. Must NOT be fixed
with imperative `systemctl`/`kubectl`. Investigate FIRST (read-only), then fix via /etc/nixos.
1. Read-only diagnosis (parallel SSH allowed for READING):
   - `ssh forge 'systemctl status k3s-agent --no-pager'` (or kubelet), `uptime`, `journalctl -u k3s-agent -n 50`.
   - Same for sentry.
   - Check kubelet cert expiry, kubeconfig server reachability.
2. Determine root cause class: wedged kubelet? cert expired? control-plane unreachable?
3. Fix declaratively in /etc/nixos (the Nix source of truth):
   - If kubelet unit misconfigured → edit the NixOS module, `colmena apply --on <host>` from
     /etc/nixos. Do NOT `systemctl restart` imperatively as the permanent fix.
4. VERIFY: `kubectl get nodes` → forge/sentry Ready (nexus already Ready).
Gate: forge + sentry Ready.

────────────────────────────────────────────────────────────────────────────
## PHASE 5 — Portal /signin 404 (#782)  [login link dead]
────────────────────────────────────────────────────────────────────────────
Source: portal links already use /signup (canonical). /signin returns 404.
Plan (quill repo, OpenSpec change `fix-signin-route`):
1. Add a portal route alias: `/signin` → redirect to `/signup` (Astro getStaticPaths or a
   catch route). Centralize auth-route const if portal repeats the path.
2. Build portal image (podman --format docker), push, digest-pin, rollout (same as Phase 1).
3. VERIFY: `curl -s -o /dev/null -w '%{http_code}' https://quill.maplespike.ca/signin` → 200/302.
   `curl ... /signup` → 200.
Gate: /signin resolves (not 404).

────────────────────────────────────────────────────────────────────────────
## PHASE 6 — HEY.md gap closure + issue updates
────────────────────────────────────────────────────────────────────────────
- After each phase, update HEY.md (Active Sessions / Work Log with timestamps) and close the
  corresponding GitHub issue with the verification evidence.
- Move real "Completed" items into the Completed list with timestamps; delete false claims.
- Commit HEY.md (`git add HEY.md && commit -m "docs(coord): resolution progress 2026-07-16"`).

────────────────────────────────────────────────────────────────────────────
## ORDERING / DEPENDENCIES
────────────────────────────────────────────────────────────────────────────
Phase 0 (sync) → Phase 1 (GitHub CA, blocker) → Phase 2 (Astral origin) →
Phase 4 (nodes) → Phase 3 (proxy, depends on 4) → Phase 5 (signin) → Phase 6 (close-out).
Phases 1,2,5 each need: code change → OpenSpec (quill) / commit (astral) → build
(--no-cache, --format docker) → push (--tls-verify=false) → digest-pin → rollout →
LIVE verify. NO phase is "done" until its live verification gate passes.

## ANTI-PATTERNS THIS PLAN AVOIDS (from prior failure)
- ❌ Rebuild with cached layers → no-op (use --no-cache; verify digest changed).
- ❌ Trust `:latest`+IfNotPresent → pod stays on stale cache (pin by digest).
- ❌ OCI format push to nexus:5000 (HTTP) → manifest corruption (use --format docker).
- ❌ Imperative `kubectl set env` as the permanent fix for Astral (use the manifest in repo).
- ❌ Imperative `systemctl` on nodes for #781 (use /etc/nixos + colmena).
- ❌ Declare "deployed" on pod Running / rollout success — verify REAL behavior (GH fetch,
  nonce domain, /astral/health, /signin code).

## WHAT I NEED FROM YOU TO EXECUTE
- Go-ahead to (a) run builds on a builder host, (b) push to nexus:5000, (c) apply/rollout.
- For #781: access to read /etc/nixos (I have it) + permission to `colmena apply` if a Nix fix
  is needed (you've said "do not attempt redeployment" before — confirm for cluster nodes).
- A builder host with `cargo` for the astral-key `cargo check` (or I use `nix develop` in astral-key).
