# Secrets after NixOS — sops + age on Arch/Omarchy

Status: **working.** All 76 secrets in `nixos-secrets` decrypt on zephyr with
no NixOS host involved (verified 2026-08-24).

## Why this had to happen first

`sops-nix` dies with NixOS. Worse, before this work the two plaintext age
private keys existed on **exactly one host** — `sentry:/etc/nixos/.age/key.txt`.
Zephyr's copies were destroyed in its nvme wipe.

So reinstalling sentry before extracting that key would have left the two
YubiKeys as the only path to every secret in the fleet. That is a one-way door,
and it gated the whole migration.

The key is now on zephyr at `~/.config/sops/age/keys.txt` (0600). It holds both
plaintext recipients:

| Recipient | Alias in `.sops.yaml` |
|-----------|----------------------|
| `age1567g6raae4adh97lrfhalc9wwhmtsulh89k9pkx24m5ezfh8a4xqndrt6l` | `cluster_age` |
| `age12k7ch5r9sczu42zc6eutxtl6leudn47uv5fvsjrlq5ms0f0hz9nshm3t7q` | `zephyr_age_v2` |

The other two recipients are YubiKeys (`age1yubikey1…`) — host-independent
backstop, see the `age-yubikey-decrypt` skill.

## The circular dependency (do not design around garage)

Garage's own S3 credentials (`garage-rpc-secret`, `garage-s3-access-key-id`,
`garage-s3-secret-key`) are **themselves sops-encrypted in this repo**. So the
age key can never live only in garage — you would need garage to start garage.

The key must live somewhere reachable with **no secrets at all**: a local file
on each host, a YubiKey, or an offline copy. `nixos-secrets` (private GitHub
repo) correctly holds only ciphertext — verified no `AGE-SECRET-KEY` material is
committed.

## Usage on Arch

`sops` and `age` are both in Arch `extra` — no AUR, no Nix:

```bash
sudo pacman -S --needed sops age
```

Decrypt:

```bash
cd ~/Projects/nixos-secrets
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -d secrets/storage/garage-rpc-secret.yaml                  # whole file
sops -d --extract '["data"]' secrets/ai/memlawb-passphrase.yaml  # just the value
```

Every secret in this repo uses a single `data:` key, so the `--extract '["data"]'`
form is what you want when piping a value into a file or env var.

## Provisioning a secret onto a host

This replaces what `sops-nix` did declaratively. Decrypt on zephyr, pipe over
SSH, install root-owned:

```bash
cd ~/Projects/nixos-secrets
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -d --extract '["data"]' secrets/storage/garage-rpc-secret.yaml \
  | ssh nexus "sudo install -Dm600 -o root -g root /dev/stdin /etc/garage-secrets/garage-rpc-secret"
```

Note the mode: a service running as a non-root user needs the *config* readable
by its group (garage's `/etc/garage.toml` is `0640 root:garage`), but the raw
secret files stay `0600 root:root` and are only read by the apply script.

## Hermes .env auto-sync (zephyr)

`~/.local/bin/sops-hermes-env-sync.sh` pulls every Hermes-consumed key from
this repo into `~/.hermes/.env`. Runs at login via
`systemctl --user enable hermes-secrets-sync.service`; also safe to run by hand.
Store wins. A decrypt returning empty never blanks a live key.

To manage an additional key: encrypt it here (`data:` binary format, all five
recipients), then add one line to the `MAP=(...)` table in the script.

## Verification

```bash
~/Projects/homelab-ops/scripts/test-ai-keys.sh   # live auth check per key
```

```bash
cd ~/Projects/nixos-secrets
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
ok=0; fail=0
for f in $(git ls-files 'secrets/**/*.yaml'); do
  sops -d "$f" >/dev/null 2>&1 && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL $f"; }
done
echo "ok=$ok fail=$fail"
```

Result 2026-08-24: **ok=76 fail=0**.

## Open

1. **Only zephyr has the key.** Same single-point-of-failure shape as before,
   just moved. Decide the durable answer: a copy on each Omarchy host, a
   password manager, or YubiKey-only with a documented recovery drill.
2. **No rotation since 2026-07-25.** `.sops.yaml` notes that rotation followed
   a data-loss incident. Worth scheduling.
3. **`nixos-secrets/flake.nix` is now vestigial** — it exists so NixOS could
   consume the repo as a flake input. Nothing on Arch needs it.
