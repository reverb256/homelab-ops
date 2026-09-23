# Fleet TRIM fix — staged 2026-09-23 (NOT rebooted)

## Why

Omarchy enables full-disk encryption but never allows TRIM through dm-crypt and never enables a trim timer. Measured on all four hosts: the encrypted root reports `discard_granularity 0`, `cryptsetup luksDump` shows `Flags: (no flags)`, `fstrim` returns "the discard operation is not supported", and `fstrim.timer` is disabled.

Upstream: issue #2229 (declined by the maintainer as "not needed on modern nvmes", reopened 2026-02-18 with current-gen NVMe data showing 400+ GiB of stale blocks), PRs #4840 (closed) and #5332 (open, based on the abandoned `dev` branch, `mergeable_state: dirty` because it patches `install/login/limine-snapper.sh`, which no longer exists on `quattro`).

## What was changed (additive, on each host)

`/etc/default/limine` — the `cryptdevice=` options field gained:

```
:allow-discards,no-read-workqueue,no-write-workqueue
```

Why those tokens, and which parser to trust, is recorded once in the `omarchy-boot-config` skill and in the header of `scripts/apply-luks-trim.sh` — do not re-derive it here. Short version: Omarchy's effective hook is `encrypt` (via the `omarchy_hooks.conf` drop-in, which overrides the `systemd` hooks in `/etc/mkinitcpio.conf`) and its parser whitelists exactly these three names.

`/etc/default/limine` is owned by **no package** (verified: `pacman -Qo` returns "No package owns"), so an update cannot revert it, and hand-editing it is the mechanism Omarchy's own migration 1789325478 uses (`sed`/`tee` + `limine-mkinitcpio` + `limine-entry-tool --tree` verification).

## State

| Host | staged | UKI rebuilt | entry verified | Secure Boot | rebooted |
|---|---|---|---|---|---|
| sentry | yes | yes | linux-omarchy | disabled | **YES — 2026-09-23 14:49, trimming** |
| forge | yes | yes | linux-omarchy | disabled | **NO** |
| nexus | yes | yes | linux-omarchy | disabled (setup) | **NO** |
| zephyr | not touched (workstation rule) | — | — | — | NO |

The running systems are unchanged. Each host picks the change up at its **next** boot, planned or not.

Rollback per host:

```
sudo cp /etc/default/limine.pre-trim-<timestamp> /etc/default/limine
sudo limine-mkinitcpio linux-omarchy
```

## Outcome: sentry rebooted 2026-09-23 14:49, and it trims

Proof read off the host after the boot:

    /proc/cmdline         cryptdevice=PARTUUID=beb6ecb2-...:root:allow-discards,no-read-workqueue,no-write-workqueue
    dmsetup table root    ... allow_discards no_read_workqueue no_write_workqueue sector_size:4096
    discard_granularity   4096   (0 before = discards blocked)
    findmnt -no OPTIONS / rw,relatime,compress=zstd:3,ssd,discard=async,...
    fstrim -v /           162.1 GiB trimmed on the first pass; a second pass trimmed 5.3 GiB

`silent-failure-sweep.sh` D10 flipped `sentry/root` from `trim-staged` (NOTE) to `trim-active` (PASS)
on its own — the check detects the transition without being told.

**These hosts cannot boot unattended, and that is the load-bearing fact for the rest of this
rollout.** There is no `cryptkey=` on the cmdline, `FILES=()` in `/etc/mkinitcpio.conf`, and no LUKS
TPM token — so the `encrypt` hook PROMPTS for the passphrase at the console on every boot. Rebooting
a headless host strands it until a human types the passphrase: sentry sat at that prompt for about
seven minutes. Before rebooting any of these hosts, confirm a human will be at the console. The
alternative is enrolling a TPM2 token, which requires the `systemd`/`sd-encrypt` hook path that
Omarchy's own drop-in replaces — a deliberate divergence, not a small edit.

So: **forge and nexus must be rebooted attended**, one at a time, verifying quorum between them.
Leaving the staged tokens in place is safe — a host that never reboots simply keeps running untrimmed.

Tradeoff, stated once: passing discards through dm-crypt tells the device which regions are free.
That is the accepted cost of TRIM on LUKS, and it is what the upstream fix does too.

## Verify after any future boot

```
sudo dmsetup table root | grep -o 'allow_discards\|no_read_workqueue\|no_write_workqueue'
sudo fstrim -v /
findmnt -no OPTIONS /        # btrfs auto-enables discard=async once discards pass through
```

## Relationship to the upstream fix

This is the same change the upstream PR implements as a migration. Because that migration is idempotent (it no-ops when the option is already present), a host staged here looks exactly like a host that already ran it. No conflict when the fix ships.

## Known follow-up

`sector-size` is also available through the same hook whitelist, and the fleet is split: sentry runs
`sector_size:4096` while nexus runs the 512-byte default, which multiplies crypto work per I/O on a
4K-native device. Separate change, separate reboot, attended.

## Repro script

`stage-trim-options.sh` in this directory performs the staged change with guards: it aborts if the config is missing, if there is no `cryptdevice=`, if the option is already present (idempotent no-op), if Secure Boot is enabled (a rebuilt UKI would need re-signing), if `/boot` has under 200 MB free, if the running kernel is not an omarchy kernel, or if the kernel package is absent. It backs up the config to `pre-trim-<timestamp>` and refuses to report success unless the boot entry exists after the rebuild.


