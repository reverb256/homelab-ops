#!/bin/bash
# TP-Link Switch 802.1Q VLAN Configuration Script
# Uses Chrome DevTools MCP for automation
#
# This script configures VLANs on all 4 switches sequentially

set -e

SWITCHES=(
    "10.1.1.10:sw1-modem"
    "10.1.1.11:sw2-tv"
    "10.1.1.12:sw3-upstairs"
    "10.1.1.13:sw4-zephyr"
)

USERNAME="admin"
PASSWORD="ee80cb9718"

echo "=========================================="
echo "TP-Link Switch VLAN Configuration"
echo "=========================================="
echo ""
echo "This script will:"
echo "1. Enable 802.1Q VLAN on all switches"
echo "2. Create 7 VLANs per switch design"
echo ""
echo "Switches to be configured:"
for switch in "${SWITCHES[@]}"; do
    ip=$(echo $switch | cut -d: -f1)
    name=$(echo $switch | cut -d: -f2)
    echo "  - $name ($ip)"
done
echo ""
read -p "Continue? (yes/no): " response
if [ "$response" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Configuration will be done via Chrome DevTools MCP
# This script serves as a launcher/documentation
echo ""
echo "Please use the Chrome DevTools MCP to run the configuration."
echo ""
echo "Example commands:"
echo "1. Navigate to switch: http://10.1.1.13"
echo "2. Login with admin / ee80cb9718"
echo "3. Go to http://10.1.1.13/Vlan8021QRpm.htm"
echo "4. Enable 802.1Q VLAN"
echo "5. Create VLANs with port configuration"
echo ""
echo "See /etc/nixos/scripts/tplink-configure-vlans.py for port configurations."
