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
| Cloudflare (tokens, tunnels) | sops store + API | `GET /user/tokens/verify` |

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
  files on three hosts.
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
