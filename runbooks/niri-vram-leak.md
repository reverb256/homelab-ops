# Niri VRAM Leak — Diagnosis & Fix

**Symptom:** niri RSS balloons to 11+ GB over hours/days. `earlyoom` starts killing processes. System becomes unstable.

**Trigger:** Every surface/window created leaks its NVIDIA GEM device mapping. Accelerated by gamescope/PoE2 crash-loops (each crash creates + leaks surfaces).

## Root Cause

NVIDIA driver bug: the explicit-sync present path (`libEGL_nvidia`) never releases per-present allocations. Compositor-side dead-surface hooks compound it. Mappings accumulate in `/proc/<niri-pid>/maps`:

```
/dev/nvidiactl   ~2000 maps, ~11 GB   (control device)
/dev/nvidia0      ~800 maps, ~1.9 GB  (GPU memory)
```

## Diagnosis

```bash
# Mapping count (healthy: <100, leaky: >1000)
sudo grep -c "/dev/nvidia" /proc/$(pgrep -x niri)/maps

# Detailed breakdown
sudo awk '$6 ~ /nvidia/ {split($1,a,"-"); s=strtonum("0x"a[2])-strtonum("0x"a[1]); cnt[$6]++; tot[$6]+=s} END {for (f in cnt) print cnt[f], "maps", tot[f]/1024/1024 "MB", f}' /proc/$(pgrep -x niri)/maps
```

## Immediate Fix (no reboot)

```bash
niri msg action quit   # sddm autologin relaunches; frees all leaked mappings
```

## Long-term Mitigations

1. **NVIDIA application profile** (deployed): `GLVidHeapReuseRatio=0` — caps heap reuse. Already in `modules/hardware/nvidia-niri-profile.nix`.

2. **Disable explicit sync** (deployed Aug 16 2026): `__NV_DISABLE_EXPLICIT_SYNC=1` in `modules/desktop/wayland-compositor-common.nix`. Falls back to implicit sync (no visible difference at 60 Hz).

3. **niri-hdr fork rebase**: ensure the fork includes upstream fix `6d5c5f12` "Fix dead surface hook VRAM leak (#3404)". Current fork `980aa465` already has it.

## Verification

After restart, mapping count should be <100 and stable over time:

```bash
niri-leak   # alias: sudo grep -c /dev/nvidia /proc/(pgrep -x niri)/maps
```
