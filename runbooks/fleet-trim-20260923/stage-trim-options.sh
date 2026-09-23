#!/usr/bin/env bash
# Fleet TRIM fix, stage 1+2 (write + rebuild, NO reboot). Run on ONE host at a time.
# Adds the cryptdevice options, rebuilds the UKI, verifies the entry exists.
# Guards abort rather than risk an unbootable host.
set +e
TS=$(date +%Y%m%d-%H%M%S)
CONF=/etc/default/limine
ALREADY="allow-discards"
OPTS="allow-discards,no-read-workqueue,no-write-workqueue"

echo "########## 0. PREFLIGHT (read-only) ##########"
echo "  host: $(hostname)   $(date)"
echo "  /etc/default/limine:"
sudo cat "$CONF" 2>/dev/null | sed 's/^/    /'
echo "  LUKS mapping table flags:"
sudo dmsetup table root 2>/dev/null | sed 's/^/    /' | cut -c1-160
echo "  LUKS device + dm name from cmdline: $(grep -o 'cryptdevice=[^ ]*' /proc/cmdline)"
echo "  root source: $(findmnt -no SOURCE /)"
echo "  kernel pkg: $(pacman -Qq 2>/dev/null | grep -E '^linux' | tr '\n' ' ')"
echo "  boot entries:"; sudo limine-entry-tool --tree 2>/dev/null | head -12 | sed 's/^/    /'
echo "  /boot free: $(df -h /boot | tail -1 | awk '{print $4}')"
echo "  Secure Boot: $(bootctl status 2>/dev/null | grep -i 'Secure Boot' | head -2 | tr '\n' ' ')"
echo "  sbctl: $(sbctl status 2>/dev/null | grep -iE 'Secure Boot|Setup Mode' | tr '\n' ' ')"
echo "  quorum: $(sudo k3s kubectl get nodes --no-headers --request-timeout=15s 2>/dev/null | awk '{print $1,$2}' | tr '\n' ' ')"

echo
echo "########## GUARDS (abort instead of risking an unbootable host) ##########"
[[ -f $CONF ]] || { echo "!! ABORT: $CONF missing"; exit 1; }
grep -q 'cryptdevice=' "$CONF" || { echo "!! ABORT: no cryptdevice= in $CONF (unencrypted host?) - nothing to do"; exit 1; }
if grep -q "$ALREADY" "$CONF"; then echo "!! ABORT: '$ALREADY' already present - idempotent no-op"; exit 0; fi
if bootctl status 2>/dev/null | grep -qi 'Secure Boot: enabled'; then
  echo "!! ABORT: Secure Boot is ENABLED - a rebuilt UKI must be re-signed, which is out of scope for this stage."
  echo "   (Report this and stop: do not rebuild an unsigned UKI on an SB host.)"
  exit 2
fi
free_m=$(df -m /boot | tail -1 | awk '{print $4}')
(( free_m > 200 )) || { echo "!! ABORT: only ${free_m}M free on /boot"; exit 3; }

echo
echo "########## 1. BACK UP THE WORKING CONFIG AND THE UKI (a visible fallback entry) ##########"
sudo cp -a "$CONF" "$CONF.pre-trim-$TS" && echo "  config backed up: $CONF.pre-trim-$TS"
for uki in /boot/EFI/Linux/*.efi; do
  [[ -f $uki ]] || continue
  base=$(basename "$uki" .efi)
  case "$base" in *pre-trim*) continue;; esac
  sudo cp -a "$uki" "/boot/EFI/Linux/${base}-pre-trim-$TS.efi" && echo "  UKI fallback copy: ${base}-pre-trim-$TS.efi"
done

echo
echo "########## 2. APPLY THE OPTIONS (additive; preserves everything else) ##########"
sudo /usr/bin/python3 - "$CONF" "$OPTS" <<'PY'
import re, sys, pathlib
conf, opts = sys.argv[1], sys.argv[2]
p = pathlib.Path(conf)
text = p.read_text()
# Append the options to the value of cryptdevice=<spec>, after the existing ":<dmname>".
def add(m):
    val = m.group(1)
    if opts.split(',')[0] in val:
        return m.group(0)
    return f'cryptdevice={val}:{opts}'
new, n = re.subn(r'cryptdevice=([^ "\\\'\n]+)', add, text, count=1)
if n != 1:
    print(f"  !! expected exactly 1 cryptdevice=, found {n}"); sys.exit(1)
if new == text:
    print("  no change needed (already present)"); sys.exit(0)
p.write_text(new)
print("  patched:")
for line in new.splitlines():
    if 'cryptdevice=' in line:
        print("   ", line[:200])
PY
rc=$?; echo "  patch rc=$rc"; (( rc == 0 )) || { echo "!! ABORT: patch failed; restoring"; sudo cp -a "$CONF.pre-trim-$TS" "$CONF"; exit 4; }

echo
echo "########## 3. REBUILD THE UKI AND VERIFY THE ENTRY EXISTS ##########"
KERNEL=linux-omarchy
case "$(uname -r)" in *omarchy*) : ;; *) echo "!! ABORT: running kernel '$(uname -r)' is not an omarchy kernel - refusing to rebuild the wrong one"; exit 6 ;; esac
pacman -Qq "$KERNEL" >/dev/null 2>&1 || { echo "!! ABORT: package $KERNEL is not installed"; exit 7; }
sudo limine-mkinitcpio "$KERNEL" 2>&1 | tail -4 | sed 's/^/  /'
echo "  entries after rebuild:"; sudo limine-entry-tool --tree 2>/dev/null | head -12 | sed 's/^/    /'
if ! sudo limine-entry-tool --tree 2>/dev/null | grep -q "$KERNEL"; then
  echo "!! ABORT: no $KERNEL entry after rebuild; restoring config"
  sudo cp -a "$CONF.pre-trim-$TS" "$CONF"
  exit 5
fi

echo
echo "########## 4. PROOF: WHAT THE NEXT BOOT WILL USE ##########"
echo "  patched line in $CONF:"
sudo grep cryptdevice "$CONF" | sed 's/^/    /'
echo "  expected tokens present in that line: allow-discards, no-read-workqueue, no-write-workqueue"
echo
echo "########## STAGED. NOT REBOOTED (per instruction). ##########"
echo "  The running system is unchanged. The next reboot - planned or not - picks this up."
echo "  Rollback if wanted:  sudo cp $CONF.pre-trim-$TS $CONF && sudo limine-mkinitcpio $KERNEL"
echo "  After any future boot, verify with:"
echo "    sudo dmsetup table root | grep -o 'allow_discards\\|no_read_workqueue\\|no_write_workqueue'"
echo "    sudo fstrim -v /     &&     findmnt -no OPTIONS /"
