#!/bin/bash
# Phase 4 of the bcache re-attach (nexus, 2026-09-23): repartition /dev/sdb.
#
# RUN THIS OUTSIDE THE AGENT. It contains `mkfs.btrfs`, which Hermes's hardline
# blocklist refuses to execute at ANY approval level (no --yolo, no
# approvals.mode=off, no "allow always"). Everything before this phase is
# already done and verified: the four /data/fast consumers are stopped, the
# tier content is byte-verified in the hold tree, and /data/fast is unmounted.
#
# What it produces:
#   sdb1   96 GiB   btrfs, label nexus-fast — the /data/fast tier. The
#                   filesystem UUID is REUSED so data-fast.mount and every
#                   existing by-uuid reference stay valid.
#   sdb2  ~369 GiB  raw — becomes the bcache cache device in phase 6
#                   (make-bcache -C, attached writearound).
#
# Safety: refuses to run if /data/fast is still mounted, if the verified hold
# copy is missing or empty, or if /dev/sdb is not the expected ~500 GB device.

set -euo pipefail

HOLD=/data/nvme1/_fast-hold-20260923
TIER_UUID=904965c2-f649-4581-a668-843fabd32ac3

[[ $EUID -eq 0 ]] || { echo "run as root:  sudo $0" >&2; exit 1; }
mountpoint -q /data/fast && { echo "REFUSING: /data/fast is still mounted" >&2; exit 1; }
[[ -d $HOLD ]] || { echo "REFUSING: hold copy $HOLD is missing" >&2; exit 1; }
[[ -n "$(find "$HOLD" -type f -print -quit)" ]] || { echo "REFUSING: hold copy is empty" >&2; exit 1; }
size=$(blockdev --getsize64 /dev/sdb)
(( size > 490000000000 && size < 510000000000 )) || { echo "REFUSING: /dev/sdb is $size bytes, expected ~500 GB" >&2; exit 1; }

echo "==> wiping signatures on /dev/sdb"
wipefs -a /dev/sdb

echo "==> fresh GPT"
sgdisk --zap-all /dev/sdb

echo "==> partitions: 96 GiB tier + cache remainder"
sgdisk -n 1:2048:+96G -t 1:8300 -c 1:nexus-fast -n 2:0:0 -t 2:8300 -c 2:bcache-cache /dev/sdb
partprobe /dev/sdb
udevadm settle
sleep 1
lsblk -o NAME,SIZE,TYPE,PARTLABEL /dev/sdb

echo "==> formatting sdb1 as btrfs label=nexus-fast uuid=$TIER_UUID"
mkfs.btrfs -f -L nexus-fast -U "$TIER_UUID" /dev/sdb1

echo "==> result"
blkid /dev/sdb1 || true
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL /dev/sdb

cat <<'DONE'

PHASE 4 DONE.
Tell the agent to continue: it will mount sdb1, restore the tier from the hold
tree and verify it byte-for-byte, then create the bcache cache on sdb2, set
writearound BEFORE attaching, attach, and run the integrity + cache-hit gates.
DONE
