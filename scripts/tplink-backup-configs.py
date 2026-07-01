#!/usr/bin/env python3
"""
TP-Link Switch Configuration Backup Script
Captures screenshots of all switch configurations before VLAN changes

Usage:
    python3 tplink-backup-configs.py

Switches:
  sw1-modem:    10.1.1.90
  sw2-nexus:    10.1.1.95
  sw3-upstairs: 10.1.1.12
  sw4-zephyr:   10.1.1.104
"""

import asyncio
import sys
from datetime import datetime
from pathlib import Path
from playwright.async_api import async_playwright

# Switch configurations (SEQUENTIAL IPs - 2026-03-10)
SWITCHES = {
    "sw1-modem": {"ip": "10.1.1.10", "model": "TL-SG105E"},
    "sw2-tv": {"ip": "10.1.1.11", "model": "TL-SG105E"},
    "sw3-upstairs": {"ip": "10.1.1.12", "model": "TL-SG105E"},
    "sw4-zephyr": {"ip": "10.1.1.13", "model": "TL-SG105E"},
}

# Default credentials
USERNAME = "admin"
PASSWORD = "ee80cb9718"

# Pages to screenshot (in navigation order)
PAGES_TO_CAPTURE = [
    {"name": "system-info", "url": "/home.htm", "description": "System Information"},
    {"name": "port-status", "url": "/PortRgm.htm", "description": "Port Status"},
    {"name": "vlan-settings", "url": "/VlanMtuRpm.htm", "description": "VLAN Settings"},
    {"name": "port-based-vlan", "url": "/VlanPvid.htm", "description": "Port PVID Configuration"},
    {"name": "port-config", "url": "/PortCfgRpm.htm", "description": "Port Configuration"},
    {"name": "system-ip", "url": "/NmSwIp.htm", "description": "System IP Settings"},
]


class SwitchBackup:
    """Backup switch configuration screenshots"""

    def __init__(self, switch_name, switch_config):
        self.switch_name = switch_name
        self.ip = switch_config["ip"]
        self.model = switch_config["model"]
        self.base_url = f"http://{self.ip}"

        # Create output directory
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.output_dir = Path(
            f"/var/cache/tplink-switches/backups/{timestamp}/{self.switch_name}"
        )
        self.output_dir.mkdir(parents=True, exist_ok=True)

    async def login(self, page):
        """Login to switch web interface"""
        try:
            await page.goto(self.base_url, timeout=15000)
            await page.fill('input[name="username"]', USERNAME)
            await page.fill('input[name="password"]', PASSWORD)
            await page.click('input[name="logon"]')
            await page.wait_for_timeout(3000)

            if "logon" in page.url:
                return False
            return True
        except Exception as e:
            print(f"  ✗ Login error: {e}")
            return False

    async def capture_page(self, page, page_info):
        """Capture screenshot of a specific page"""
        try:
            url = f"{self.base_url}{page_info['url']}"
            await page.goto(url, timeout=15000)
            await page.wait_for_timeout(2000)

            filename = f"{page_info['name']}.png"
            filepath = self.output_dir / filename

            await page.screenshot(path=str(filepath), full_page=True)
            print(f"  ✓ Captured: {page_info['description']}")
            return True
        except Exception as e:
            print(f"  ✗ Failed to capture {page_info['name']}: {e}")
            return False

    async def backup(self):
        """Backup all configuration pages"""
        print(f"\n{'='*60}")
        print(f"Backing up: {self.switch_name} ({self.ip}) - {self.model}")
        print(f"{'='*60}\n")

        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=False)  # Show browser for debugging
            page = await browser.new_page()

            # Login
            print("Logging in...")
            if not await self.login(page):
                await browser.close()
                return False

            # Create summary file
            summary = []
            summary.append(f"Switch: {self.switch_name}")
            summary.append(f"IP: {self.ip}")
            summary.append(f"Model: {self.model}")
            summary.append(f"Backup Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            summary.append(f"\nPages Captured:")

            # Capture each page
            for page_info in PAGES_TO_CAPTURE:
                success = await self.capture_page(page, page_info)
                status = "✓" if success else "✗"
                summary.append(f"  {status} {page_info['description']}")

            await browser.close()

            # Write summary
            with open(self.output_dir / "backup_summary.txt", "w") as f:
                f.write("\n".join(summary))

            print(f"\n✓ Backup complete: {self.output_dir}")
            return True


async def backup_all_switches():
    """Backup all switches"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    print("="*60)
    print("TP-Link Switch Configuration Backup")
    print("="*60)
    print(f"Started: {timestamp}")
    print(f"Output: /var/cache/tplink-switches/backups/")
    print()

    results = {}

    for switch_name, switch_config in SWITCHES.items():
        backup = SwitchBackup(switch_name, switch_config)
        success = await backup.backup()
        results[switch_name] = success

    # Print summary
    print("\n" + "="*60)
    print("Backup Summary")
    print("="*60)

    for switch_name, success in results.items():
        status = "✓" if success else "✗"
        print(f"  {status} {switch_name}")

    failed = [name for name, success in results.items() if not success]

    if failed:
        print(f"\n✗ {len(failed)} backup(s) failed:")
        for name in failed:
            print(f"    - {name}")
        return False
    else:
        print(f"\n✓ All {len(results)} switches backed up successfully!")
        return True


if __name__ == "__main__":
    print("\nThis will backup configurations from all 4 switches.")
    print("A browser window will open for each switch.")
    print("\nPress Enter to continue or Ctrl+C to cancel...")
    try:
        input()
    except KeyboardInterrupt:
        print("\nCancelled.")
        sys.exit(0)

    success = asyncio.run(backup_all_switches())
    sys.exit(0 if success else 1)
