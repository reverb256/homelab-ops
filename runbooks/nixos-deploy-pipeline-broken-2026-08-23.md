# NixOS deploy pipeline is BROKEN after the nexus Omarchy migration

Status: **blocked, pre-existing, not caused by any current change.** Discovered
2026-08-23 while trying to deploy a one-line `tailscale.nix` fix to forge/sentry.

## Summary

`just deploy <host>` cannot work. Three independent dependencies on nexus died
when it was reinstalled on Omarchy, plus a scoped deploy key blocks flake eval
on the only remaining viable builder.

## The four breakages

### 1. The builder is gone

`justfile` routes every build through `scripts/deploy/nexus-dispatch.sh` and
runs `ssh nexus "cd /etc/nixos && nix build …"`. nexus has no `/etc/nixos` and
no `nix` binary — it is Arch now.

```
$ ssh nexus 'ls -d /etc/nixos; which nix'
ls: cannot access '/etc/nixos': No such file or directory
which: no nix in (/usr/local/bin:/usr/bin:/bin)
```

zephyr cannot substitute: it is also Omarchy with no Nix, and was deliberately
never a builder (31GB, OOMs).

### 2. The `central` git remote is gone

`nixos-config` has `central → j_kro@10.1.1.120:/srv/git/nixos-config.git`.
That bare repo lived on nexus and was destroyed. `/srv/git` no longer exists.

### 3. The LAN binary cache is gone

`/etc/nix/nix.conf` on forge and sentry lists
`http://10.1.1.110:50000?priority=90` — a `nix-serve` on zephyr. Port 50000 is
refused; zephyr no longer serves it. Because priority 90 is queried early, every
uncached path costs **10s of timeout × up to 10 retries** before falling through
to `cache.nixos.org`. This does not fail the build, it just makes every eval
crawl. `nexus-cache-1:…` is also still in `trusted-public-keys`.

### 4. sentry's root deploy key is scoped to one repo — this is the hard blocker

sentry is otherwise a fine builder (16 cores, 19GB free, Lix present). But any
flake eval dies with:

```
error: program 'git' failed with exit code 128
```

Root cause: the flake has two **private** inputs fetched over SSH —
`nixos-secrets` and `home-manager-config`. Root's key on sentry authenticates as
a **repo-scoped deploy key for `nixos-config` only**:

```
$ sudo ssh git@github.com
Hi reverb256/nixos-config! You've successfully authenticated…      # deploy key

$ sudo git ls-remote ssh://git@github.com/reverb256/nixos-secrets
Please make sure you have the correct access rights                # DENIED
```

`j_kro`'s own key reaches both repos, so the credential exists — it just isn't
the one the eval uses.

**Verified pre-existing:** reverting `modules/system/tailscale.nix` to the
committed version and re-evaluating produces the identical exit-128. This is not
caused by the tailscale change.

Ruled out via the `nix-flake-hygiene` skill: not the `git+https` private-repo
prompt (the flake already uses `git+ssh://`), and not sudo credential loss (it
fails as `j_kro` too, because the nix daemon does the fetch as root).

## Why nothing is on fire right now

Tailscale SSH is **already enabled and durable** on all three hosts without a
deploy. `RunSSH: true` is persisted in `/var/lib/tailscale/tailscaled.state`, so
it survives reboot on its own.

The committed fix still matters: run interactively, bare `tailscale set --ssh`
aborts (exit 0, no change). From a systemd context there is no TTY warning, so
the current `tailscaled-set` unit applies `--ssh=true` correctly — verified by
running it and confirming `RunSSH: true` plus a live connection afterward. So the
existing units will not revert the setting; the fix removes the interactive
footgun and makes the intent explicit.

Garage, the miners, and both SSH paths are all healthy and independent of this.

## Fix options, cheapest first

1. **Give sentry's root a key that can read both private repos.** Either add
   root's existing pubkey as a deploy key on `nixos-secrets` and
   `home-manager-config`, or point root's SSH config at a key with account-level
   access. Smallest change; unblocks eval immediately.
2. **Drop the dead cache from `nix.conf`.** Remove
   `http://10.1.1.110:50000` and the stale `nexus-cache-1` trusted key. This is
   a config change needing a deploy — chicken-and-egg with (1), so do (1) first.
3. **Repoint the deploy pipeline at sentry.** `justfile` and
   `scripts/deploy/nexus-dispatch.sh` hardcode nexus as dispatcher/builder.
   Needs a real rewrite, not a find-replace: `contracts/host-inventory.nix` and
   the colmena machine list also assume nexus is a NixOS node.
4. **Delete the `central` remote**, or re-host the bare repo somewhere alive.
5. **Decide nexus's role.** It is no longer a NixOS host, so `hosts/nexus/` and
   its dendritic registry entry are dead code. Removing them is what actually
   retires the ambiguity.

## Do not

- Do not "fix" this by pointing the builder at forge: it has **2GB available**
  of 15GB total and runs two revenue-critical miners. Building there risks OOM
  on a mining host.
- Do not run `nix flake update` while chasing this — the failure is an auth
  problem on a private input, not lock drift, and an update would rewrite pins
  that are deliberate (see `nix-flake-hygiene`).
