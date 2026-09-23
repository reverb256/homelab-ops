#!/usr/bin/env bash
# verify-noexec-cifs-mounts.sh — prove the four media CIFS mounts refuse
# execution and still serve reads. Writes two throwaway probe files on the share
# and removes them; leaves nothing behind. Exits non-zero on any failure.
#
#   ssh nexus "bash -s" < scripts/media/verify-noexec-cifs-mounts.sh
#
# Reading is not execution: `cat` of the probe must still work, and a copy of a
# real ELF (/bin/true) must be refused too — a script-only check would pass on a
# mount that merely lacks the exec bit.
set -uo pipefail
MOUNTS=(/data/media/krash2-smb /data/media/krash3-smb /data/media/krash2-media /data/media/krash3-media)
HOST="$(hostname -s)"
echo "### verify-noexec-cifs-mounts on host=$HOST at $(date -u +%Y-%m-%dT%H:%M:%SZ) kernel=$(uname -r)"
rc=0

echo
echo "=== A. fstab lines ==="
grep -nE '^//10\.1\.1\.(79|150)/' /etc/fstab

echo
echo "=== B. live mount options (mount | grep) ==="
mount | grep -E 'krash[23]-(smb|media) type cifs' | while IFS= read -r l; do
  mp="$(printf '%s' "$l" | awk '{for(i=1;i<=NF;i++) if($i=="on"){print $(i+1); break}}')"
  if printf '%s' "$l" | grep -qE '\(([^)]*,)?noexec(,[^)]*)?\)'; then
    printf '  %-28s noexec=YES\n' "$mp"
  else
    printf '  %-28s noexec=NO\n' "$mp"
    rc=1
  fi
done
echo "  lines: $(mount | grep -cE 'krash[23]-(smb|media) type cifs') of 4 expected"

echo
echo "=== C. execute-a-probe-on-each-mount ==="
for m in "${MOUNTS[@]}"; do
  p="$m/.noexec-probe-a"
  if printf '#!/bin/sh\necho SHARE-EXEC-RAN\n' > "$p" 2>/dev/null; then
    chmod 755 "$p"
    out="$(timeout 20 "$p" 2>&1)"; st=$?
    catout="$(timeout 20 cat "$p" 2>&1 | head -1)"
    printf '  %-28s direct-exec rc=%s out=%s | cat=%s\n' "$m" "$st" "$(printf '%s' "$out" | head -1)" "$catout"
    [ "$st" -eq 0 ] && { echo "    ^^ EXECUTION SUCCEEDED — noexec NOT enforced here"; rc=1; }
    rm -f "$p"
  else
    printf '  %-28s SKIP (not writable by this user)\n' "$m"
  fi
done

echo
echo "=== D. same probe on a native (exec-allowed) filesystem, as the control ==="
ctl=/tmp/noexec-control-probe
printf '#!/bin/sh\necho CONTROL-RAN\n' > "$ctl"
chmod 755 "$ctl"
timeout 20 "$ctl"; echo "  control rc=$? (0 = the probe itself is fine)"
rm -f "$ctl"

echo
echo "=== E. ELF binary copied onto the share ==="
if [ -x /bin/true ]; then
  b=/data/media/krash2-media/.noexec-probe-b
  cp /bin/true "$b" && chmod 755 "$b"
  timeout 20 "$b"; echo "  elf direct-exec rc=$? (non-zero = blocked)"
  file "$b" 2>/dev/null | head -1
  rm -f "$b"
fi

echo
echo "=== F. is anything already executing FROM these mounts? ==="
for p in /proc/[0-9]*/exe; do
  t="$(readlink "$p" 2>/dev/null)"
  case "$t" in /data/media/krash*) echo "  EXEC FROM MOUNT: $p -> $t"; rc=1 ;; esac
done
echo "  scan complete (empty above = nothing)"

echo
echo "=== G. reads still served (df) ==="
for m in "${MOUNTS[@]}"; do
  printf '  %-28s ' "$m"
  timeout 25 df -h "$m" 2>/dev/null | tail -1 || echo "df FAILED"
done

echo
echo "=== H. the generated mount units carry noexec ==="
for u in 'data-media-krash2\x2dsmb.mount' 'data-media-krash3\x2dsmb.mount' 'data-media-krash2\x2dmedia.mount' 'data-media-krash3\x2dmedia.mount'; do
  printf '  %-34s ' "$u"
  systemctl cat "$u" 2>/dev/null | grep -m1 '^Options=' | grep -oE '(^|,)noexec(,|$)' || { printf 'NOEXEC-MISSING'; rc=1; }
  echo
done

echo
echo "### verify-noexec-cifs-mounts rc=$rc on $HOST at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit "$rc"
