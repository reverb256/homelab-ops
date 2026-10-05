# Age Key Distribution Decision

## Status: RESOLVED 2026-09-23

Decision executed and verified. All quill SOPS files now have five recipients.

## Decision
**Option 1**: Copy the age identity (cluster-age-key.txt) to each Omarchy host that must decrypt secrets, with permissions 0600, and document the exact path.

## Rationale
- Prevents single point of failure (zephyr-only decryption).
- Ensures survivability if zephyr is unavailable.
- Simple, low-maintenance solution that leverages existing SOPS workflow.
- The YubiKey remains as a physical backup, but host copies enable immediate recovery without hardware dependency.

## Implementation

### Host key placement (all 0600, j_kro:j_kro)
- `zephyr:~/.config/sops/age/cluster-age-key.txt` — primary
- `nexus:~/.config/sops/age/cluster-age-key.txt` — added for durability

### SOPS recipients (all five — OR semantics, any one decrypts)
| Recipient | Type | PublicKey |
|-----------|------|-----------|
| `cluster_age` | cluster key | `age1567g6raae4adh97lrfhalc9wwhmtsulh89k9pkx24m5ezfh8a4xqndrt6l` |
| `zephyr_age_v2` | cluster key | `age12k7ch5r9sczu42zc6eutxtl6leudn47uv5fvsjrlq5ms0f0hz9nshm3t7q` |
| `yubikey_nano` | YubiKey 5 Nano | `age1yubikey1qtrfqkheehc6dlyux9stwq67dq3kcledlwzzrckx0wk639mh0wqh54auh7v` |
| `yubikey_nfc` | YubiKey 5 NFC | `age1yubikey1qvh5yeguawe89kr9muzn6xvfwjkcja7rf0j6afxgyula6p9vql4kkjh52h2` |
| `offline_recovery` | air-gapped | `age1td0zl0eexvgssdz2yljjg3wxnm60m3wytatg4uf3fgmn4z29kevstmgl6j` |

### Files updated
- `quill/.sops.yaml` — creation_rules now lists all five
- `quill/secrets/runtime.yaml` — re-sealed to all five
- `quill/secrets/billing.yaml` — re-sealed to all five
- `quill/secrets/cloudflared.yaml` — re-sealed to all five
- `quill/secrets/build.yaml` — re-sealed to all five
- `quill/secrets/README.md` — documents the five recipients and host paths
- `homelab-ops/runbooks/secrets-after-nixos.md` — decision resolved here

### Script behavior
The quill deploy/sync script (`scripts/sops-sync-k8s.sh`) uses `SOPS_AGE_KEY_FILE` and now works on nexus because the key is at the standard path.

## Verification

### On zephyr
```
$ SOPS_AGE_KEY_FILE=~/.config/sops/age/cluster-age-key.txt sops -d secrets/runtime.yaml
# Quill — runtime secrets (decrypted by sops-nix on nexus at boot)
```

### On nexus (proves host copy works)
```
$ SOPS_AGE_KEY_FILE=~/.config/sops/age/cluster-age-key.txt sops -d secrets/runtime.yaml
# Quill — runtime secrets (decrypted by sops-nix on nexus at boot)

$ SOPS_AGE_KEY_FILE=~/.config/sops/age/cluster-age-key.txt sops -d secrets/billing.yaml
STRIPE_SECRET_KEY: sk_live_... (value redacted)
```

All four files decrypt on both zephyr and nexus with the cluster_age key.

## Maintenance
- Rotate the age key following the procedure in `quill/secrets/README.md`.
- When rotating, copy the new private key to all designated hosts (zephyr, nexus, etc.) and update the YubiKeys if desired.
- Verify decryption on each host after rotation.

