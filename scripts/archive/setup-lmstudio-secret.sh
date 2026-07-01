#!/usr/bin/env bash
# Setup LM Studio API Key as Agenix Secret
#
# Usage: sudo ./setup-lmstudio-secret.sh
#
# This script:
# 1. Prompts for LM Studio API key
# 2. Encrypts it with agenix
# 3. Adds to NixOS configuration
# 4. Triggers rebuild

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== LM Studio API Key Setup ===${NC}"
echo ""
echo "This will:"
echo "  1. Prompt for your LM Studio API key"
echo "  2. Encrypt it with agenix (for j_kro + zephyr)"
echo "  3. Add to secrets.nix and agenix-secrets-registry.nix"
echo "  4. Trigger nixos-rebuild switch"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    echo "Usage: sudo $0"
    exit 1
fi

# Check if we're in /etc/nixos
cd /etc/nixos || {
    echo -e "${RED}Error: Cannot cd to /etc/nixos${NC}"
    exit 1
}

# Check if agenix secret file already exists
if [ -f "secrets/lm-studio-api-key.age" ]; then
    echo -e "${YELLOW}Warning: secrets/lm-studio-api-key.age already exists${NC}"
    read -p "Overwrite? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    rm -f "secrets/lm-studio-api-key.age"
fi

# Prompt for API key
echo ""
echo "Enter your LM Studio API key (or press Enter to skip and create placeholder):"
read -s -r API_KEY
echo ""

if [ -z "$API_KEY" ]; then
    echo -e "${YELLOW}No API key provided. Creating placeholder...${NC}"
    API_KEY="lm-studio-placeholder-key-$(date +%s)"
    echo "Placeholder: $API_KEY"
fi

# Create temporary file with the key
TEMP_FILE=$(mktemp)
echo -n "$API_KEY" > "$TEMP_FILE"

# Encrypt with agenix
echo ""
echo "Encrypting with agenix..."
if nix run github:ryantm/agenix/0.15.0 -- -e secrets/lm-studio-api-key.age -i "$TEMP_FILE" 2>&1; then
    echo -e "${GREEN}✓ Secret encrypted successfully${NC}"
    rm -f "$TEMP_FILE"
else
    echo -e "${RED}✗ Encryption failed${NC}"
    rm -f "$TEMP_FILE"
    exit 1
fi

# Verify the encrypted file was created
if [ ! -f "secrets/lm-studio-api-key.age" ]; then
    echo -e "${RED}✗ Encrypted file not created${NC}"
    exit 1
fi

# Set proper permissions
chmod 644 "secrets/lm-studio-api-key.age"
chown j_kro:users "secrets/lm-studio-api-key.age"

echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo ""
echo "Next steps:"
echo "  1. Review the changes:"
echo "     - secrets.nix (already updated)"
echo "     - modules/system/agenix-secrets-registry.nix (already updated)"
echo "     - secrets/lm-studio-api-key.age (newly created)"
echo ""
echo "  2. Test the configuration:"
echo "     nix flake check"
echo ""
echo "  3. Apply the changes:"
echo "     just switch"
echo ""
echo "  4. Verify the secret is accessible:"
echo "     test -r /run/agenix/lm-studio-api-key && echo '✓ Readable' || echo '✗ Not readable'"
echo ""
echo "  5. Reload fish shell:"
echo "     exec fish"
echo ""
