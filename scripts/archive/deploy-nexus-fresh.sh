#!/usr/bin/env bash
# deploy-nexus-fresh.sh — Remote reprovision Nexus from Zephyr
# Wipes nvme0n1, installs fresh NixOS from flake, reboots.
# Data drives (bcache0, nvme1n1) are untouched.
#
# Prerequisites:
#   - Nexus booted into USB rescue with SSH (j_kro@10.1.1.120)
#   - j_kro has passwordless sudo on USB rescue
#   - Zephyr, Sentry, Forge are healthy (for K3s quorum)
#   - This script runs ON ZEPHYR from /etc/nixos/

set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

TARGET="j_kro@10.1.1.120"
TARGET_ROOT="root@10.1.1.120"
FLAKE=".#nexus"
AGE_KEY_PATH="/etc/nixos/.age/key.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[deploy]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

cleanup() {
  # Remove temporary root key from target
  if [[ -n "${ROOT_KEY_SETUP:-}" ]]; then
    log "Cleaning up temporary root SSH key..."
    ssh "$TARGET" "sudo sed -i '/# TEMP nixos-anywhere/d' /root/.ssh/authorized_keys 2>/dev/null" || true
  fi
}
trap cleanup EXIT

# ── Phase 0: Pre-flight ──────────────────────────────────────────────
log "Phase 0: Pre-flight checks"

# Check we're on Zephyr
[[ "$(hostname)" == "zephyr" ]] || die "Must run on Zephyr"

# Check target SSH (as j_kro)
ssh -o ConnectTimeout=5 "$TARGET" "echo ok" > /dev/null 2>&1 || die "Cannot SSH to $TARGET"

# Check target has passwordless sudo
ssh "$TARGET" "sudo -n whoami" 2>/dev/null | grep -q root || die "Target needs passwordless sudo"

# Check cluster health
log "Checking K3s cluster health..."
HEALTHY=$(kubectl get nodes --no-headers 2>&1 | grep -c " Ready" || true)
[[ "$HEALTHY" -ge 2 ]] || die "Need at least 2 healthy K3s nodes. Found: $HEALTHY"

# Check K3s VIP reachable
ping -c 1 -W 2 10.1.1.100 > /dev/null 2>&1 || warn "K3s VIP 10.1.1.100 not reachable - nexus may fail to join"

# Check age key exists
[[ -f "$AGE_KEY_PATH" ]] || die "Age key not found at $AGE_KEY_PATH"

# Check target disk layout matches expectations
ssh "$TARGET" "lsblk /dev/nvme0n1 -n -o NAME" 2>/dev/null | grep -q "nvme0n1" || die "nvme0n1 not found on target"

log "All pre-flight checks passed"

# ── Phase 1: K3s cleanup ─────────────────────────────────────────────
log "Phase 1: Removing nexus from K3s cluster"

kubectl cordon nexus --ignore-not-found 2>/dev/null || true
kubectl delete node nexus --ignore-not-found 2>/dev/null || true

# Remove etcd member (if still registered)
ETCD_MEMBER=$(sudo -S -p '' k3s etcdctl member list 2>/dev/null | grep nexus || true)
if [[ -n "$ETCD_MEMBER" ]]; then
  MEMBER_ID=$(echo "$ETCD_MEMBER" | awk -F: '{print $1}' | tr -d ' ')
  log "Removing etcd member $MEMBER_ID"
  sudo -S -p '' k3s etcdctl member remove "$MEMBER_ID" 2>/dev/null || warn "Failed to remove etcd member (may already be gone)"
fi

log "Nexus removed from cluster. Remaining members:"
kubectl get nodes --no-headers 2>/dev/null || true

# ── Phase 1.5: Enable root SSH on target ─────────────────────────────
log "Setting up temporary root SSH access on target..."

# Copy j_kro's public key to root's authorized_keys on nexus
PUB_KEY=$(cat /home/j_kro/.ssh/id_ed25519.pub 2>/dev/null || cat /home/j_kro/.ssh/id_rsa.pub 2>/dev/null || die "No SSH public key found for j_kro")
ssh -i /home/j_kro/.ssh/id_ed25519 "$TARGET" "sudo mkdir -p /root/.ssh && echo '$PUB_KEY # TEMP nixos-anywhere' | sudo tee -a /root/.ssh/authorized_keys > /dev/null && sudo chmod 600 /root/.ssh/authorized_keys"

# Verify root SSH works
ssh -o ConnectTimeout=5 "$TARGET_ROOT" "echo ROOT_OK" > /dev/null 2>&1 || die "Root SSH setup failed"
ROOT_KEY_SETUP=1
log "Root SSH: OK"

# ── Phase 2: Install NixOS via nixos-anywhere ─────────────────────────
log "Phase 2: Installing NixOS on nexus via nixos-anywhere"
log "This will WIPE /dev/nvme0n1 on nexus. All data on nvme0n1 will be lost."
log "Data drives (bcache0, nvme1n1) are NOT touched."
echo ""
warn "Press Ctrl+C to abort. Continuing in 10 seconds..."
sleep 10

nix run github:numtide/nixos-anywhere -- \
  --flake "$FLAKE" \
  --no-reboot \
  "$TARGET_ROOT"

INSTALL_EXIT=$?
if [[ $INSTALL_EXIT -ne 0 ]]; then
  die "nixos-anywhere failed with exit code $INSTALL_EXIT"
fi

log "NixOS installed successfully (not yet rebooted)"

# ── Phase 3: Seed age key ────────────────────────────────────────────
log "Phase 3: Seeding age key for agenix"

# The system is mounted at /mnt on the target after nixos-anywhere --no-reboot
# Copy the age key to /mnt/etc/age/ (third identityPath in agenix config)
ssh "$TARGET_ROOT" "mkdir -p /mnt/etc/age"
cat "$AGE_KEY_PATH" | ssh "$TARGET_ROOT" "cat > /mnt/etc/age/key.txt && chmod 600 /mnt/etc/age/key.txt"

log "Age key seeded to /mnt/etc/age/key.txt"

# ── Phase 4: Reboot ──────────────────────────────────────────────────
log "Phase 4: Rebooting nexus into new system"
ssh "$TARGET_ROOT" "reboot" || true

log "Waiting for nexus to come back online..."
for i in $(seq 1 30); do
  if ssh -o ConnectTimeout=5 "$TARGET" "echo ok" > /dev/null 2>&1; then
    log "Nexus is back online!"
    break
  fi
  echo "  waiting... ($i/30)"
  sleep 10
done

# ── Phase 5: Verify ──────────────────────────────────────────────────
log "Phase 5: Verification"

# Check SSH
ssh -o ConnectTimeout=5 "$TARGET" "hostname" 2>/dev/null && log "SSH: OK" || warn "SSH: not yet available"

# Check K3s rejoin (may take a minute)
log "Waiting for nexus to rejoin K3s cluster..."
for i in $(seq 1 12); do
  NODE_STATUS=$(kubectl get node nexus --no-headers 2>/dev/null | awk '{print $2}' || true)
  if [[ "$NODE_STATUS" == *"Ready"* ]]; then
    log "K3s: nexus is Ready!"
    break
  fi
  echo "  nexus status: ${NODE_STATUS:-not yet registered} ($i/12)"
  sleep 10
done

# Check data mounts
log "Checking data mounts..."
ssh "$TARGET" "mountpoint -q /data/home && echo '/data/home: OK' || echo '/data/home: MISSING'" 2>/dev/null || true
ssh "$TARGET" "mountpoint -q /data/worn && echo '/data/worn: OK' || echo '/data/worn: MISSING'" 2>/dev/null || true

log "========================================="
log "Deployment complete!"
log "If K3s hasn't rejoined yet, check: ssh nexus 'sudo journalctl -u k3s -f'"
log "If data mounts are missing, check: ssh nexus 'sudo systemctl restart local-fs.target'"
log "========================================="
