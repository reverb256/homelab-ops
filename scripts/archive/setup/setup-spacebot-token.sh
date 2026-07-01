#!/usr/bin/env bash
# Setup Spacebot Discord Bot Token
# This script helps you create an encrypted agenix secret for your Discord bot token

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Spacebot Discord Token Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if age key exists
AGE_KEY_FILE="/home/j_kro/.age/key.txt"
if [[ ! -f "$AGE_KEY_FILE" ]]; then
    echo -e "${RED}Error: Age key not found at $AGE_KEY_FILE${NC}"
    echo -e "${YELLOW}Please ensure agenix is properly configured.${NC}"
    exit 1
fi

# Extract public key
PUBLIC_KEY=$(grep -oP 'public key: \K.*' "$AGE_KEY_FILE" 2>/dev/null || true)
if [[ -z "$PUBLIC_KEY" ]]; then
    echo -e "${RED}Error: Could not extract public key from $AGE_KEY_FILE${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found age public key${NC}"
echo ""

# Instructions for getting Discord bot token
echo -e "${YELLOW}Step 1: Get your Discord Bot Token${NC}"
echo "1. Go to https://discord.com/developers/applications"
echo "2. Create a new application (or select existing one)"
echo "3. Go to 'Bot' section in the left sidebar"
echo "4. Click 'Add Bot' if needed"
echo "5. Under 'Privileged Gateway Intents', enable:"
echo "   - Message Content Intent"
echo "   - Server Members Intent"
echo "6. Click 'Reset Token' to reveal your bot token"
echo "7. Copy the token (it looks like: MTI...long string...)"
echo ""

# Prompt for token
echo -e "${YELLOW}Step 2: Enter your Discord Bot Token${NC}"
echo -e "${RED}⚠️  Keep your token secret! Never share it or commit it to git.${NC}"
echo ""
read -p "Paste your Discord bot token here: " DISCORD_TOKEN

# Validate token
if [[ -z "$DISCORD_TOKEN" ]]; then
    echo -e "${RED}Error: Token cannot be empty${NC}"
    exit 1
fi

if [[ ${#DISCORD_TOKEN} -lt 50 ]]; then
    echo -e "${RED}Warning: Token seems too short. Discord tokens are usually 59+ characters.${NC}"
    read -p "Continue anyway? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Create encrypted secret
SECRET_FILE="/etc/nixos/secrets/spacebot-discord-token.age"
echo ""
echo -e "${YELLOW}Step 3: Creating encrypted secret${NC}"

if echo "$DISCORD_TOKEN" | age -r "$PUBLIC_KEY" > "$SECRET_FILE"; then
    echo -e "${GREEN}✓ Encrypted secret created at $SECRET_FILE${NC}"
else
    echo -e "${RED}Error: Failed to create encrypted secret${NC}"
    exit 1
fi

# Verify file was created
if [[ ! -f "$SECRET_FILE" ]]; then
    echo -e "${RED}Error: Secret file was not created${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Setup complete!${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Rebuild NixOS: sudo nixos-rebuild switch"
echo "2. Start Spacebot: sudo systemctl start spacebot"
echo "3. Check status: sudo systemctl status spacebot"
echo "4. View logs: sudo journalctl -u spacebot -f"
echo ""
echo -e "${BLUE}Optional: Invite your bot to a Discord server${NC}"
echo "1. Go to https://discord.com/developers/applications"
echo "2. Select your application"
echo "3. Go to 'OAuth2' > 'URL Generator'"
echo "4. Select scopes: bot, applications.commands"
echo "5. Select bot permissions:"
echo "   - Send Messages"
echo "   - Read Messages/View Channels"
echo "   - Read Message History"
echo "   - Add Reactions"
echo "   - Use Slash Commands"
echo "   - Embed Links"
echo "   - Attach Files"
echo "6. Copy the generated URL and open it in your browser"
echo "7. Select a server to invite the bot to"
echo ""
echo -e "${GREEN}Done! Your bot token is securely encrypted and stored.${NC}"
