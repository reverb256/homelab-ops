# SSH architecture — homelab fleet

Status: **Tailscale SSH enabled and verified on forge, sentry, nexus**
(2026-08-23). Key-based SSH still works everywhere as the fallback.

## The decision

Use **Tailscale SSH** as the primary access path. Keep OpenSSH key auth as a
fallback. Do not build a key-distribution mechanism.

Rationale: the fleet had one shared keypair copied across three hosts, an
11-entry `authorized_keys` on nexus sourced from a GitHub account, and a
`mesh-keys.nix` that matched no host's reality. Tailscale SSH removes the
problem class instead of automating it — authorization moves to the tailnet
policy, which is one place, applies in seconds, and revokes live sessions.

## How it works

Tailscale claims port 22 **for tailnet traffic only** and routes it to its own
SSH server. It does not touch `sshd_config` or `authorized_keys`. Non-tailnet
SSH (LAN, direct IP) continues to hit OpenSSH normally. Both paths coexist —
verified on all three hosts.

Authentication uses the WireGuard node key. There is no SSH keypair involved,
so nothing to rotate, copy, or leave behind on a host.

## Current state

| Host | Tailscale IP | Tailscale SSH | Key SSH | Port 22 exposure |
|------|--------------|---------------|---------|------------------|
| zephyr | 100.91.11.2 | n/a (client) | sshd **disabled** | nothing listening |
| nexus | 100.76.105.73 | ✅ enabled | ✅ works | ufw: tailnet only |
| forge | 100.126.31.20 | ✅ enabled | ✅ works | LAN + tailnet |
| sentry | 100.86.28.49 | ✅ enabled | ✅ works | LAN + tailnet |

All devices are owned by a single user (`reverb256@`), so the **default tailnet
policy** already grants access via `autogroup:self`. No ACL edit was needed.

## Usage

```bash
tailscale ssh j_kro@nexus        # primary path, no key
ssh nexus                        # fallback, uses ~/.ssh/id_ed25519
```

`~/.ssh/config` points `nexus` at its tailnet IP because nexus's ufw allows 22
only on `tailscale0` — its LAN address refuses connections.

## Enabling on a new host

```bash
sudo tailscale set --ssh --accept-risk=lose-ssh
```

`--accept-risk=lose-ssh` is required when you are connected over Tailscale: the
command reroutes tailnet:22 mid-session. It is safe — the reroute is what you
want — but read the warning before accepting it.

Rollback is immediate and was verified on forge:

```bash
sudo tailscale set --ssh=false
```

### Order matters

Enable on hosts with a **LAN SSH fallback first**. nexus has none (ufw is
tailnet-only), so it went last, and only after a temporary LAN allow rule was
added *and* key auth through it was verified. The rule was removed afterward
and LAN 22 confirmed closed again.

```bash
# safety net for a host with no fallback
sudo ufw allow from 10.1.1.0/24 to any port 22 proto tcp comment "temp"
# ...verify LAN key auth works, then flip, then...
sudo ufw --force delete <rule-number>
```

## What is NOT yet done

1. **Not declarative.** `tailscale set --ssh` is imperative local state. On
   forge/sentry this belongs in `services.tailscale` in nixos-config; on nexus
   it belongs in the Omarchy applier. Right now a reinstall loses it.
2. **`mesh-keys.nix` is stale and misleading.** It declares 4 keys; forge and
   sentry each authorize exactly 1, and the `j_kro@nexus` entry is a dead key
   from the wiped host. Two entries were dropped by an unrelated
   "sync: reset to central/main" commit. Either fix it or retire it.
3. **One keypair is copied across three hosts.** `~/.ssh/id_ed25519` is
   byte-identical on zephyr, forge, and sentry. Compromising any one yields
   all three. Tailscale SSH makes this less load-bearing, but it is still true.
4. **Password auth is enabled on nexus.** `PasswordAuthentication` is set
   nowhere in `/etc/ssh/`, so OpenSSH's default (`yes`) applies and sshd
   advertises `publickey,password`. The old NixOS config set it to `no`. ufw
   limits reach to the tailnet, but this should be turned off.
5. **nexus authorizes 11 keys, all from GitHub.** The Omarchy installer pulled
   them from `github.com/reverb256.keys`. That makes the GitHub account an SSH
   trust root. Decide whether that is acceptable; with Tailscale SSH working,
   the file can likely be trimmed to one break-glass key.

## Findings worth remembering

- **`SSH_HostKeys` in `tailscale status --json` is not a reliable indicator.**
  It read `False` on all hosts while `RunSSH: true` and real connections
  succeeded. Test with an actual `tailscale ssh` connection instead.
- **forge and sentry default to fish, not bash.** Remote commands using `$?`,
  `for f in *.pub`, or other bash syntax fail silently or misreport. Wrap
  every remote command in `bash -lc '...'`. An unwrapped `sudo -n` test made
  passwordless sudo look unavailable when it was actually fine on all three.
- **`OperatorUser` does not cover `--ssh`.** nexus has `OperatorUser: j_kro`,
  which permits most `tailscale` calls without sudo, but `set --ssh` still
  requires root.
- **Tailscale versions drift:** nexus/zephyr 1.102.3, forge/sentry 1.98.9.
