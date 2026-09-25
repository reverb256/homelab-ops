# Secrets control map

Companion to `runbooks/secrets-after-nixos.md` (which owns the *key hierarchy* and why it is
shaped that way). This file owns the *inventory*: what exists, who consumes it, how it reaches
the consumer, and how to verify that it did.

## The model, in three layers

| Layer | Where it lives | State |
|---|---|---|
| **Storage** | `nixos-secrets` (private repo, sops+age ciphertext only) | 90 secrets, verified decryptable on zephyr |
| **Contract** | `secretspec.toml` per project | 3 repos only (site-agency, Reverb-OS, nixos-config) — not fleet-wide |
| **Delivery** | per consumer: k8s Secret, host file, process env | partly automated, partly hand-placed |

Age recipients: `cluster_age`, `zephyr_age_v2`, two YubiKeys, one offline recovery.
The age private key lives on zephyr (`~/.config/sops/age/keys.txt`, 0600) and on the YubiKeys.
**Garage credentials are themselves sops-encrypted**, so the age key can never live only in
Garage — that is a one-way door, documented in the runbook.

## Delivery per consumer

| Consumer | Mechanism | Verify |
|---|---|---|
| k8s (media, monitoring, trading, haven) | k8s Secrets, applied per project | project-specific, e.g. quill's `sops-sync-k8s.sh --check` proves cluster == git |
| Oracle VPS (haven, cloudflared) | **hand-placed** (`/etc/haven/haven.env`, `/etc/cloudflared/tunnel.env`) | none yet — the gap this file exists to close |
| nexus (garage, backup keys) | `/etc/garage-secrets/*`, root-only files | `garage key info <name> --show-secret` |
| nexus host backup script (RustFS, `*arr`/Jellyfin configs) | sops store → rendered env file `~/.config/rustfs/backup.env` (0600) by `scripts/render-rustfs-backup-env.sh` (run on zephyr); the script sources it | re-render, then `aws --endpoint-url http://localhost:9000 s3 ls s3://jellyfin-backups/configs/` |
| Hermes profiles (sentry/nexus/zephyr) | per-profile `.env`, 0600, ~12 files, ~2 KB each | none — no drift detection |
| Hermes **A2A peer tokens** (nexus, zephyr) | store `secrets/infra/hermes-a2a-peer-tokens.yaml` → rendered into `~/.hermes/.env A2A_PEER_TOKENS` **and** `~/.hermes/config.yaml a2a_agents.<peer>.auth.token` by `scripts/a2a-peer-token-rotate.py` | `scripts/a2a-peer-token-rotate.py check` — store vs live, fingerprints only, exit 0/1/2 |
| Cloudflare (tokens, tunnels) | sops store + API | `GET /user/tokens/verify` |
| j_kro's user-facing credentials | **Bitwarden** — j_kro sets/rotates them imperatively in the app (source of truth); machine resolution via secretspec `bw://` or `~/.local/bin/bw-run` (unlocked `bw` CLI on zephyr) | `bw-run --status`; `bw-run bw list items --search <q>` |
| Cluster machine secrets — 40 keys / 19 secrets + 6 ArgoCD repo creds (2026-09-25) | **Bitwarden Secrets Manager** project `k3s` → **ESO pull** in k3s (ClusterSecretStore `bitwarden-secretsmanager`; CRs in media-k8s `cluster/addons/eso-secrets/`); rotation = change the value in the Bitwarden app, ESO refreshes ≤1h | gate A9: `python3 media-k8s/scripts/eso-verify.py` (expect 40 ok / 0 diff) |

## Rules

1. **Ciphertext only in git.** Never commit a plaintext secret, an age private key, or a decrypted
   render. **The store carries two envelope formats** — sops YAML (`sops:` metadata) and age files
   (`-----BEGIN AGE ENCRYPTED FILE-----`). A sweep that tests only for `sops:` mislabels every age
   file as plaintext; it did exactly that on 2026-09-22 and produced a false alarm across 11 files.
   Test for either envelope, and treat "no envelope" as the only alarm.
2. **A missing credential must fail loudly — either refuse to start, or degrade *visibly*.**
   `optional: true` is only legitimate when the consumer explicitly degrades and something observes the
   degradation. `alertmail-relay` is the reference case: its contract documents that with no Cloudflare
   credentials `/webhook` answers 503, alertmanager retries, and the gmail fallback still delivers — so
   the flag is correct design, but nothing watches the 503s, which is why the branded path sat broken
   unnoticed. The fix is a monitor on its degraded state, not removing the flag. (Rule corrected
   2026-09-22 after the first version of it was too absolute.)
   The monitor LANDED 2026-09-22: VMProbe `alertmail-relay-configured` (blackbox module
   `alertmail_configured`, which fails on the `/healthz` body when `"configured": true` is absent —
   a status-code probe cannot see the degraded state, because the relay answers 200 while handing
   off) plus `AlertMailDeliveryDegraded` (warning, 10m). Negative control recorded in media-k8s
   GATES.md gate A7; the token itself lives in `cluster/secrets/alertmail-cloudflare.sops.yaml`.
3. **Every secret has one owner and one delivery path.** Two delivery paths for the same secret
   means one of them is stale.
4. **Rotation is a procedure, not an intention.** Rotate on leak, on staff change, and on a schedule
   per class (long-lived API tokens annually; host join keys after any host rebuild). Rotation =
   update sops -> render -> restart the consumer -> verify by use.
5. **A secret that exists only hand-placed is not controlled.** If it is not in the store, it cannot
   be rotated deliberately, restored on a rebuilt host, or reviewed.
6. **User-facing credentials live in j_kro's Bitwarden (2026-09-25).** He sets and rotates them
   imperatively in the app; agents resolve them only via the secretspec `bw://` provider or the
   `bw-run` wrapper (unlocked `bw` CLI session on zephyr). Do not mirror them into the sops store
   unless a credential becomes an infra/machine secret.
7. **Cluster machine secrets pull from Bitwarden Secrets Manager via ESO (2026-09-25).** The k3s
   cluster resolves its own secrets — no zephyr push, no age key in-cluster. Bootstrap objects
   (deliberately NOT in git): ns `external-secrets` holds `bitwarden-access-token` (BSM
   machine-account token) and `bitwarden-tls-certs` (Homelab CA leaf for the SDK server; renew via
   ops-log `cluster/external-secrets/issue-sdk-cert.sh`). Rotation = change the value in Bitwarden;
   ESO refreshes within 1h. Coverage: 40 keys / 19 ExternalSecrets (maplespike, monitoring, media,
   cloudflared, haven, activepieces, kube-system smb, astral-key, default) + 6 ArgoCD repo
   credentials (shared `argocd-repo-pat`, templated CRs). Verify: media-k8s
   `scripts/eso-verify.py` (gate A9). Exceptions by design: `quill-db-secret` (chart-rendered from
   quill values) and ArgoCD internals (`argocd-secret`/`redis`/`notifications`). The sops/script
   rail stays for credentials not yet on the ESO rail.

## Known gaps

- **`nexus:/usr/local/bin/backup-to-rustfs.sh` carried its RustFS S3 credentials inline**
  (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) until 2026-09-22 — a hand-placed, non-declarative
  file any process on nexus could read. Now store-backed (`secrets/storage/rustfs-backup-*`,
  rendered to a 0600 env file; the script sources it and refuses to run without it). **Still a gap:**
  the script lives in no repo and has no schedule (no cron/timer references it), so it only runs
  when a human remembers — and its siblings (`media-config-backup`, `haven-backup`,
  `activepieces-backup`, `memlawb-backup`, `stampede-backup`, `btrfs-scrub`,
  `garage-buckets-reconcile`) are the same class. *Smallest next action:* move the script into this
  repo's `scripts/` and add a systemd timer; then sweep the siblings the same way.
  **Rotate the RustFS keys** that were embedded in the file (they were also readable by any
  `j_kro` process for 3 days; rotation is a dashboard/CLI action on the RustFS side).
- The Oracle VPS's two secret files are hand-placed (see rules 5). They belong in the store with a
  render step wired into `omarchy/oracle-vps/apply.sh`.
- Hermes profile `.env` files have no drift detection — the same keys are duplicated across ~12
  files on three hosts. **Partially closed 2026-09-22 for the A2A peer tokens**: those now have one
  owner (the store), one render step, and a `check` mode; the duplicated copies were removed from
  every profile that is not the host's A2A owner (13 profiles on nexus carried zephyr's `A2A_HOST`
  **and** zephyr's tokens — a foreign identity, and the source of 552 bind failures per 3 h), and
  every non-serving profile now has `platforms.a2a.enabled: false` so it cannot race for :9900.
  Still unmanaged, same class: the `~/.hermes/.env` provider keys on the other hosts.
- Only 3 repos declare a `secretspec.toml`; the fleet has no single contract to diff against.
- `secretspec-checkpoint` skill audited the old sops-nix/agenix registries from the NixOS era. No NixOS
  hosts remain, so its premise is gone — retired 2026-09-22.
- `secrets/ai/commandcode-api-key.yaml` held 238 bytes of corrupt non-UTF8 data (written Aug 26) where a
  key was expected; the store therefore had NO usable commandcode key while the runtime did. Replaced with
  a sops-encrypted entry built from the live value; the corrupt artifact is kept beside it as
  `.corrupt-20260922` (untracked) rather than deleted.

## Verification sweep (use this, not a sops-only grep)

    cd ~/Work/Projects/nixos-secrets
    for f in $(git ls-files 'secrets/*'); do
      grep -qE 'sops:|BEGIN AGE ENCRYPTED FILE|ENC\[AES256_GCM' "$f" || echo "NO ENVELOPE: $f"
    done
    git grep -l 'AGE-SECRET-KEY' || echo "no age private keys tracked"

Rendered-file drift (fingerprints only — never print a value):

    # RustFS backup env on nexus == store ciphertext?
    sha256sum <(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["data"])' \
      <(sops -d --output-type json secrets/storage/rustfs-backup-access-key-id.yaml)) \
      <(grep -oP '(?<=^export AWS_ACCESS_KEY_ID=).*' /dev/stdin)   # compare fp with the render line

Simpler: re-run the render script and confirm its printed fingerprints are unchanged.

Both checks on 2026-09-22: zero files with no envelope, zero age private keys tracked. The only
raw file found was untracked on disk (a sibling's work in progress) and was sops-encrypted before
commit — so nothing plaintext has ever entered git history.

## Rotating an auth token that a live path depends on (the overlap rule)

Rule 4 says rotation = update store → render → restart → verify by use. For a credential that
gates a *money-halt* path, "restart" is the dangerous step: the listener reads its allow-list at
adapter start, so switching the caller first gives a 401 window. Rotate with overlap instead:

1. seal the new set into the store (the store is the source of truth, so it moves first);
2. render **old + new** into each listener's allow-list and restart — both now authenticate
   (`_parse_peer_tokens` returns `{token: name}`, so one name may hold two tokens);
3. prove BOTH work (new → 200, old → 200) and that no-auth/unknown → 401;
4. switch the callers to the new token, then prove the real path end to end;
5. drop the old token, restart, and re-prove (new → 200, old → 401, junk → 401).

`scripts/a2a-peer-token-rotate.py rotate --yes` does exactly this, enforces the cross-host
consistency the mesh needs (`nexus.outbound[zephyr] == zephyr.inbound[nexus]`, and
`nexus.outbound[nexus] == nexus.inbound[nexus]` — the halt self-peer), and **refuses to write an
inconsistent set**. It stops on the last verified-good state, so an interrupted run leaves an
overlap (safe) rather than a half-rotated mesh. Run it from zephyr: it holds the age identity.
