#!/usr/bin/env python3
"""
TP-Link Switch Configuration Backup
Captures current state before applying changes for rollback purposes
"""

import asyncio
import json
from datetime import datetime
from pathlib import Path
from playwright.async_api import async_playwright

# Switch configurations (SEQUENTIAL IPs - 2026-03-10)
SWITCHES = {
    "sw1-modem": {"ip": "10.1.1.10", "name": "sw1-modem-root (TL-SG105E)"},
    "sw2-tv": {"ip": "10.1.1.11", "name": "sw2-tv-branch (TL-SG105E)"},
    "sw3-upstairs": {"ip": "10.1.1.12", "name": "sw3-upstairs (TL-SG105E)"},
    "sw4-zephyr": {"ip": "10.1.1.13", "name": "sw4-zephyr-end (TL-SG105E)"},
}

USERNAME = "admin"
# Try default password first, then custom
PASSWORDS = ["admin", "ee80cb9718"]

BACKUP_DIR = Path("/tmp/tplink-backup")
BACKUP_DIR.mkdir(parents=True, exist_ok=True)


async def backup_switch(switch_key, switch_config):
    """Backup current configuration of a switch"""
    ip = switch_config["ip"]
    name = switch_config["name"]

    print(f"\n{'='*60}")
    print(f"Backing up: {name} ({ip})")
    print(f"{'='*60}")

    backup_data = {
        "switch": switch_key,
        "name": name,
        "ip": ip,
        "timestamp": datetime.now().isoformat(),
        "pages": {}
    }

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()

        try:
            # Login - try multiple passwords
            await page.goto(f"http://{ip}", timeout=15000)

            for password in PASSWORDS:
                await page.fill('input[name="username"]', USERNAME)
                await page.fill('input[name="password"]', password)
                await page.click('input[name="logon"]')
                await asyncio.sleep(3)

                if "logon" not in page.url:
                    print(f"  ✓ Logged in (password: {password})")
                    backup_data["password_used"] = password
                    break
                else:
                    print(f"  ! Failed with password: {password}")
                    await page.goto(f"http://{ip}", timeout=10000)
                    await asyncio.sleep(1)

            if "logon" in page.url:
                print(f"  ✗ Login failed with all passwords")
                await browser.close()
                return backup_data

            # Capture key configuration pages
            pages_to_backup = [
                ("main", f"http://{ip}"),
                ("system", f"http://{ip}/SystemInfoRpm.htm"),
                ("ports", f"http://{ip}/PortSettingRpm.htm"),
                ("vlan", f"http://{ip}/VlanMtuRpm.htm"),
                ("qos", f"http://{ip}/QosBasicRpm.htm"),
                ("loopback", f"http://{ip}/LoopbackDetectionRpm.htm"),
                ("stats", f"http://{ip}/PortStatisticsRpm.htm"),
            ]

            for page_name, page_url in pages_to_backup:
                try:
                    await page.goto(page_url, timeout=10000)
                    await asyncio.sleep(2)

                    # Get text content
                    text = await page.evaluate("() => document.body.innerText")

                    # Get HTML for detailed backup
                    html = await page.evaluate("() => document.body.innerHTML")

                    backup_data["pages"][page_name] = {
                        "url": page_url,
                        "text": text[:5000],  # First 5000 chars
                        "has_vlan": "vlan" in text.lower(),
                        "has_qos": "qos" in text.lower(),
                        "has_loopback": "loopback" in text.lower(),
                    }

                    # Screenshot
                    screenshot_path = BACKUP_DIR / f"{switch_key}-{page_name}.png"
                    await page.screenshot(path=str(screenshot_path))
                    print(f"  ✓ {page_name}: captured")

                except Exception as e:
                    print(f"  ! {page_name}: {e}")

            # Save JSON
            json_path = BACKUP_DIR / f"{switch_key}-backup.json"
            json_path.write_text(json.dumps(backup_data, indent=2))
            print(f"  ✓ JSON saved: {json_path.name}")

        except Exception as e:
            print(f"  ✗ Error: {e}")

        await browser.close()

    return backup_data


async def main():
    print("="*60)
    print("TP-Link Switch Configuration Backup")
    print("="*60)
    print(f"Backup directory: {BACKUP_DIR}")
    print()

    all_backups = {}
    for key, config in SWITCHES.items():
        backup = await backup_switch(key, config)
        all_backups[key] = backup

    # Save master backup index
    master_backup = {
        "timestamp": datetime.now().isoformat(),
        "switches": all_backups,
        "backup_dir": str(BACKUP_DIR)
    }

    (BACKUP_DIR / "master-backup.json").write_text(json.dumps(master_backup, indent=2))
    print(f"\n{'='*60}")
    print(f"Backup Complete!")
    print(f"{'='*60}")
    print(f"\nAll backups saved to: {BACKUP_DIR}/")
    print(f"Master index: {BACKUP_DIR}/master-backup.json")

    # Create rollback script
    switch_list = "\n".join([f"{config['ip']} ({config['name']})" for config in SWITCHES.values()])
    rollback_content = f"""# TP-Link Switch Rollback Instructions
# Generated: {datetime.now().isoformat()}

## If anything breaks after VLAN configuration:

### Quick Rollback (via Web UI):
1. Login to each switch (admin/admin)
2. Go to VLAN (802.1.1Q VLAN) page
3. Uncheck "Enable 802.1Q VLAN"
4. Click Apply/Save

### Per-Switch Rollback:
{switch_list}

### Full Reset (if needed):
1. Hold reset button on switch for 10 seconds
2. Reconfigure from scratch

### Connectivity Test After Rollback:
ssh zephyr 'for ip in 10.1.1.120 10.1.1.130 10.1.1.140; do ping -c 2 $ip; done'
"""
    rollback_script = BACKUP_DIR / "ROLLBACK.txt"
    rollback_script.write_text(rollback_content)

    print(f"\n📋 Rollback instructions: {rollback_script}")
    print(f"📂 Backup files: {BACKUP_DIR}/")


if __name__ == "__main__":
    asyncio.run(main())
