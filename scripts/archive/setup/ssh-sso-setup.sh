#!/usr/bin/env bash
# SSH SSO Setup Script for j_kro
# Sets up round-trip SSH and SSH Certificate Authority for cluster-wide SSO

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

# Configuration
J_KRO_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvekxGk1YR/eF8llVmNk3C59BtgB+9DNvxLy2WjPEyb j_kro@zephyr"
SSH_DIR="$HOME/.ssh"
CA_KEY_DIR="/etc/ssh"
CLUSTER_HOSTS=(zephyr nexus forge sentry)

# ============================================================================
# STEP 1: Verify current SSH setup
# ============================================================================
log_info "Step 1: Verifying current SSH setup..."

if [[ ! -f "$SSH_DIR/id_ed25519" ]]; then
    log_error "No SSH key found at $SSH_DIR/id_ed25519"
    log_info "Generating new SSH key..."
    ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -C "j_kro@zephyr"
    log_success "SSH key generated"
else
    log_success "SSH key exists at $SSH_DIR/id_ed25519"
fi

# Display public key
log_info "Your public key:"
echo "────────────────────────────────────"
cat "$SSH_DIR/id_ed25519.pub"
echo "────────────────────────────────────"

# ============================================================================
# STEP 2: Generate SSH CA key pair
# ============================================================================
log_info "Step 2: Setting up SSH Certificate Authority..."

if [[ ! -f "$CA_KEY_DIR/ca_key" ]]; then
    log_warning "CA key not found. Generating new SSH CA key pair..."
    sudo mkdir -p "$CA_KEY_DIR"

    # Generate CA key
    ssh-keygen -t ed25519 -f "$CA_KEY_DIR/ca_key" -C "cluster-CA@zephyr" -N ""

    # Set permissions
    sudo chmod 600 "$CA_KEY_DIR/ca_key"
    sudo chmod 644 "$CA_KEY_DIR/ca_key.pub"

    log_success "SSH CA key pair generated"
    log_info "CA Public Key:"
    echo "────────────────────────────────────"
    sudo cat "$CA_KEY_DIR/ca_key.pub"
    echo "────────────────────────────────────"
    log_warning "Update modules/system/ssh-ca.nix caPublicKey with the key above!"
else
    log_success "SSH CA key exists"
    sudo cat "$CA_KEY_DIR/ca_key.pub"
fi

# ============================================================================
# STEP 3: Sign j_kro's SSH key with the CA
# ============================================================================
log_info "Step 3: Signing j_kro's SSH key with CA..."

# Check if certificate already exists
if [[ -f "$SSH_DIR/id_ed25519-cert.pub" ]]; then
    log_info "Existing certificate found. Checking validity..."
    if ssh-keygen -L -f "$SSH_DIR/id_ed25519-cert.pub" 2>/dev/null | grep -q "valid: forever"; then
        log_success "Certificate is valid forever"
    elif ssh-keygen -L -f "$SSH_DIR/id_ed25519-cert.pub" 2>/dev/null | grep -q "valid:"; then
        expiry=$(ssh-keygen -L -f "$SSH_DIR/id_ed25519-cert.pub" 2>/dev/null | grep "Valid:" | awk '{print $4}')
        log_warning "Certificate expires: $expiry"
        read -p "Regenerate certificate? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f "$SSH_DIR/id_ed25519-cert.pub"
        else
            log_info "Keeping existing certificate"
        fi
    fi
fi

# Generate new certificate if needed
if [[ ! -f "$SSH_DIR/id_ed25519-cert.pub" ]]; then
    sudo ssh-keygen -s "$CA_KEY_DIR/ca_key" \
        -I "j_kro@cluster" \
        -n "j_kro" \
        -V "+52w" \
        -z "$(date +%s)" \
        "$SSH_DIR/id_ed25519.pub"

    log_success "SSH certificate generated (valid for 52 weeks)"
fi

# Display certificate info
log_info "Certificate details:"
ssh-keygen -L -f "$SSH_DIR/id_ed25519-cert.pub"

# ============================================================================
# STEP 4: Test SSH to cluster hosts
# ============================================================================
log_info "Step 4: Testing round-trip SSH connectivity..."

for host in "${CLUSTER_HOSTS[@]}"; do
    log_info "Testing SSH to $host..."

    if timeout 5 ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" "echo 'Connected to $host'; hostname" 2>/dev/null; then
        log_success "✓ $host: Round-trip SSH working"
    else
        log_warning "✗ $host: SSH connection failed (may need rebuild/deploy)"
    fi
done

# ============================================================================
# STEP 5: Summary and next steps
# ============================================================================
echo ""
log_success "SSH SSO Setup Complete!"
echo ""
echo "────────────────────────────────────────────────────────────"
echo "SUMMARY:"
echo "────────────────────────────────────────────────────────────"
echo "1. SSH Key:        $SSH_DIR/id_ed25519"
echo "2. SSH Certificate: $SSH_DIR/id_ed25519-cert.pub"
echo "3. CA Public Key:  $CA_KEY_DIR/ca_key.pub"
echo "4. CA Private Key: $CA_KEY_DIR/ca_key (keep secure!)"
echo ""
echo "────────────────────────────────────────────────────────────"
echo "NEXT STEPS:"
echo "────────────────────────────────────────────────────────────"
echo "1. Review and update ssh-ca.nix caPublicKey if needed"
echo "2. Run: just switch     # Apply changes locally (zephyr)"
echo "3. Run: just deploy     # Deploy to all nodes"
echo "4. After deploy, test SSH to each host:"
echo "   ssh zephyr hostname"
echo "   ssh nexus hostname"
echo "   ssh forge hostname"
echo "   ssh sentry hostname"
echo ""
echo "────────────────────────────────────────────────────────────"
echo "SSH CERTIFICATE COMMANDS:"
echo "────────────────────────────────────────────────────────────"
echo "ssh-sign-cert          # Sign your SSH key with CA"
echo "ssh-cert-info           # View certificate details"
echo "ssh-ca-generate         # Generate new CA key pair"
echo "────────────────────────────────────────────────────────────"
