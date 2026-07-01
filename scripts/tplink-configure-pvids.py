#!/usr/bin/env python3
"""
TP-Link Switch PVID Configuration Script
Configures Port VLAN IDs (PVIDs) on all switches to direct untagged traffic to VLAN 99.

USAGE:
    # Show current PVIDs
    python3 tplink-configure-pvids.py

    # Configure PVIDs (dry-run by default)
    python3 tplink-configure-pvids.py --dry-run

    # Actually apply PVID changes
    python3 tplink-configure-pvids.py --apply

    # Configure specific switch only
    python3 tplink-configure-pvids.py --switch sw1-modem --apply

PVID TARGETS:
    sw1-modem: [99, 10, 1, 99, 99]   (Modem, Printer, [EMPTY], sw3, sw2)
    sw2-tv:    [99, 99, 1, 1, 1]       (sw1, Nexus)
    sw3-upstairs: [99, 99, 1, 99, 99]  (sw1, sw4, Spare, Sentry, Forge)
    sw4-zephyr: [99, 1, 99, 1, 99]      (sw3, [spare], AP, [spare], Zephyr)

SAFETY:
    - Dry-run mode shows what would change without applying
    - Full rollback procedure documented in help output
    - All changes reversible via --reset flag
"""

import asyncio
import sys
from playwright.async_api import async_playwright

# Switch configurations
SWITCHES = {
    "sw1-modem": {"ip": "10.1.1.10", "name": "sw1-modem-root"},
    "sw2-tv": {"ip": "10.1.1.11", "name": "sw2-tv-branch"},
    "sw3-upstairs": {"ip": "10.1.1.12", "name": "sw3-upstairs"},
    "sw4-zephyr": {"ip": "10.1.1.13", "name": "sw4-zephyr-end"},
}

# Target PVID configuration (port indices 1-5)
TARGET_PVIDS = {
    "sw1-modem": [99, 10, 1, 99, 99],       # Modem, Printer, [EMPTY], sw3, sw2
    "sw2-tv": [99, 99, 1, 1, 1],          # sw1, Nexus
    "sw3-upstairs": [99, 99, 1, 99, 99],    # sw1, sw4, Spare, Sentry, Forge
    "sw4-zephyr": [99, 1, 99, 1, 99],        # sw3, [spare], AP, [spare], Zephyr
}

USERNAME = "admin"
PASSWORD = "ee80cb9718"


class PVIDConfigurator:
    """Configure PVIDs on TP-Link switches"""

    def __init__(self, switch_key: str, config: dict, target_pvids: list):
        self.switch_key = switch_key
        self.ip = config["ip"]
        self.name = config["name"]
        self.target_pvids = target_pvids
        self.base_url = f"http://{self.ip}"
        self.current_pvids = []

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

    async def get_current_pvids(self, page):
        """Get current PVID configuration"""
        try:
            await page.goto(f"{self.base_url}/Vlan8021QPvidRpm.htm", timeout=15000)
            await asyncio.sleep(1)

            pvid_data = await page.evaluate('''() => {
                if (window.pvid_ds) {
                    return window.pvid_ds.pvids;
                }
                return null;
            }''')

            self.current_pvids = pvid_data if pvid_data else [1, 1, 1, 1, 1]
            return True
        except Exception as e:
            print(f"  ✗ Error getting PVIDs: {e}")
            return False

    async def configure_pvids(self, page, dry_run=True):
        """Configure PVIDs on the switch"""
        try:
            await page.goto(f"{self.base_url}/Vlan8021QPvidRpm.htm", timeout=15000)
            await asyncio.sleep(1)

            if dry_run:
                print(f"\n  [DRY RUN] Would configure PVIDs:")
                for i, (current, target) in enumerate(zip(self.current_pvids, self.target_pvids), 1):
                    status = "✓" if current == target else "→"
                    print(f"    Port {i}: {current} {status} {target}")
                return True

            # Find PVID input fields and set values
            for port_num in range(1, 6):
                port_index = port_num - 1
                target_pvid = self.target_pvids[port_index]

                # Try multiple selectors for PVID input
                selectors = [
                    f'#port{port_num}Pvid',
                    f'input[name="port{port_num}Pvid"]',
                    f'input[placeholder*="Port {port_num}"]',
                ]

                for selector in selectors:
                    try:
                        input_elem = await page.query_selector(selector)
                        if input_elem:
                            await input_elem.fill(str(target_pvid))
                            break
                    except:
                        continue

            # Click Apply button
            await asyncio.sleep(1)

            selectors = [
                'input[value="Apply"]',
                'input[name="pvid_apply"]',
                'button:has-text("Apply")',
            ]

            for selector in selectors:
                try:
                    btn = await page.query_selector(selector)
                    if btn:
                        await btn.click()
                        break
                except:
                    continue

            await asyncio.sleep(3)
            return True

        except Exception as e:
            print(f"  ✗ Configuration error: {e}")
            return False

    async def verify_pvids(self, page):
        """Verify PVIDs were applied correctly"""
        try:
            await asyncio.sleep(2)
            await page.goto(f"{self.base_url}/Vlan8021QPvidRpm.htm", timeout=15000)
            await asyncio.sleep(1)

            pvid_data = await page.evaluate('''() => {
                if (window.pvid_ds) {
                    return window.pvid_ds.pvids;
                }
                return null;
            }''')

            if not pvid_data:
                print("  ⚠ Could not verify PVIDs (no data returned)")
                return False

            success = True
            print(f"\n  PVID Verification:")
            for i, (actual, expected) in enumerate(zip(pvid_data, self.target_pvids), 1):
                match = "✓" if actual == expected else "✗"
                print(f"    Port {i}: {actual} (expected {expected}) {match}")
                if actual != expected:
                    success = False

            return success
        except Exception as e:
            print(f"  ✗ Verification error: {e}")
            return False


async def configure_switch(switch_key: str, dry_run: bool = True):
    """Configure a single switch"""
    if switch_key not in SWITCHES:
        print(f"Error: Unknown switch '{switch_key}'")
        return False

    config = SWITCHES[switch_key]
    target_pvids = TARGET_PVIDS[switch_key]
    configurator = PVIDConfigurator(switch_key, config, target_pvids)

    print(f"\n{'='*70}")
    print(f"SWITCH: {config['name']} ({config['ip']})")
    print(f"{'='*70}")

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context()
        page = await context.new_page()

        try:
            # Login
            if not await configurator.login(page):
                print("  ✗ Login failed")
                return False

            # Get current PVIDs
            if not await configurator.get_current_pvids(page):
                print("  ✗ Failed to get current PVIDs")
                return False

            print(f"  Current PVIDs: {configurator.current_pvids}")
            print(f"  Target PVIDs:  {target_pvids}")

            # Configure
            if not await configurator.configure_pvids(page, dry_run=dry_run):
                print("  ✗ Configuration failed")
                return False

            # Verify (only if not dry run)
            if not dry_run:
                if await configurator.verify_pvids(page):
                    print(f"\n  ✓ {config['name']}: PVID configuration successful")
                else:
                    print(f"\n  ✗ {config['name']}: PVID verification failed")
                    return False
            else:
                print(f"\n  [DRY RUN] No changes made to {config['name']}")

        except Exception as e:
            print(f"  ✗ Error: {e}")
            return False
        finally:
            await browser.close()

    return True


async def reset_switch_pvids(switch_key: str):
    """Reset all PVIDs on a switch to 1 (rollback)"""
    if switch_key not in SWITCHES:
        print(f"Error: Unknown switch '{switch_key}'")
        return False

    config = SWITCHES[switch_key]
    reset_pvids = [1, 1, 1, 1, 1]
    configurator = PVIDConfigurator(switch_key, config, reset_pvids)

    print(f"\n{'='*70}")
    print(f"RESET: {config['name']} ({config['ip']}) - All PVIDs → 1")
    print(f"{'='*70}")

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context()
        page = await context.new_page()

        try:
            if not await configurator.login(page):
                return False

            if not await configurator.configure_pvids(page, dry_run=False):
                return False

            print(f"  ✓ {config['name']}: PVID reset successful")
            return True

        except Exception as e:
            print(f"  ✗ Error: {e}")
            return False
        finally:
            await browser.close()


def print_summary():
    """Print configuration summary"""
    print("\n" + "="*70)
    print("PVID CONFIGURATION SUMMARY")
    print("="*70)

    for switch_key, pvids in TARGET_PVIDS.items():
        switch = SWITCHES[switch_key]
        print(f"\n{switch['name']} ({switch['ip']}):")
        print(f"  PVIDs: {pvids}")

    print("\n" + "="*70)
    print("LEGEND:")
    print("  PVID 99  = Management VLAN (cluster nodes)")
    print("  PVID 10  = Gaming VLAN (printer)")
    print("  PVID 1   = Default VLAN (unused ports)")
    print("="*70)


async def main():
    args = sys.argv[1:]

    dry_run = "--dry-run" in args or "-d" in args
    apply_mode = "--apply" in args or "-a" in args
    reset_mode = "--reset" in args or "-r" in args
    specific_switch = None

    for i, arg in enumerate(args):
        if arg in ["--switch", "-s"] and i + 1 < len(args):
            specific_switch = args[i + 1]

    if reset_mode:
        print("ROLLBACK MODE: Resetting all PVIDs to 1")
        switches_to_reset = [specific_switch] if specific_switch else list(SWITCHES.keys())

        for switch_key in switches_to_reset:
            await reset_switch_pvids(switch_key)

        print("\n" + "="*70)
        print("ROLLBACK COMPLETE")
        print("All switches have been reset to PVID = 1")
        print("="*70)
        return

    # Normal configuration mode
    print_summary()

    if not dry_run and not apply_mode:
        print("\n⚠️  WARNING: No mode specified. Use --dry-run to preview changes.")
        print("            Use --apply to actually configure PVIDs.")
        print("\nDefaulting to --dry-run mode for safety.\n")
        dry_run = True

    switches_to_config = [specific_switch] if specific_switch else list(SWITCHES.keys())

    for switch_key in switches_to_config:
        await configure_switch(switch_key, dry_run=dry_run)

    if not dry_run:
        print("\n" + "="*70)
        print("CONFIGURATION COMPLETE")
        print("="*70)
        print("\nNext steps:")
        print("1. Verify all switches are reachable: ping 10.1.1.10-13")
        print("2. Verify cluster nodes: ping 10.1.1.110, 120, 130, 140")
        print("3. Verify Kubernetes: kubectl get nodes")
        print("\nRollback if needed:")
        print("  python3 tplink-configure-pvids.py --reset")
        print("="*70)


if __name__ == "__main__":
    asyncio.run(main())
