# Gates: bcache cache re-attach (nexus, 2026-09-23)

OWNS: runbooks/bcache-cache-reattach-20260923/**, omarchy/nexus/README.md, omarchy/nexus/apply.sh, omarchy/nexus/systemd/bcache-cache-mode.service

Scope: re-attach the 500 GB SSD (/dev/sdb) to /dev/bcache0 as a writearound read cache while keeping the /data/fast tier intact on a 96 GiB partition, then record the change in homelab-ops.

- [x] G0: this ledger states outcomes that can fail
  CHECK: node /home/j_kro/.hermes/skills/productivity/unlazy/scripts/gate-lint.mjs GATES.md
  EXPECT: LINT OK
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/home/j_kro/homelab-ops/runbooks/bcache-cache-reattach-20260923; path=c9b672f407fb/25 entries; EXPECT=matched; output-sha256=48630b7361dd44ee870917b12c3d19b9d7bdea738aaca16bb04d4cab83b772d2; output-bytes=8

- [ ] G1: every media workload that mounts /data/fast is stopped, no process holds the tier, and ArgoCD self-heal is suspended
  CHECK: node scripts/verify.mjs paused
  EXPECT: PHASE VERIFIED: paused
  EVIDENCE: pending

- [ ] G2: the tier content exists in the hold tree and every file matches byte-for-byte, with no writer left running while it was copied
  CHECK: node scripts/verify.mjs copy
  EXPECT: PHASE VERIFIED: copy
  EVIDENCE: pending

- [ ] G3: /data/fast is unmounted, /dev/sdb has no holders, and the bcache0 pool is still live
  CHECK: node scripts/verify.mjs unmounted
  EXPECT: PHASE VERIFIED: unmounted
  EVIDENCE: pending

- [ ] G4: /dev/sdb carries a 96 GiB tier partition and a cache partition of at least 350 GiB, tier formatted btrfs label nexus-fast
  CHECK: node scripts/verify.mjs partitions
  EXPECT: PHASE VERIFIED: partitions
  EVIDENCE: pending

- [ ] G5: the tier is restored on sdb1 and mounted at /data/fast under the UUID declared by data-fast.mount, matching the hold copy
  CHECK: node scripts/verify.mjs tier-restored
  EXPECT: PHASE VERIFIED: tier-restored
  EVIDENCE: pending

- [ ] G6: a bcache cache device exists on sdb2, is registered with the kernel, and writearound is selected before the attach
  CHECK: node scripts/verify.mjs cache-mode
  EXPECT: PHASE VERIFIED: cache-mode
  EVIDENCE: pending

- [ ] G7: the cache is attached and clean, holds no dirty data, and writearound plus the cache-set UUID are persisted in the backing superblock
  CHECK: node scripts/verify.mjs cache-attached
  EXPECT: PHASE VERIFIED: cache-attached
  EVIDENCE: pending

- [ ] G8: the pool reports no new I/O, flush, generation or checksum errors and a 64 MiB write/read round-trip succeeds through bcache0
  CHECK: node scripts/verify.mjs pool-integrity
  EXPECT: PHASE VERIFIED: pool-integrity
  EVIDENCE: pending

- [ ] G9: the cache actually serves pool reads (repeated direct 64 KiB reads produce cache hits)
  CHECK: node scripts/verify.mjs cache-in-use
  EXPECT: PHASE VERIFIED: cache-in-use
  EVIDENCE: pending

- [ ] G10: the four media workloads are back with their state files re-opened and ArgoCD self-heal restored with those apps Synced and Healthy
  CHECK: node scripts/verify.mjs media-restored
  EXPECT: PHASE VERIFIED: media-restored
  EVIDENCE: pending

- [ ] G11: all four app UIs answer through the cluster service proxy after the window
  CHECK: node scripts/verify.mjs stack-http
  EXPECT: PHASE VERIFIED: stack-http
  EVIDENCE: pending

- [ ] G12: homelab-ops records the new layout (README section, apply.sh CACHE_UUID, boot-time mode unit) and the tree is committed clean
  CHECK: node scripts/verify.mjs repo-state
  EXPECT: PHASE VERIFIED: repo-state
  EVIDENCE: pending

- [ ] G13: the runbook records the phase evidence and the residual risk that the cache masks dead extents until the pool is repaired
  CHECK: node scripts/verify.mjs runbook
  EXPECT: PHASE VERIFIED: runbook
  EVIDENCE: pending
