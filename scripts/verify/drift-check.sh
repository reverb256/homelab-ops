#!/usr/bin/env bash
# drift-check - D9: committed tree vs installed host state. DETECTION ONLY.
#
# homelab-ops has no ArgoCD Application for host state: `omarchy/<host>/` is
# applied by that host's own apply.sh, so the host can drift from the committed
# tree silently and nothing notices. This check hashes every committed file
# against its installed counterpart and reports the difference.
#
# It NEVER applies, copies, or repairs anything. There is no apply mode.
# Output matches scripts/verify/silent-failure-sweep.sh:
#   verdict | section | item | signal | expected
#
# Exit: 0 clean, 1 drift/missing found, 3 a host was unreachable (unknown, not
# clean - an unreachable host must never read as "in sync").
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OMARCHY="$ROOT/omarchy"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8"
emit() { printf '%-9s | %-22s | %-46s | %-52s | %s\n' "$1" "$2" "$3" "$4" "$5"; }

# Committed path (relative to omarchy/<host>/) -> installed absolute path.
# Derived from the `install_file` calls in each host's apply.sh.
map_dst() {
  case "$1" in
    README*|apply.sh|*.template|*.env|*.md|*authorized_keys*|*.jsonl) echo ""; return ;;
    bin/*)               echo "/usr/local/bin/${1#bin/}" ;;
    usr/*)               echo "/${1}" ;;
    etc/*)               echo "/${1}" ;;
    systemd/*)           echo "/etc/systemd/system/${1#systemd/}" ;;
    systemd-user/*)      echo "$HOME/.config/systemd/user/${1#systemd-user/}" ;;
    modules-load.d/*)    echo "/etc/modules-load.d/${1#modules-load.d/}" ;;
    modprobe.d/*)        echo "/etc/modprobe.d/${1#modprobe.d/}" ;;
    udev/*)              echo "/etc/udev/rules.d/${1#udev/}" ;;
    tmpfiles.d/*)        echo "/etc/tmpfiles.d/${1#tmpfiles.d/}" ;;
    ssh/10-hardening.conf) echo "/etc/ssh/sshd_config.d/10-hardening.conf" ;;
    garage-buckets.tsv)  echo "/etc/garage-buckets.tsv" ;;
    *)                   echo "" ;;
  esac
}

drifted=0
missing=0
unmapped=0
unreachable=0
checked=0

for hostdir in "$OMARCHY"/*/; do
  host="$(basename "$hostdir")"
  [ -d "$hostdir" ] || continue
  files="$(find "$hostdir" -type f 2>/dev/null | sort)"
  [ -n "$files" ] || continue

  local_host=0
  [ "$host" = "$(hostname)" ] && local_host=1

  if [ "$local_host" = 0 ]; then
    if ! ssh $SSH_OPTS "$host" true 2>/dev/null; then
      nfiles="$(printf '%s\n' "$files" | grep -c .)"
      emit FINDING D9 host-unreachable "$host" "ssh failed ($nfiles committed files unverifiable)" \
        "reachable host (unreachable is unknown, not in-sync)"
      unreachable=$((unreachable + 1))
      continue
    fi
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$hostdir"}"
    dst="$(map_dst "$rel")"
    if [ -z "$dst" ]; then
      emit NOTE D9 unmapped "$host/$rel" "no install mapping" "add a map_dst entry when the file is installed"
      unmapped=$((unmapped + 1))
      continue
    fi
    want="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1 | tr -d '\\')"
    if [ "$local_host" = 1 ]; then
      have="$(sudo sha256sum "$dst" 2>/dev/null | cut -d' ' -f1)"
    else
      have="$(ssh $SSH_OPTS "$host" "sudo sha256sum '$dst' 2>/dev/null" 2>/dev/null | cut -d' ' -f1 | tr -d '\\')"
    fi
    checked=$((checked + 1))
    if [ -z "$have" ]; then
      emit FINDING D9 installed-missing "$host:$dst" "committed but not installed" "installed file matches the tree"
      missing=$((missing + 1))
    elif [ "$want" = "$have" ]; then
      emit OK D9 in-sync "$host:$dst" "sha256 ${want:0:12}" "committed tree hash"
    else
      emit FINDING D9 drifted "$host:$dst" "installed ${have:0:12} != committed ${want:0:12}" \
        "installed content equals the committed tree"
      drifted=$((drifted + 1))
    fi
  done <<<"$files"
done

emit NOTE D9 coverage "$ROOT/omarchy" \
  "checked=$checked drifted=$drifted missing=$missing unmapped=$unmapped unreachable=$unreachable" \
  "detection only; drift is repaired by hand (apply.sh), never by this check"

if [ "$unreachable" -gt 0 ]; then exit 3; fi
if [ "$drifted" -gt 0 ] || [ "$missing" -gt 0 ]; then exit 1; fi
exit 0
