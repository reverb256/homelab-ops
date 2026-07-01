#!/usr/bin/env bash
#
# TP-Link Switch Simple Backup Script
# Captures HTML configuration pages using curl (no Playwright required)
#

set -o pipefail

# Switch configurations (CORRECTED IPs 2026-03-10)
declare -A SWITCHES
SWITCHES[sw1-modem]="10.1.1.90"
SWITCHES[sw2-nexus]="10.1.1.95"
SWITCHES[sw3-upstairs]="10.1.1.12"
SWITCHES[sw4-zephyr]="10.1.1.104"

USERNAME="admin"
PASSWORD="ee80cb9718"

# Create backup directory with timestamp
BACKUP_DIR="$HOME/tplink-backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "═══════════════════════════════════════════════════════════"
echo "  TP-Link Switch Configuration Backup"
echo "═══════════════════════════════════════════════════════════"
echo "Backup directory: $BACKUP_DIR"
echo ""

# Pages to capture
PAGES=(
    "home.htm:Dashboard"
    "SystemInfoRpm.htm:System Information"
    "PortSettingRpm.htm:Port Settings"
    "VlanMtuRpm.htm:VLAN Settings"
    "VlanPvid.htm:Port PVID Configuration"
    "QosBasicRpm.htm:QoS Settings"
    "PortStatisticsRpm.htm:Port Statistics"
)

backup_switch() {
    local switch=$1
    local ip=$2

    echo ""
    echo "───────────────────────────────────────────────────────────────"
    echo "Backing up: $switch ($ip)"
    echo "───────────────────────────────────────────────────────────────"

    # Create switch directory
    mkdir -p "$BACKUP_DIR/$switch"

    # Create summary file
    {
        echo "Switch: $switch"
        echo "IP: $ip"
        echo "Backup Time: $(date)"
        echo ""
        echo "Pages Captured:"
    } > "$BACKUP_DIR/$switch/backup_summary.txt"

    # Capture each page
    for page_spec in "${PAGES[@]}"; do
        IFS=':' read -r page_file page_name <<< "$page_spec"
        page_url="http://$ip/$page_file"

        echo -n "  Capturing: $page_name... "

        # Fetch page (with login cookie)
        # Note: TP-Link switches use basic auth or session cookies
        if curl -s -u "$USERNAME:$PASSWORD" --max-time 10 "$page_url" \
            -o "$BACKUP_DIR/$switch/$(basename $page_file .htm).html" 2>/dev/null; then

            # Check if file has content
            if [ -s "$BACKUP_DIR/$switch/$(basename $page_file .htm).html" ]; then
                echo "✓"
                echo "  ✓ $page_name" >> "$BACKUP_DIR/$switch/backup_summary.txt"

                # Extract key info from the page
                case "$page_file" in
                    "VlanMtuRpm.htm")
                        if grep -q "Enable 802.1Q VLAN" "$BACKUP_DIR/$switch/$(basename $page_file .htm).html" 2>/dev/null; then
                            echo "    VLAN enabled: $(grep -o 'Enable 802.1Q VLAN' "$BACKUP_DIR/$switch/$(basename $page_file .htm).html" | wc -l) instances"
                        fi
                        ;;
                    "SystemInfoRpm.htm")
                        echo "    System info captured" >> "$BACKUP_DIR/$switch/backup_summary.txt"
                        ;;
                esac
            else
                echo "✗ (empty)"
                echo "  ✗ $page_name (empty response)" >> "$BACKUP_DIR/$switch/backup_summary.txt"
            fi
        else
            echo "✗ (failed)"
            echo "  ✗ $page_name (fetch failed)" >> "$BACKUP_DIR/$switch/backup_summary.txt"
        fi
    done

    # Get switch model info if available
    echo "" >> "$BACKUP_DIR/$switch/backup_summary.txt"
    echo "Quick Verification:" >> "$BACKUP_DIR/$switch/backup_summary.txt"
    if ping -c 1 -W 2 "$ip" &>/dev/null; then
        echo "  ✓ Ping: OK" >> "$BACKUP_DIR/$switch/backup_summary.txt"
    else
        echo "  ✗ Ping: FAILED" >> "$BACKUP_DIR/$switch/backup_summary.txt"
    fi

    if timeout 2 bash -c "echo > /dev/tcp/$ip/80" 2>/dev/null; then
        echo "  ✓ Port 80: Open" >> "$BACKUP_DIR/$switch/backup_summary.txt"
    else
        echo "  ✗ Port 80: Closed" >> "$BACKUP_DIR/$switch/backup_summary.txt"
    fi
}

# Backup all switches
for switch in sw1-modem sw2-nexus sw3-upstairs sw4-zephyr; do
    ip="${SWITCHES[$switch]}"
    backup_switch "$switch" "$ip"
done

# Create master index
{
    echo "TP-Link Switch Backup Index"
    echo "============================"
    echo "Backup Time: $(date)"
    echo "Directory: $BACKUP_DIR"
    echo ""
    echo "Switches Backed Up:"
    for switch in sw1-modem sw2-nexus sw3-upstairs sw4-zephyr; do
        ip="${SWITCHES[$switch]}"
        echo "  - $switch ($ip)"
    done
    echo ""
    echo "Contents:"
    ls -la "$BACKUP_DIR"
} > "$BACKUP_DIR/BACKUP_INDEX.txt"

# Create rollback instructions
cat > "$BACKUP_DIR/ROLLBACK.txt" <<'EOF'
# TP-Link Switch Rollback Instructions
# Generated: $(date)

## If anything breaks after VLAN configuration:

### Immediate Rollback (via Web UI):
1. Login to each switch: http://<switch-ip> (admin / ee80cb9718)
2. Navigate to: VLAN → 802.1Q VLAN
3. Uncheck "Enable 802.1Q VLAN"
4. Click Apply/Save
5. Reboot switch if needed

### Per-Switch Access:
- sw1-modem:   http://10.1.1.90
- sw2-nexus:   http://10.1.1.95
- sw3-upstairs: http://10.1.1.12
- sw4-zephyr:  http://10.1.1.104

### Factory Reset (if Web UI inaccessible):
1. Hold reset button for 10 seconds
2. Wait for reboot
3. Reconfigure from scratch

### Connectivity Test After Rollback:
```bash
# From Zephyr, test connectivity to all nodes
for ip in 10.1.1.120 10.1.1.130 10.1.1.140; do
    echo "Testing $ip..."
    ping -c 2 $ip
done
```

### Verify Cluster Operations:
```bash
# Check Kubernetes cluster
ssh zephyr 'kubectl get nodes'

# Check NFS mounts
ssh zephyr 'df -h | grep nfs'

# Check Tailscale
ssh zephyr 'tailscale status'
```
EOF

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Backup Complete!"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "📂 Backup location: $BACKUP_DIR"
echo "📋 Index: $BACKUP_DIR/BACKUP_INDEX.txt"
echo "🔄 Rollback: $BACKUP_DIR/ROLLBACK.txt"
echo ""
echo "Next steps:"
echo "  1. Review captured HTML files"
echo "  2. Document current VLAN status"
echo "  3. Run: python3 scripts/tplink-configure-vlans.py --verify"
echo ""

# Show backup summary
echo "Backup Summary:"
ls -lh "$BACKUP_DIR" | tail -5

exit 0
