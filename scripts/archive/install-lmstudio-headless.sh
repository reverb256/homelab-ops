#!/usr/bin/env bash
# Install LM Studio headless CLI (lms) on NixOS
# Based on: https://lmstudio.ai/docs/developer/core/headless_llmster
#
# Usage: sudo ./scripts/install-lmstudio-headless.sh [username]
#
# This script installs the lms CLI to the user's home directory.
# Run this ONCE per user before enabling the lm-studio-headless service.

set -euo pipefail

# Default user
USERNAME="${1:-j_kro}"
USER_HOME="/home/${USERNAME}"
LMS_INSTALL_DIR="${USER_HOME}/.lmstudio/bin"

echo "=========================================="
echo "LM Studio Headless CLI Installer"
echo "=========================================="
echo ""
echo "Target user: ${USERNAME}"
echo "Install dir: ${LMS_INSTALL_DIR}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (sudo)"
   echo "Usage: sudo $0 [username]"
   exit 1
fi

# Check if user exists
if ! id "$USERNAME" &>/dev/null; then
    echo "Error: User '${USERNAME}' does not exist"
    exit 1
fi

# Create install directory
echo "Creating install directory..."
mkdir -p "${LMS_INSTALL_DIR}"
chown "${USERNAME}:users" "${LMS_INSTALL_DIR}"

# Download and install lms CLI using the official installer
echo "Downloading lms CLI..."
cd "${USER_HOME}"

# Run the official installer as the target user
su - "${USERNAME}" -c 'curl -fsSL https://lmstudio.ai/install.sh | bash'

# Verify installation
echo ""
echo "Verifying installation..."
if su - "${USERNAME}" -c 'command -v lms'; then
    LMS_VERSION=$(su - "${USERNAME}" -c 'lms --version 2>/dev/null || echo "unknown"')
    echo "✓ lms CLI installed successfully"
    echo "  Version: ${LMS_VERSION}"
else
    echo "✗ lms CLI not found in PATH"
    echo "  The installer may have placed it in: ${LMS_INSTALL_DIR}"
fi

# Show lms location
echo ""
echo "lms CLI location:"
su - "${USERNAME}" -c 'which lms || echo "~/.lmstudio/bin/lms"'

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Download a model (optional):"
echo "     su - ${USERNAME} -c 'lms get qwen/qwen3.5-9b-instruct'"
echo ""
echo "  2. Enable the service in configuration.nix:"
echo "     services.lm-studio-headless = {"
echo "       enable = true;"
echo "       user = \"${USERNAME}\";"
echo "       preloadModel = \"qwen/qwen3.5-9b-instruct\";  # Optional"
echo "     };"
echo ""
echo "  3. Rebuild NixOS:"
echo "     sudo nixos-rebuild switch"
echo ""
echo "  4. Start the service:"
echo "     sudo systemctl start lm-studio-headless"
echo ""
echo "  5. Verify it's working:"
echo "     curl http://localhost:1234/v1/models"
echo ""
