# Secure Boot and TPM unlock on the Omarchy fleet — decided NO (2026-08-24)

**Decision: do not enable Secure Boot, and do not pursue TPM-backed LUKS
auto-unlock.** This file records the evidence so the question does not get
re-litigated from scratch.

Full-disk encryption **is** already on and working — Omarchy enables LUKS2 by
default. What is declined here is the *unattended unlock* and *verified boot*
layer on top of it.

## Fleet state (verified, read-only)

| Host | Secure Boot | SetupMode | PK/KEK/db | Bootloader | TPM | Board |
|------|-------------|-----------|-----------|------------|-----|-------|
| zephyr | disabled | 0 (user mode) | **present** | Limine 12.6.0 | 2.0 | MSI MAG X570 TOMAHAWK WIFI (MS-7C84) |
| nexus | disabled (setup) | 1 | **absent** | Limine 12.5.2 | 2.0 | Gigabyte X470 AORUS ULTRA |
| forge | disabled | 0 (user mode) | — | systemd-boot 261.1 | 2.0 | MSI B360-F PRO (MS-7B25) |
| sentry | disabled (setup) | 1 | **absent** | systemd-boot 261.1 | 2.0 | ASRock B450M-HDV R4.0 |

All four are genuine UEFI 2.70 (AMI) with TPM 2.0. The hardware is capable; the
feature is simply off everywhere.

`SetupMode=1` (nexus, sentry) means **no Secure Boot keys are enrolled at all**,
so `sbctl enroll-keys` would work there without a firmware trip. zephyr and forge
are in user mode with factory keys, so enrolling a custom PK needs BIOS access.

## Reason 1 — zephyr's firmware does not enforce Secure Boot (FQ0001)

`sbctl status` on zephyr:

```
Firmware: ‼ Your firmware has known quirks
  - FQ0001: Defaults to executing on Secure Boot policy violation (CRITICAL)
```

zephyr's board (MSI MAG X570 TOMAHAWK WIFI) is named on the FQ0001 affected list.
Per the sbctl wiki:

> This firmware quirk causes the device to not perform any Secure Boot
> verification, making it execute any operating system or Option ROM, even if it
> isn't signed by a trusted key.

MSI shipped this across **all firmware versions** for this board; zephyr is on
BIOS 1.K1 (2025-09-10), so it is not fixed by updating. Enabling Secure Boot here
would report "enabled" while enforcing nothing — security theatre with real
recurring cost (re-signing the UKI and 4 nvidia out-of-tree modules on every
kernel/driver update).

forge is also MSI (B360-F PRO) and should be FQ0001-checked before anyone
reconsiders it there.

## Reason 2 — Omarchy has no TPM tooling and tells you to disable TPM

Checked at **upstream tip** (`origin/quattro`), not just the local checkout,
which was 39 commits behind:

- `git log --all --grep` for `tpm`, `cryptenroll`, `secure boot` → **zero commits
  in the entire project history**
- `git grep` across `bin/ install/ manual/ docs/ migrations/` → one hit only

That single hit, `manual/02-getting-started.md:7`, is the official position:

> *You must turn off Secure Boot and/or TPM in the BIOS. You have to turn these
> off to be able to install Omarchy. They're Microsoft security schemes meant for
> Windows and Microsoft-affiliated Linux distributions.*

(The reasoning is loose — `systemd-cryptenroll` is standard Linux, not a
Microsoft scheme — but the practical stance is unambiguous.)

Omarchy's LUKS tooling is entirely passphrase-based:

| Tool | Behavior |
|------|----------|
| `omarchy-provision-owner` | re-keys LUKS from throwaway install key → owner passphrase |
| `omarchy-system-factory-reset` | `cryptsetup luksAddKey` to a throwaway passphrase |
| `omarchy-upgrade-to-quattro` | preserves `cryptdevice=` / `rd.luks.*` cmdline params |
| Menu → *Update > Password > Drive Encryption* | changes the passphrase |

`manual/48-security.md` describes exactly two passwords (drive, user). No TPM
path exists.

## Reason 3 — the initrd cannot do TPM unlock as shipped

The measurement foundation **is** present on zephyr — this corrects an earlier
misreading of `bootctl`:

```
Measured UKI: yes
 Measured OS: yes
Current Stub: systemd-stub 261.2-1-arch
PCR  7: A869BC6E0BDBF30D…   (non-zero)
PCR 11: F1ADAB0653608C81…   (non-zero)
```

`bootctl`'s `✗ Loader reports active TPM2 PCR banks` is a **Limine feature flag**
(whether the loader advertises PCR banks via an EFI variable), *not* a statement
that measurement is absent. `systemd-stub` inside the UKI does the measuring
regardless of Limine.

The real obstacle is the unlock path. Effective hooks come from
`/etc/mkinitcpio.conf.d/omarchy_hooks.conf`, which **replaces** `HOOKS` from the
main conf:

```
main conf:  base systemd autodetect ... block filesystems fsck            ← overridden, unused
drop-in:    base udev plymouth ... block encrypt filesystems fsck ...     ← live
cmdline:    cryptdevice=PARTUUID=…:root root=/dev/mapper/root
```

`encrypt` is the **busybox** hook: passphrase and keyfile only. Confirmed by
initrd contents — it ships `usr/bin/cryptsetup` but **no** `systemd-cryptsetup`,
no `systemd-cryptsetup-generator`, no `pcrphase`, no tpm2 modules.

Consequence: `systemd-cryptenroll` would happily add a TPM2 keyslot to the LUKS
header and **the initrd would ignore it**, still prompting for the passphrase.

Making it work means `encrypt` → `sd-encrypt`, adding
`/etc/crypttab.initramfs`, and changing the cmdline to `rd.luks.name=` — i.e.
overriding Omarchy's own hook drop-in, against the defer-to-Omarchy rule.

## Reason 4 — PCR 11 churn breaks unlock on every kernel update

The UKI carries **no `.pcrsig` / `.pcrpkey` sections** (verified via `objdump -h`),
so enrollment must bind to *literal* PCR values. PCR 11 measures the kernel and
initrd, so it changes on every kernel update — unlock breaks and needs
re-enrollment each time.

Durable alternatives, neither wired up here:
- `--tpm2-public-key-pcrs=11` signed policy, which needs `ukify` to embed
  `.pcrsig`/`.pcrpkey`
- `systemd-pcrlock`

Also note: binding to PCR 7 (`secure-boot-policy`) is near-worthless on zephyr,
since PCR 7 would only record "Secure Boot disabled" on a board that does not
enforce it anyway. PCR 11 is what would carry the actual value — defeating
kernel substitution and offline disk theft.

## If this is ever revisited

Do it on **nexus**, not zephyr:
- also LUKS2, also Omarchy, so the same lessons apply
- `SetupMode=1`, no keys enrolled → no BIOS trip for enrollment
- not the host Hermes runs on, so a clobbered initrd costs a service, not the
  workstation

And decide the PCR-churn strategy (signed policy or `pcrlock`) **before**
enrolling. Always keep the existing pbkdf2 passphrase keyslot as rollback —
`systemd-cryptenroll` adds slots; never wipe the passphrase slot.

## What is already true without any of this

- LUKS2 full-disk encryption on zephyr (`nvme1n1p2`) and nexus, passphrase at boot
- Data at rest is protected against disk theft, which is the main threat for
  homelab hardware
- The cost of the declined work is unattended reboots, not encryption itself
