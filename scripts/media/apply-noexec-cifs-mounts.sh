#!/usr/bin/env bash
# apply-noexec-cifs-mounts.sh — put `noexec` on the four krash2/krash3 CIFS media
# mounts, in /etc/fstab AND on the live superblocks.
#
#   ssh nexus "bash -s" < scripts/media/apply-noexec-cifs-mounts.sh
#   ssh forge "bash -s" < scripts/media/apply-noexec-cifs-mounts.sh
#
# Why both places: fstab is what survives a reboot, but every one of these
# mounts is `x-systemd.automount` with `timeout=0`, so it never idles out and
# `systemctl daemon-reload` alone changes nothing on the running host. The live
# flag has to be put there with `mount -o remount,noexec <mountpoint>`, which on
# cifs preserves every other option (credentials, vers, cache) and needs no
# unmount — no pod is disturbed.
#
# Idempotent: a line that already has noexec is left byte-identical, a run that
# changes nothing writes no backup and installs nothing, and stages 3-6 still
# assert the live state. Fail-closed: it aborts unless it finds exactly 4 target
# lines and each carries the `noperm,` anchor it inserts next to. Exits non-zero
# if any of the four mounts ends up without noexec, or a unit's options do.
set -uo pipefail

F="${FSTAB:-/etc/fstab}"
MOUNTS=(/data/media/krash2-smb /data/media/krash3-smb /data/media/krash2-media /data/media/krash3-media)
HOST="$(hostname -s)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

echo "### apply-noexec-cifs-mounts on host=$HOST at $(date -u +%Y-%m-%dT%H:%M:%SZ) kernel=$(uname -r)"

echo "--- stage 0: preflight ---"
if ! sudo -n true 2>/dev/null; then echo "FAIL: passwordless sudo unavailable"; exit 1; fi
echo "  sudo: ok"

echo "--- stage 1: build the candidate /etc/fstab and decide ---"
tmp="$(mktemp)"
targets=0
changed=0
while IFS= read -r line || [ -n "$line" ]; do
  if printf '%s' "$line" | grep -qE '^//10\.1\.1\.(79|150)/[^[:space:]]+[[:space:]]+/data/media/krash[23]-(smb|media)[[:space:]]+cifs[[:space:]]'; then
    targets=$((targets + 1))
    mp="$(printf '%s' "$line" | awk '{print $2}')"
    if printf '%s' "$line" | grep -qE '(^|,)noexec(,|$)'; then
      printf '%s\n' "$line" >> "$tmp"
      printf '  %-28s already has noexec (no change)\n' "$mp"
    else
      case "$line" in
        *noperm,*)
          printf '%s\n' "${line/noperm,/noperm,noexec,}" >> "$tmp"
          changed=$((changed + 1))
          printf '  %-28s + noexec\n' "$mp"
          ;;
        *)
          printf 'FAIL: no "noperm," anchor to insert next to, in: %s\n' "$line"
          rm -f "$tmp"; exit 1
          ;;
      esac
    fi
  else
    printf '%s\n' "$line" >> "$tmp"
  fi
done < "$F"

printf '  cifs target lines found: %s (expect 4), changed: %s\n' "$targets" "$changed"
if [ "$targets" -ne 4 ]; then echo "FAIL: expected exactly 4 krash cifs lines in $F"; rm -f "$tmp"; exit 1; fi

echo "--- stage 2: back up and install (only if there is something to install) ---"
if cmp -s "$F" "$tmp"; then
  echo "  /etc/fstab already correct — no backup, nothing installed"
  rm -f "$tmp"
else
  bk="/etc/fstab.bak-${TS}-noexec"
  sudo -n cp -a "$F" "$bk" || { echo "FAIL: backup failed"; rm -f "$tmp"; exit 1; }
  echo "  backup: $bk"
  echo "  --- fstab diff for the krash lines (old vs new) ---"
  diff <(grep -E '^//10\.1\.1\.(79|150)/' "$F") <(grep -E '^//10\.1\.1\.(79|150)/' "$tmp")
  drc=$?
  if [ "$drc" -ne 1 ]; then echo "FAIL: expected diff rc=1, got rc=$drc"; rm -f "$tmp"; exit 1; fi
  sudo -n tee "$F" < "$tmp" > /dev/null || { echo "FAIL: install failed"; rm -f "$tmp"; exit 1; }
  rm -f "$tmp"
  echo "  installed new $F"
fi

echo "--- stage 3: validate + regenerate systemd units ---"
findmnt --verify --verbose > /tmp/fstab-verify.txt 2>&1
echo "  findmnt --verify rc=$?"
grep -E '^\s*\[W\]|^\s*\[E\]' /tmp/fstab-verify.txt | head -5
sudo -n systemctl daemon-reload || { echo "FAIL: daemon-reload"; exit 1; }
echo "  daemon-reload: ok"

echo "--- stage 4: live remount with noexec ---"
for m in "${MOUNTS[@]}"; do
  if mountpoint -q "$m"; then
    if sudo -n mount -o remount,noexec "$m" 2>&1; then
      echo "  remounted: $m"
    else
      echo "  FAILED remount: $m"
    fi
  else
    echo "  not currently mounted (automount will pick up fstab on next access): $m"
  fi
done

echo "--- stage 5: verify live mount options (kernel per-mount flags) ---"
bad=0
for m in "${MOUNTS[@]}"; do
  line="$(mount | grep -F " on $m type cifs ")"
  if [ -z "$line" ]; then
    printf '  %-28s NOT-MOUNTED\n' "$m"; bad=1
  elif printf '%s' "$line" | grep -qE '\(([^)]*,)?noexec(,[^)]*)?\)'; then
    printf '  %-28s NOEXEC-OK\n' "$m"
  else
    printf '  %-28s NOEXEC-MISSING\n' "$m"; bad=1
  fi
done
echo "  mount | grep counts: $(mount | grep -cE 'krash[23]-(smb|media) type cifs') of 4"

echo "--- stage 6: the generated unit carries the new fstab options ---"
# Read the generator output, NOT `systemctl show -p Options`: for an *active*
# mount that property is systemd's cached copy of /proc/self/mountinfo, which
# lags a hand remount by a few seconds and reads as a missing noexec.
for u in 'data-media-krash2\x2dsmb.mount' 'data-media-krash3\x2dsmb.mount' 'data-media-krash2\x2dmedia.mount' 'data-media-krash3\x2dmedia.mount'; do
  printf '  %-34s ' "$u"
  if systemctl cat "$u" 2>/dev/null | grep -m1 '^Options=' | grep -qE '(^|,)noexec(,|$)'; then
    echo "noexec present"
  else
    echo "NOEXEC-MISSING"; bad=1
  fi
done

echo "--- stage 7: etckeeper ---"
if command -v etckeeper >/dev/null 2>&1; then
  if [ "$changed" -gt 0 ]; then
    sudo -n etckeeper commit -m "fstab: add noexec to the four krash2/krash3 cifs media mounts" 2>&1 | tail -3
  else
    echo "  nothing changed in /etc/fstab — no etckeeper commit"
  fi
else
  echo "  etckeeper NOT installed on $HOST — /etc is not under version control here"
fi

echo "### done on $HOST at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit "$bad"
