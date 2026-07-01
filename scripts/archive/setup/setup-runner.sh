#!/usr/bin/env bash
set -euo pipefail

RUNNER_USER="actions-runner"
RUNNER_HOME="/var/lib/actions-runner"
REPO="${1:-$(cd /etc/nixos && git config --get remote.origin.url 2>/dev/null | sed 's/.*github.com[:/]\(.*\)\.git/\1/' || echo "")}"

if [[ -z "$REPO" ]]; then
  echo "Error: Could not determine repository."
  echo "Usage: $0 [owner/repo]"
  exit 1
fi

echo "=== Setting up GitHub Actions Self-Hosted Runner ==="
echo "Repository: $REPO"
echo "Runner user: $RUNNER_USER"
echo "Runner home: $RUNNER_HOME"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

# Create runner user
if ! id "$RUNNER_USER" &>/dev/null; then
  echo "Creating user: $RUNNER_USER"
  useradd -m -s /bin/bash "$RUNNER_USER"
  usermod -aG nixos "$RUNNER_USER"
else
  echo "User $RUNNER_USER already exists"
fi

# Create runner directory
mkdir -p "$RUNNER_HOME"
chown "$RUNNER_USER:nixos" "$RUNNER_HOME"

# Download and install runner
cd "$RUNNER_HOME"
sudo -u "$RUNNER_USER" mkdir -p actions-runner

echo "Fetching latest runner version..."
LATEST_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name)
ARCH="x64"

echo "Downloading runner: $LATEST_VERSION"
sudo -u "$RUNNER_USER" curl -o actions-runner.tar.gz -L \
  "https://github.com/actions/runner/releases/download/${LATEST_VERSION}/actions-runner-linux-${ARCH}-${LATEST_VERSION#v}.tar.gz"

echo "Extracting runner..."
sudo -u "$RUNNER_USER" tar xzf ./actions-runner.tar.gz -C actions-runner --strip-components=1
rm actions-runner.tar.gz

# Configure runner
echo ""
echo "Enter GitHub registration token (from https://github.com/$REPO/settings/actions):"
read -rs TOKEN

cd actions-runner
echo "Configuring runner..."
sudo -u "$RUNNER_USER" ./config.sh \
  --url "https://github.com/$REPO" \
  --token "$TOKEN" \
  --labels nixos,self-hosted \
  --work "/tmp/actions-runner/_work"

# Install systemd service
echo "Installing systemd service..."
./svc.sh install "$RUNNER_USER"
./svc.sh start

echo ""
echo "✓ Runner installed and started"
echo "  Check status: sudo ./svc.sh status (from $RUNNER_HOME/actions-runner)"
echo "  Stop: sudo ./svc.sh stop"
echo "  Start: sudo ./svc.sh start"
echo "  Uninstall: sudo ./svc.sh uninstall"
