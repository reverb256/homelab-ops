#!/usr/bin/env python3
"""
TP-Link Switch Current Settings & Rollback Script
Captures current VLAN and PVID configuration for all switches.

USAGE:
    # Show current settings (quick view)
    python3 tplink-current-settings.py

    # Backup to file (before making changes)
    python3 tplink-current-settings.py --backup

    # Show specific switch
    python3 tplink-current-settings.py --switch sw1-modem

OUTPUT:
    --backup: Creates /var/cache/tplink-switches/current-settings-YYYYMMDD-HHMMSS.json
    This file contains complete VLAN/PVID state for rollback.

ROLLBACK:
    If anything breaks, use the backup JSON to restore settings manually
    or disable 802.1Q VLAN to revert to default behavior.
"""

import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path
from playwright.async_api import async_playwright

# Switch configurations (SEQUENTIAL IPs - 2026-03-10)
SWITCHES = {
    "sw1-modem": {"ip": "10.1.1.10", "name": "sw1-modem-root"},
    "sw2-tv": {"ip": "10.1.1.11", "name": "sw2-tv-branch"},
    "sw3-upstairs": {"ip": "10.1.1.12", "name": "sw3-upstairs"},
    "sw4-zephyr": {"ip": "10.1.1.13", "name": "sw4-zephyr-end"},
}

USERNAME = "admin"
PASSWORD = "ee80cb9718"

BACKUP_DIR = Path("/var/cache/tplink-switches")
BACKUP_DIR.mkdir(parents=True, exist_ok=True)


class SwitchSettings:
    """Capture current VLAN and PVID settings from a switch"""

    def __init__(self, switch_key: str, config: dict):
        self.switch_key = switch_key
        self.ip = config["ip"]
        self.name = config["name"]
        self.base_url = f"http://{self.ip}"
        self.settings = {}

    async def login(self, page):
        """Login to switch"""
        try:
            await page.goto(self.base_url, timeout=15000)

            # Check if already logged in
            if await page.query_selector('text=Logout'):
                return True

            await page.fill('input[name="username"]', USERNAME)
            await page.fill('input[name="password"]', PASSWORD)
            await page.click('input[name="logon"]')
            await asyncio.sleep(2)

            return await page.query_selector('text=Logout') is not None
        except Exception as e:
            print(f"  ✗ Login error: {e}")
            return False

    async def capture_vlan_settings(self, page):
        """Capture 802.1Q VLAN configuration"""
        try:
            await page.goto(f"{self.base_url}/Vlan8021QRpm.htm", timeout=15000)
            await asyncio.sleep(1)

            vlan_data = await page.evaluate('''() => {
                if (window.qvlan_ds) {
                    // Decode port membership bitmasks to readable format
                    const decodeMbrs = (mbr) => {
                        const ports = [];
                        for (let p = 1; p <= 5; p++) {
                            const bit = 1 << (p - 1);
                            if (mbr & bit) ports.push(p);
                        }
                        return ports;
                    };

                    return {
                        enabled: window.qvlan_ds.state === 1,
                        count: window.qvlan_ds.count,
                        vlans: window.qvlan_ds.vids.map((vid, i) => ({
                            id: vid,
                            name: window.qvlan_ds.names[i] || '',
                            memberPorts: decodeMbrs(window.qvlan_ds.mbrs[i])
                        }))
                    };
                }
                return {error: 'qvlan_ds not found', enabled: false};
            }''')

            self.settings['vlan'] = vlan_data
            return True
        except Exception as e:
            self.settings['vlan_error'] = str(e)
            return False

    async def capture_pvid_settings(self, page):
        """Capture PVID configuration"""
        try:
            await page.goto(f"{self.base_url}/Vlan8021QPvidRpm.htm", timeout=15000)
            await asyncio.sleep(1)

            pvid_data = await page.evaluate('''() => {
                if (window.pvid_ds) {
                    return {
                        portCount: window.pvid_ds.portNum,
                        pvids: window.pvid_ds.pvids,  // PVID for ports 1-5
                        vlanCount: window.pvid_ds.count,
                        vlanIds: window.pvid_ds.vids
                    };
                }
                return {error: 'pvid_ds not found'};
            }''')

            self.settings['pvid'] = pvid_data
            return True
        except Exception as e:
            self.settings['pvid_error'] = str(e)
            return False

    async def capture_system_info(self, page):
        """Capture basic system info"""
        try:
            await page.goto(f"{self.base_url}/SystemInfoRpm.htm", timeout=15000)
            await asyncio.sleep(1)

            sys_info = await page.evaluate('''() => {
                const getCellText = (row, cellIndex) => {
                    const cells = row.querySelectorAll('td');
                    return cells[cellIndex]?.textContent?.trim() || '';
                };

                const rows = document.querySelectorAll('tr');
                const info = {};

                for (const row of rows) {
                    const label = getCellText(row, 0);
                    const value = getCellText(row, 1);

                    if (label.includes('Device Description')) info.description = value;
                    if (label.includes('MAC Address')) info.mac = value;
                    if (label.includes('IP Address')) info.ip = value;
                    if (label.includes('Firmware Version')) info.firmware = value;
                    if (label.includes('Hardware Version')) info.hardware = value;
                }

                return info;
            }''')

            self.settings['system'] = sys_info
            return True
        except Exception as e:
            self.settings['system_error'] = str(e)
            return False


async def get_switch_settings(switch_key: str, config: dict) -> dict:
    """Get current settings from a single switch"""
    settings = SwitchSettings(switch_key, config)

    result = {
        "switch": settings.name,
        "key": switch_key,
        "ip": settings.ip,
        "timestamp": datetime.now().isoformat(),
        "settings": {}
    }

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context()
        page = await context.new_page()

        try:
            if not await settings.login(page):
                result["error"] = "Login failed"
                return result

            await settings.capture_vlan_settings(page)
            await settings.capture_pvid_settings(page)
            await settings.capture_system_info(page)

            result["settings"] = settings.settings
            result["success"] = True

        except Exception as e:
            result["error"] = str(e)

        await browser.close()

    return result


def format_vlan_summary(settings_data: dict) -> str:
    """Format VLAN settings for display"""
    vlan = settings_data.get('vlan', {})
    if not vlan or vlan.get('error'):
        return "  (VLAN data unavailable)"

    lines = []
    if vlan.get('enabled'):
        lines.append(f"  ✓ 802.1Q Enabled: {vlan['count']} VLANs")
        for v in vlan.get('vlans', []):
            ports = v.get('memberPorts', [])
            lines.append(f"    VLAN {v['id']:3d} ({v['name']:12s}): Ports {ports}")
    else:
        lines.append("  ✗ 802.1Q Disabled")

    return "\n".join(lines)


def format_pvid_summary(settings_data: dict) -> str:
    """Format PVID settings for display"""
    pvid = settings_data.get('pvid', {})
    if not pvid or pvid.get('error'):
        return "  (PVID data unavailable)"

    lines = [f"  PVIDs per port:"]
    pvids = pvid.get('pvids', [])
    for i, pvid_val in enumerate(pvids, 1):
        lines.append(f"    Port {i}: VLAN {pvid_val}")

    return "\n".join(lines)


def print_settings_summary(all_settings: dict):
    """Print a human-readable summary of current settings"""
    print("\n" + "=" * 70)
    print("CURRENT SWITCH SETTINGS SUMMARY")
    print("=" * 70)

    for key, data in all_settings.items():
        if not data.get('success'):
            print(f"\n❌ {data.get('switch', key)} ({data.get('ip', key)})")
            print(f"   Error: {data.get('error', 'Unknown')}")
            continue

        settings = data.get('settings', {})
        print(f"\n📋 {data['switch']} ({data['ip']})")

        # System info
        sys = settings.get('system', {})
        if sys:
            hw = sys.get('hardware', 'Unknown')
            fw = sys.get('firmware', 'Unknown')
            print(f"   Hardware: {hw} | Firmware: {fw}")

        # VLAN settings
        print("\n" + format_vlan_summary(settings))

        # PVID settings
        print("\n" + format_pvid_summary(settings))

    print("\n" + "=" * 70)
    print("ROLLBACK INSTRUCTIONS:")
    print("  If anything breaks, access switch web UI and:")
    print("  1. Go to VLAN > 802.1Q VLAN")
    print("  2. Uncheck 'Enable 802.1Q VLAN'")
    print("  3. Click Apply")
    print("  This disables VLAN segmentation and restores default behavior.")
    print("=" * 70)


async def main():
    args = sys.argv[1:]

    # Parse arguments
    backup_mode = "--backup" in args or "-b" in args
    specific_switch = None
    for i, arg in enumerate(args):
        if arg in ["--switch", "-s"] and i + 1 < len(args):
            specific_switch = args[i + 1]

    # Filter switches if specific
    switches_to_check = SWITCHES
    if specific_switch:
        if specific_switch not in SWITCHES:
            print(f"Error: Unknown switch '{specific_switch}'")
            print(f"Valid switches: {', '.join(SWITCHES.keys())}")
            sys.exit(1)
        switches_to_check = {specific_switch: SWITCHES[specific_switch]}

    print("=" * 70)
    print("TP-Link Switch Current Settings")
    print("=" * 70)
    print(f"Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print()

    all_settings = {}

    for key, config in switches_to_check.items():
        print(f"Reading {config['name']} ({config['ip']})...")
        settings = await get_switch_settings(key, config)
        all_settings[key] = settings

    # Print summary
    print_settings_summary(all_settings)

    # Save backup if requested
    if backup_mode:
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_file = BACKUP_DIR / f"current-settings-{timestamp}.json"

        backup_data = {
            "timestamp": datetime.now().isoformat(),
            "switches": all_settings,
            "_metadata": {
                "description": "TP-Link Switch VLAN and PVID configuration backup",
                "rollback": "To rollback, access each switch web UI and disable 802.1Q VLAN"
            }
        }

        with open(backup_file, 'w') as f:
            json.dump(backup_data, f, indent=2)

        print(f"\n💾 Backup saved to: {backup_file}")
        print(f"   Use this file for reference or manual rollback")


if __name__ == "__main__":
    asyncio.run(main())
