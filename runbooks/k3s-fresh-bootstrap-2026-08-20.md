# k3s Fresh Bootstrap — 2026-08-20 Recovery Runbook

Cluster quorum lost since 2026-08-16. Root causes (all verified):

1. **Stale/wrong age keys on forge/sentry** — `sops -d` fails exit 100 on every
   secret → `secretspec-creds` fails → no `/run/secrets/k3s-cluster-token` →
   k3s hard-blocked (`requires`). Only zephyr's 189 B `cluster_age` key at
   `/etc/nixos/.age/key.txt` decrypts the store (verified). An agent fix
   (7267114e) pointed at `~/.config/sops/age/keys-combined.txt` — a 378 B
   key that ALSO fails; superseded by `3ae3aa65`.
2. **Token drift** — nexus bootstrapped with a random token (live
   `K10dac1f4…`), store holds `K1058bcb5…`. `3ae3aa65` makes cluster-init
   servers use `tokenFile`, so a wiped nexus adopts the STORE token as truth.
3. **Stale k3s state** — nexus wedged etcd (term-101 election loop), forge
   1.3 G, sentry 244 M, zephyr stale agent certs. `wipeState=true` (one-shot)
   on all four hosts clears them.

Config state: `3ae3aa65` on main (pushed). `nix flake check --no-build` clean.

---

## Phase 0 — Seed the working age key (host-side, ~2 min)

The recovery deploy needs the 189 B `cluster_age` key on all servers.
Back up the stale key, install the working one from zephyr:

```bash
# on zephyr
KEY_SRC=/etc/nixos/.age/key.txt
for h in nexus forge sentry; do
  ssh "$h" "cp /etc/nixos/.age/key.txt /etc/nixos/.age/key.txt.pre-20260820 2>/dev/null; true"
  scp "$KEY_SRC" "$h:/etc/nixos/.age/key.txt"
  ssh "$h" "chmod 600 /etc/nixos/.age/key.txt; ls -la /etc/nixos/.age/key.txt"
done
```

Verify decryption on each host (expect `K1058bcb514bacb4205…`):

```bash
# on each host: use the store flake's token file from the nix store, or copy
# nixos-secrets/secrets/k8s/k3s-cluster-token.yaml to /tmp first
SOPS_AGE_KEY_FILE=/etc/nixos/.age/key.txt sops -d /tmp/k3s-cluster-token.yaml
```

## Phase 1 — Deploy (nexus FIRST, then servers, then agent)

```bash
cd ~/Projects/nixos-config
colmena apply --on nexus        # wipes etcd, bootstraps fresh WITH store token
# wait: kubectl get nodes  → nexus Ready (API back, single node)
colmena apply --on forge --on sentry   # wipe + join → etcd quorum 3/3
colmena apply --on zephyr              # wipe agent state, join via VIP
```

Verify:

```bash
kubectl get nodes -o wide                        # 4 nodes Ready
kubectl -n maplespike get pods                   # workloads back
```

Also lands in the same deploy: distributed-builds machines fix, substituter
timeouts, runner rework (#688 self-heal), cachix on nexus, fleet-deck,
memlawb fixes.

## Phase 2 — REVERT wipeState (CRITICAL, do not skip)

A persisted `wipeState=true` destroys the cluster on EVERY boot. Flip all
four hosts back to `wipeState=false` (config comment marks the spots),
push, and apply again:

```bash
# edit hosts/{nexus,forge,sentry,zephyr}/configuration.nix → wipeState = false;
git commit -am "fix(k3s): revert one-shot wipeState after fresh bootstrap"
git push origin main
colmena apply
```

## Phase 3 — Post-recovery CI checks

1. `ssh nexus systemctl is-active github-actions-runner-nixos-config` → active
   (and `ssh sentry` same). If not, the #688 self-heal unit should re-register.
2. `ls /run/current-system/sw/bin/cachix` on nexus → exists → home-manager-config
   CI goes green (8 consecutive failures were the missing binary).
3. nixos-config CI drains; `prod` branch can finally be created and the
   promote-to-prod pipeline fires for the first time.
4. quill `Deploy to Development` (queued since runners went down) will run.

## Notes / leftovers

- `origin/issue-713-cache-hit-fixes` is redundant — its content (cache-hit
  restore) is already on main. Safe to delete the remote branch.
- `modules/hardware/krash2-win11-vm.nix` is untracked WIP from another agent.
- `backup/pre-rebase` branch is an agent's pre-rebase safety net; informational.
