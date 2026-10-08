#!/usr/bin/env bash
# Regression check: every model's songs land in ~/Music/<model>/ and the
# ComfyUI runtime can actually write them there.
#
# INCIDENT (2026-10-08). Two independent failures hit ACE-Step generation, both
# AFTER minutes of work, and neither was visible from the charts:
#
#   1. Triton JIT-compiles CUDA kernels at FIRST GENERATION, not at startup.
#      The Arch base image ships no C compiler, so a 210 s track died with
#      "RuntimeError: Failed to find C compiler. Please specify via CC
#      environment variable or set triton.knobs.build.impl."
#   2. torchaudio 2.11 routes load() through torchcodec, which the ComfyUI venv
#      does not ship. SaveAudio then died with "_AudioDecoder() takes no
#      arguments" on a file that had ALREADY been generated correctly - so the
#      failure looked like a generation failure when it was only a save failure.
#
# A THIRD failure followed while fixing output routing, and it is the one this
# check exists for: ComfyUI resolves the REAL path of a save target and refuses
# anything outside --output-directory ("Saving image outside the output folder
# is not allowed"). A host-side symlink at ~/3d-out/music -> ~/Music resolves
# fine from a shell but is REJECTED, so output routing silently produced nothing.
# The mount therefore has to be genuinely nested at /home/j_kro/3d-out/music.
#
# Also note where the values live: each ArgoCD Application carries inline
# helm.values in helm/apps/<app>.yaml, and Helm REPLACES lists rather than
# merging them. Chart-level extraHostMounts/outputHostPath do NOT apply. The
# first fix attempt edited only the charts and was a no-op.
#
# Usage: bash test-music-output-routing.sh
# Exit:  0 = all checks pass, 1 = at least one failed

set -uo pipefail

NS=mining
MUSIC_ROOT=/home/j_kro/Music
COMFY_LABEL=app=comfyui-zephyr
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

echo "music output routing — $(date -Iseconds)"
echo

# --- 1. the output tree exists -------------------------------------------------
for m in acestep yue2; do
  if [ -d "$MUSIC_ROOT/$m" ]; then pass "~/Music/$m exists"; else fail "~/Music/$m missing"; fi
done
echo

# --- 2. the Application values point at ~/Music --------------------------------
comfy_out=$(kubectl get application comfyui-zephyr -n argocd \
  -o jsonpath='{.spec.source.helm.values}' 2>/dev/null | grep -A3 'name: music' | grep mountPath || true)
if echo "$comfy_out" | grep -q '/home/j_kro/3d-out/music'; then
  pass "comfyui Application mounts Music nested in the output dir"
else
  fail "comfyui Application music mountPath is '${comfy_out:-<absent>}' (must be /home/j_kro/3d-out/music; a non-nested mount is rejected by ComfyUI's realpath check)"
fi

yue2_out=$(kubectl get application yue2-zephyr -n argocd \
  -o jsonpath='{.spec.source.helm.values}' 2>/dev/null | grep -oE 'outputHostPath: .*' || true)
if echo "$yue2_out" | grep -q '/home/j_kro/Music/yue2'; then
  pass "yue2 Application outputHostPath is ~/Music/yue2"
else
  fail "yue2 Application ${yue2_out:-outputHostPath absent} (must be /home/j_kro/Music/yue2)"
fi
echo

# --- 3. the live pod can actually write there ----------------------------------
pod=$(kubectl get pod -n "$NS" -l "$COMFY_LABEL" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$pod" ]; then
  echo "  SKIP  no comfyui pod running (scale-0 is its normal idle state)"
else
  ready=$(kubectl get pod -n "$NS" "$pod" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)
  if [ "$ready" != "true" ]; then
    echo "  SKIP  comfyui pod $pod not ready"
  else
    probe="$MUSIC_ROOT/acestep/.probe-$$"
    if kubectl exec -n "$NS" -c comfyui "$pod" -- sh -c \
         "echo ok > /home/j_kro/3d-out/music/acestep/.probe-$$" >/dev/null 2>&1 \
       && [ -f "$probe" ]; then
      pass "pod write through /home/j_kro/3d-out/music reaches ~/Music/acestep"
      rm -f "$probe"
    else
      fail "pod cannot write to ~/Music/acestep through the nested mount"
    fi

    # the two deps whose absence produced the original incident
    kubectl exec -n "$NS" -c comfyui "$pod" -- sh -c 'command -v gcc >/dev/null' 2>/dev/null \
      && pass "gcc present in the comfyui pod (Triton JIT)" \
      || fail "gcc MISSING in the comfyui pod — ACE-Step generation will die at first generation"
    kubectl exec -n "$NS" -c comfyui "$pod" -- \
      /home/j_kro/StabilityMatrix/Packages/ComfyUI/venv/bin/python -c 'import torchcodec' 2>/dev/null \
      && pass "torchcodec importable in the ComfyUI venv (audio save)" \
      || fail "torchcodec MISSING — SaveAudio will fail after generation succeeds"
  fi
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "RESULT: FAIL ($fails check(s))"
  exit 1
fi
echo "RESULT: PASS"
exit 0
