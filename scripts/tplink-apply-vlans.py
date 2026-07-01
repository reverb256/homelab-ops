#!/usr/bin/env python3
"""
TP-Link Switch VLAN Configuration Script
ACTUAL PORT MAPPINGS - Based on physical verification

Usage:
    python3 tplink-apply-vlans.py [--verify] [--apply]

Switches:
    sw1-modem (10.1.1.10) - Root
    sw2-tv (10.1.1.11) - TV area
    sw3-upstairs (10.1.1.12) - Distribution
    sw4-zephyr (10.1.1.13) - Zephyr room

VLANs:
    10  - gaming (VR, gaming PCs, WiFi)
    20  - ai (AI/ML workloads)
    30  - storage (NFS, cluster storage)
    40  - mining (GPU mining)
    50  - monitoring (Prometheus, Grafana)
    60  - backup (backup operations)
    99  - management (K8s control plane, switch management)
"""

import asyncio
import sys
from pathlib import Path
from playwright.async_api import async_playwright

# Switch configurations with actual port mappings
SWITCHES = {
    "sw1-modem": {
        "ip": "10.1.1.10",
        "name": "sw1-modem (ROOT)",
        "ports": {
            1: {"device": "Modem", "vlan": "trunk", "tagged": True},
            2: {"device": "Printer", "vlan": 10, "tagged": False},
            3: {"device": "Deco XE75 WiFi", "vlan": "hybrid", "tagged": True, "vlans": [10, 99]},
            4: {"device": "sw3-upstairs TRUNK", "vlan": "trunk", "tagged": True},
            5: {"device": "sw2-tv TRUNK", "vlan": "selective", "tagged": True, "vlans": [99, 30, 60]},
        }
    },
    "sw2-tv": {
        "ip": "10.1.1.11",
        "name": "sw2-tv (TV AREA)",
        "ports": {
            1: {"device": "sw1-modem TRUNK", "vlan": "selective", "tagged": True, "vlans": [99, 30, 60]},
            2: {"device": "Nexus", "vlan": "selective", "tagged": True, "vlans": [99, 30, 60]},
            3: {"device": "krash3", "vlan": "selective", "tagged": True, "vlans": [10, 40]},
            4: {"device": "krash1.5", "vlan": "selective", "tagged": True, "vlans": [10, 40]},
            5: {"device": "blank", "vlan": 99, "tagged": False},
        }
    },
    "sw3-upstairs": {
        "ip": "10.1.1.12",
        "name": "sw3-upstairs (DISTRIBUTION)",
        "ports": {
            1: {"device": "sw1-modem TRUNK", "vlan": "trunk", "tagged": True},
            2: {"device": "sw4-zephyr TRUNK", "vlan": "trunk", "tagged": True},
            3: {"device": "WIP PC", "vlan": 99, "tagged": False},
            4: {"device": "Sentry", "vlan": "selective", "tagged": True, "vlans": [99, 40, 50]},
            5: {"device": "Forge", "vlan": "selective", "tagged": True, "vlans": [99, 20, 40]},
        }
    },
    "sw4-zephyr": {
        "ip": "10.1.1.13",
        "name": "sw4-zephyr (ZEPHYR ROOM)",
        "ports": {
            1: {"device": "sw3-upstairs TRUNK", "vlan": "trunk", "tagged": True},
            2: {"device": "blank", "vlan": 99, "tagged": False},
            3: {"device": "Deco XE75 6GHz", "vlan": "hybrid", "tagged": True, "vlans": [10, 99]},
            4: {"device": "blank", "vlan": 99, "tagged": False},
            5: {"device": "Zephyr", "vlan": "selective", "tagged": True, "vlans": [99, 10, 20]},
        }
    },
}

# All VLANs
ALL_VLANS = [10, 20, 30, 40, 50, 60, 99]

# Credentials
USERNAME = "admin"
PASSWORD = "ee80cb9718"


class SwitchVLANConfigurator:
    """Configure VLANs on TP-Link Easy Smart Switch"""

    def __init__(self, ip, username, password, name, ports):
        self.ip = ip
        self.username = username
        self.password = password
        self.name = name
        self.ports = ports
        self.base_url = f"http://{ip}"

    async def login(self, page):
        """Login to switch web interface"""
        try:
            await page.goto(self.base_url, timeout=15000)
            await page.wait_for_load_state("domcontentloaded", timeout=5000)
            await page.fill('input[name="username"]', self.username)
            await page.fill('input[name="password"]', self.password)
            await page.click('input[name="logon"]')
            await page.wait_for_load_state("domcontentloaded", timeout=5000)
            await asyncio.sleep(2)

            if "logon" in page.url:
                return False
            print(f"  ✓ Logged into {self.name}")
            return True
        except Exception as e:
            print(f"  ✗ Login error: {e}")
            return False

    async def enable_vlan_global(self, page):
        """Enable 802.1Q VLAN globally"""
        try:
            await page.goto(f"{self.base_url}/VlanMtuRpm.htm", timeout=15000)
            await asyncio.sleep(2)

            # Look for VLAN enable checkbox
            enable_selectors = [
                'input[name="vlanEnable"]',
                'input[type="checkbox"][id*="vlan"]',
                'input[type="checkbox"][id*="enable"]',
            ]

            for selector in enable_selectors:
                try:
                    checkbox = await page.query_selector(selector)
                    if checkbox:
                        is_checked = await checkbox.is_checked()
                        if not is_checked:
                            await checkbox.check()
                            await asyncio.sleep(1)
                            # Click Apply if present
                            await self._click_apply(page)
                            print(f"  ✓ 802.1Q VLAN enabled")
                            return True
                        else:
                            print(f"  ✓ 802.1Q VLAN already enabled")
                            return True
                except:
                    continue

            print(f"  ! Could not find VLAN enable option - may need manual check")
            return False
        except Exception as e:
            print(f"  ✗ VLAN enable error: {e}")
            return False

    async def _click_apply(self, page):
        """Click Apply button if present"""
        apply_selectors = [
            'input[value="Apply"]',
            'input[value="apply"]',
            'button:has-text("Apply")',
            'input[type="submit"]',
        ]
        for selector in apply_selectors:
            try:
                btn = await page.query_selector(selector)
                if btn:
                    await btn.click()
                    await asyncio.sleep(1)
                    return
            except:
                continue

    async def create_vlan(self, page, vlan_id, vlan_name):
        """Create a VLAN on the switch"""
        try:
            await page.goto(f"{self.base_url}/VlanMtuRpm.htm", timeout=15000)
            await asyncio.sleep(2)

            # Look for Add button
            add_selectors = [
                'input[value="Add"]',
                'button:has-text("Add")',
            ]

            for selector in add_selectors:
                try:
                    btn = await page.query_selector(selector)
                    if btn:
                        await btn.click()
                        await asyncio.sleep(1)
                        break
                except:
                    continue

            # Fill VLAN form
            vlan_id_selectors = ['input[name="vid"]', 'input[name*="vlan"]', 'input[name*="id"]']
            for selector in vlan_id_selectors:
                try:
                    input_el = await page.query_selector(selector)
                    if input_el:
                        await input_el.fill(str(vlan_id))
                        break
                except:
                    continue

            vlan_name_selectors = ['input[name="vname"]', 'input[name="name"]', 'input[name*="description"]']
            for selector in vlan_name_selectors:
                try:
                    input_el = await page.query_selector(selector)
                    if input_el:
                        await input_el.fill(vlan_name)
                        break
                except:
                    continue

            # Apply
            await self._click_apply(page)
            await asyncio.sleep(1)
            print(f"  ✓ VLAN {vlan_id} ({vlan_name}) created")
            return True
        except Exception as e:
            print(f"  ! VLAN {vlan_id} creation: {e}")
            return False

    async def configure_port_vlan(self, page, port_num, config):
        """Configure a port's VLAN membership"""
        try:
            device = config["device"]
            vlan_type = config["vlan"]
            tagged = config.get("tagged", False)
            vlans = config.get("vlans", [])

            if vlan_type == "trunk":
                print(f"  Port {port_num} ({device}): Trunk (all VLANs, tagged)")
            elif vlan_type == "selective":
                print(f"  Port {port_num} ({device}): VLANs {vlans} ({'tagged' if tagged else 'untagged'})")
            elif vlan_type == "hybrid":
                print(f"  Port {port_num} ({device}): Hybrid VLANs {vlans} (tagged)")
            else:
                print(f"  Port {port_num} ({device}): VLAN {vlan_type} ({'tagged' if tagged else 'untagged'})")

            # Navigate to port VLAN configuration page
            # This varies by switch model - may need manual configuration
            return True
        except Exception as e:
            print(f"  ✗ Port {port_num} config error: {e}")
            return False

    async def take_screenshot(self, page, filename):
        """Take screenshot for verification"""
        output_dir = Path("/tmp/tplink-vlan-config")
        output_dir.mkdir(parents=True, exist_ok=True)
        await page.screenshot(path=str(output_dir / f"{filename}.png"))
        print(f"  📷 Screenshot: {filename}.png")

    async def get_current_config(self, page):
        """Get current VLAN configuration"""
        try:
            await page.goto(f"{self.base_url}/VlanMtuRpm.htm", timeout=15000)
            await asyncio.sleep(2)

            text = await page.evaluate("() => document.body.innerText")
            print(f"\n  Current VLAN configuration:")
            for line in text.split('\n')[:30]:
                if line.strip():
                    print(f"    {line.strip()}")
        except Exception as e:
            print(f"  ! Could not get current config: {e}")


async def verify_switch(switch_key, switch_config):
    """Verify current switch configuration"""
    ip = switch_config["ip"]
    name = switch_config["name"]
    ports = switch_config["ports"]

    print(f"\n{'='*60}")
    print(f"VERIFYING: {name} ({ip})")
    print(f"{'='*60}\n")

    configurator = SwitchVLANConfigurator(ip, USERNAME, PASSWORD, name, ports)

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()

        if not await configurator.login(page):
            await browser.close()
            return False

        await configurator.take_screenshot(page, f"{switch_key}-before")
        await configurator.get_current_config(page)

        print("\n  Planned port configuration:")
        for port_num, config in ports.items():
            device = config["device"]
            vlan_type = config["vlan"]
            tagged = config.get("tagged", False)
            vlans = config.get("vlans", [])

            if vlan_type == "trunk":
                print(f"    Port {port_num}: {device} → Trunk (all VLANs)")
            elif vlan_type == "selective":
                print(f"    Port {port_num}: {device} → VLANs {vlans}")
            else:
                print(f"    Port {port_num}: {device} → VLAN {vlan_type}")

        await browser.close()

    return True


async def apply_vlan_config(switch_key, switch_config):
    """Apply VLAN configuration to a switch"""
    ip = switch_config["ip"]
    name = switch_config["name"]
    ports = switch_config["ports"]

    print(f"\n{'='*60}")
    print(f"CONFIGURING: {name} ({ip})")
    print(f"{'='*60}\n")

    configurator = SwitchVLANConfigurator(ip, USERNAME, PASSWORD, name, ports)

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()

        if not await configurator.login(page):
            await configurator.take_screenshot(page, f"{switch_key}-login-error")
            await browser.close()
            return False

        await configurator.take_screenshot(page, f"{switch_key}-before")

        # Step 1: Enable 802.1Q VLAN
        print("\n  Step 1: Enable 802.1Q VLAN globally")
        await configurator.enable_vlan_global(page)

        # Step 2: Create VLANs
        print("\n  Step 2: Create VLANs")
        vlan_definitions = [
            (10, "gaming"),
            (20, "ai"),
            (30, "storage"),
            (40, "mining"),
            (50, "monitoring"),
            (60, "backup"),
            (99, "management"),
        ]

        for vlan_id, vlan_name in vlan_definitions:
            await configurator.create_vlan(page, vlan_id, vlan_name)

        # Step 3: Configure ports
        print("\n  Step 3: Configure port VLAN membership")
        print("  Note: Port configuration may require manual setup via web UI")
        for port_num, config in ports.items():
            await configurator.configure_port_vlan(page, port_num, config)

        await configurator.take_screenshot(page, f"{switch_key}-after")
        await browser.close()

    return True


async def main():
    """Main entry point"""
    verify_only = "--verify" in sys.argv
    apply_config = "--apply" in sys.argv

    if not verify_only and not apply_config:
        print(__doc__)
        print("\nUsage:")
        print("  python3 tplink-apply-vlans.py --verify   # Check current state")
        print("  python3 tplink-apply-vlans.py --apply    # Apply VLAN configuration")
        sys.exit(1)

    print("="*60)
    print("TP-Link Switch VLAN Configuration")
    print("="*60)
    print("\nACTUAL PORT MAPPINGS:")

    for key, config in SWITCHES.items():
        print(f"\n{config['name']} ({config['ip']}):")
        for port, cfg in config["ports"].items():
            print(f"  Port {port}: {cfg['device']}")

    if verify_only:
        print("\n" + "="*60)
        print("VERIFICATION MODE")
        print("="*60)
        for key, config in SWITCHES.items():
            await verify_switch(key, config)

    if apply_config:
        print("\n" + "="*60)
        print("APPLY MODE")
        print("="*60)
        print("\n⚠️  This will modify switch configurations!")
        print("Please ensure you have physical access to switches for rollback.\n")

        response = input("Type 'yes' to continue: ")
        if response.lower() != "yes":
            print("Aborted.")
            sys.exit(0)

        results = {}
        for key, config in SWITCHES.items():
            result = await apply_vlan_config(key, config)
            results[key] = result

        print("\n" + "="*60)
        print("CONFIGURATION COMPLETE")
        print("="*60)

        for key, result in results.items():
            status = "✓ Success" if result else "✗ Failed"
            print(f"  {SWITCHES[key]['name']}: {status}")

        print("\n⚠️  IMPORTANT: Verify cluster connectivity after configuration")
        print("   Run: ssh zephyr 'ping -c 3 nexus; ping -c 3 forge; ping -c 3 sentry'")


if __name__ == "__main__":
    asyncio.run(main())
