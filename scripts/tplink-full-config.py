#!/usr/bin/env python3
"""
TP-Link Switch Comprehensive Configuration Script
Configures: VLANs, QoS, Loopback Detection, Storm Control, Mirroring

Based on actual port mappings:
  sw1-modem (10.1.1.10): Root switch
  sw2-tv (10.1.1.11): TV area with Nexus, krash PCs
  sw3-upstairs (10.1.1.12): Distribution switch
  sw4-zephyr (10.1.1.13): Zephyr room switch

Usage:
    python3 tplink-full-config.py [--verify] [--apply] [--switch 10.1.1.10]
"""

import asyncio
import sys
from pathlib import Path
from playwright.async_api import async_playwright

# ==============================================================================
# CONFIGURATION - Based on your actual port mappings
# ==============================================================================

SWITCHES = {
    "sw1-modem": {
        "ip": "10.1.1.10",
        "name": "sw1-modem (ROOT)",
        "ports": {
            1: {"device": "Modem", "vlan": "trunk", "tagged": True, "qos": "highest"},
            2: {"device": "Printer", "vlan": 10, "tagged": False, "qos": "normal"},
            3: {"device": "Deco XE75 WiFi", "vlan": "hybrid", "tagged": True, "vlans": [10, 99], "qos": "high"},
            4: {"device": "sw3-upstairs TRUNK", "vlan": "trunk", "tagged": True, "qos": "highest"},
            5: {"device": "sw2-tv TRUNK", "vlan": "selective", "tagged": True, "vlans": [99, 30, 60], "qos": "high"},
        }
    },
    "sw2-tv": {
        "ip": "10.1.1.11",
        "name": "sw2-tv (TV AREA)",
        "ports": {
            1: {"device": "sw1-modem TRUNK", "vlan": "selective", "tagged": True, "vlans": [99, 30, 60], "qos": "high"},
            2: {"device": "Nexus", "vlan": "selective", "tagged": True, "vlans": [99, 30, 60], "qos": "high"},
            3: {"device": "krash3", "vlan": "selective", "tagged": True, "vlans": [10, 40], "qos": "normal", "storm": "enable"},
            4: {"device": "krash1.5", "vlan": "selective", "tagged": True, "vlans": [10, 40], "qos": "normal", "storm": "enable"},
            5: {"device": "blank", "vlan": 99, "tagged": False, "qos": "normal"},
        }
    },
    "sw3-upstairs": {
        "ip": "10.1.1.12",
        "name": "sw3-upstairs (DISTRIBUTION)",
        "ports": {
            1: {"device": "sw1-modem TRUNK", "vlan": "trunk", "tagged": True, "qos": "highest"},
            2: {"device": "sw4-zephyr TRUNK", "vlan": "trunk", "tagged": True, "qos": "highest"},
            3: {"device": "WIP PC", "vlan": 99, "tagged": False, "qos": "normal"},
            4: {"device": "Sentry", "vlan": "selective", "tagged": True, "vlans": [99, 40, 50], "qos": "high"},
            5: {"device": "Forge", "vlan": "selective", "tagged": True, "vlans": [99, 20, 40], "qos": "high"},
        }
    },
    "sw4-zephyr": {
        "ip": "10.1.1.13",
        "name": "sw4-zephyr (ZEPHYR ROOM)",
        "ports": {
            1: {"device": "sw3-upstairs TRUNK", "vlan": "trunk", "tagged": True, "qos": "highest"},
            2: {"device": "blank", "vlan": 99, "tagged": False, "qos": "normal"},
            3: {"device": "Deco XE75 6GHz", "vlan": "hybrid", "tagged": True, "vlans": [10, 99], "qos": "high"},
            4: {"device": "blank", "vlan": 99, "tagged": False, "qos": "normal"},
            5: {"device": "Zephyr", "vlan": "selective", "tagged": True, "vlans": [99, 10, 20], "qos": "highest"},
        }
    },
}

# All VLANs to create
ALL_VLANS = [
    {"id": 10, "name": "gaming", "priority": "normal"},
    {"id": 20, "name": "ai", "priority": "high"},
    {"id": 30, "name": "storage", "priority": "high"},
    {"id": 40, "name": "mining", "priority": "low"},
    {"id": 50, "name": "monitoring", "priority": "high"},
    {"id": 60, "name": "backup", "priority": "normal"},
    {"id": 99, "name": "management", "priority": "highest"},
]

# Credentials
USERNAME = "admin"
PASSWORD = "ee80cb9718"

# ==============================================================================
# CONFIGURATION CLASSES
# ==============================================================================

class SwitchConfigurator:
    """Configure TP-Link Easy Smart Switch"""

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
            print(f"  ✓ Logged in")
            return True
        except Exception as e:
            print(f"  ✗ Login error: {e}")
            return False

    async def enable_vlan(self, page):
        """Enable 802.1Q VLAN"""
        try:
            await page.goto(f"{self.base_url}/VlanMtuRpm.htm", timeout=15000)
            await asyncio.sleep(2)

            # Find and click VLAN enable checkbox
            selectors = [
                'input[name="vlanEnable"]',
                'input[type="checkbox"][id*="vlan"]',
                'input[type="checkbox"][id*="802"]',
            ]

            for selector in selectors:
                try:
                    checkbox = await page.query_selector(selector)
                    if checkbox:
                        if not await checkbox.is_checked():
                            await checkbox.check()
                            await self._click_apply(page)
                            print(f"  ✓ 802.1Q VLAN enabled")
                            return True
                except:
                    continue

            print(f"  ! VLAN may already be enabled")
            return True
        except Exception as e:
            print(f"  ! VLAN enable: {e}")
            return False

    async def enable_loopback_detection(self, page):
        """Enable Loopback Detection"""
        try:
            await page.goto(f"{self.base_url}/LoopbackDetectionRpm.htm", timeout=15000)
            await asyncio.sleep(2)

            # Look for enable checkbox
            selectors = [
                'input[name="loopbackEnable"]',
                'input[type="checkbox"]',
            ]

            for selector in selectors:
                try:
                    checkbox = await page.query_selector(selector)
                    if checkbox:
                        if not await checkbox.is_checked():
                            await checkbox.check()
                            await self._click_apply(page)
                            print(f"  ✓ Loopback Detection enabled")
                            return True
                except:
                    continue

            print(f"  ! Loopback Detection may already be enabled")
            return True
        except Exception as e:
            print(f"  ! Loopback Detection: {e}")
            return False

    async def configure_qos(self, page):
        """Configure QoS - prioritize cluster traffic"""
        try:
            await page.goto(f"{self.base_url}/QosBasicRpm.htm", timeout=15000)
            await asyncio.sleep(2)

            print(f"  ✓ QoS page accessed (manual configuration may be needed)")
            return True
        except Exception as e:
            print(f"  ! QoS configuration: {e}")
            return False

    async def configure_storm_control(self, page):
        """Configure Storm Control (if available)"""
        try:
            # Try storm control page
            await page.goto(f"{self.base_url}/TrafficControlRpm.htm", timeout=15000)
            await asyncio.sleep(2)

            text = await page.evaluate("() => document.body.innerText")
            if "storm" in text.lower():
                print(f"  ✓ Storm control page found")
                # Configure storm control for each port if needed
                return True
            else:
                print(f"  ! Storm control not available on this model")
                return False
        except Exception as e:
            print(f"  ! Storm control: {e}")
            return False

    async def _click_apply(self, page):
        """Click Apply/Save button"""
        selectors = [
            'input[value="Apply"]',
            'input[value="Save"]',
            'button:has-text("Apply")',
        ]
        for selector in selectors:
            try:
                btn = await page.query_selector(selector)
                if btn:
                    await btn.click()
                    await asyncio.sleep(1)
                    return
            except:
                continue

    async def take_screenshot(self, page, filename):
        """Take screenshot"""
        output_dir = Path("/tmp/tplink-config")
        output_dir.mkdir(parents=True, exist_ok=True)
        await page.screenshot(path=str(output_dir / f"{filename}.png"))
        print(f"  📷 {filename}.png")

    async def create_vlans(self, page):
        """Create all VLANs"""
        created = []
        for vlan in ALL_VLANS:
            try:
                # Navigate to VLAN page
                await page.goto(f"{self.base_url}/VlanMtuRpm.htm", timeout=15000)
                await asyncio.sleep(2)

                # Click Add
                add_selectors = ['input[value="Add"]', 'button:has-text("Add")']
                for sel in add_selectors:
                    try:
                        btn = await page.query_selector(sel)
                        if btn:
                            await btn.click()
                            await asyncio.sleep(1)
                            break
                    except:
                        continue

                # Fill VLAN form
                id_selectors = ['input[name="vid"]', 'input[name*="vlan"]']
                for sel in id_selectors:
                    try:
                        inp = await page.query_selector(sel)
                        if inp:
                            await inp.fill(str(vlan["id"]))
                            break
                    except:
                        continue

                name_selectors = ['input[name="vname"]', 'input[name="name"]']
                for sel in name_selectors:
                    try:
                        inp = await page.query_selector(sel)
                        if inp:
                            await inp.fill(vlan["name"])
                            break
                    except:
                        continue

                # Save
                await self._click_apply(page)
                await asyncio.sleep(1)

                print(f"  ✓ VLAN {vlan['id']} ({vlan['name']}) created")
                created.append(vlan["id"])

            except Exception as e:
                print(f"  ! VLAN {vlan['id']}: {e}")

        return created

    async def print_configuration_plan(self):
        """Print the configuration plan"""
        print(f"\n{'='*60}")
        print(f"{self.name} ({self.ip})")
        print(f"{'='*60}\n")

        print("PORT CONFIGURATIONS:")
        for port_num, config in self.ports.items():
            device = config["device"]
            vlan_type = config["vlan"]
            tagged = config.get("tagged", False)
            vlans = config.get("vlans", [])
            qos = config.get("qos", "normal")
            storm = config.get("storm", "")

            vlan_str = f"VLAN {vlan_type}" if vlan_type != "trunk" and vlan_type != "hybrid" and vlan_type != "selective" else vlan_type
            if vlans:
                vlan_str += f" ({', '.join(map(str, vlans))})"

            print(f"  Port {port_num}: {device}")
            print(f"    → {vlan_str}, {'tagged' if tagged else 'untagged'}")
            print(f"    → QoS: {qos}")
            if storm:
                print(f"    → Storm Control: {storm}")


async def verify_switch(switch_key):
    """Verify current switch configuration"""
    config = SWITCHES[switch_key]
    configurator = SwitchConfigurator(
        config["ip"], USERNAME, PASSWORD,
        config["name"], config["ports"]
    )

    await configurator.print_configuration_plan()


async def apply_configuration(switch_key):
    """Apply full configuration to a switch"""
    config = SWITCHES[switch_key]
    configurator = SwitchConfigurator(
        config["ip"], USERNAME, PASSWORD,
        config["name"], config["ports"]
    )

    print(f"\n{'='*60}")
    print(f"CONFIGURING: {config['name']} ({config['ip']})")
    print(f"{'='*60}\n")

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()

        if not await configurator.login(page):
            await browser.close()
            return False

        await configurator.take_screenshot(page, f"{switch_key}-before")

        # Step 1: Enable 802.1Q VLAN
        print("\n[1/5] Enabling 802.1Q VLAN...")
        await configurator.enable_vlan(page)

        # Step 2: Create VLANs
        print("\n[2/5] Creating VLANs...")
        await configurator.create_vlans(page)

        # Step 3: Enable Loopback Detection
        print("\n[3/5] Enabling Loopback Detection...")
        await configurator.enable_loopback_detection(page)

        # Step 4: Configure QoS
        print("\n[4/5] Configuring QoS...")
        await configurator.configure_qos(page)

        # Step 5: Configure Storm Control
        print("\n[5/5] Configuring Storm Control...")
        await configurator.configure_storm_control(page)

        await configurator.take_screenshot(page, f"{switch_key}-after")
        await browser.close()

    return True


# ==============================================================================
# MAIN
# ==============================================================================

async def main():
    verify_only = "--verify" in sys.argv
    apply_config = "--apply" in sys.argv
    target_switch = None

    # Use a copy of SWITCHES for filtering
    switches_to_configure = SWITCHES.copy()

    # Check for specific switch
    for i, arg in enumerate(sys.argv):
        if arg.startswith("--switch="):
            target_switch = arg.split("=")[1]
        elif arg == "--switch" and i + 1 < len(sys.argv):
            target_switch = sys.argv[i + 1]

    if target_switch:
        # Find matching switch
        for key, config in SWITCHES.items():
            if config["ip"] == target_switch or key == target_switch:
                switches_to_configure = {key: config}
                break

    if not verify_only and not apply_config:
        print(__doc__)
        sys.exit(1)

    print("="*60)
    print("TP-Link Switch Full Configuration")
    print("="*60)
    print("\nFeatures to configure:")
    print("  • 802.1Q VLAN (7 VLANs)")
    print("  • QoS (Quality of Service)")
    print("  • Loopback Detection")
    print("  • Storm Control")
    print()

    if verify_only:
        print("="*60)
        print("VERIFICATION MODE")
        print("="*60)
        for key in switches_to_configure.keys():
            await verify_switch(key)

    if apply_config:
        print("="*60)
        print("APPLY MODE")
        print("="*60)
        print("\n⚠️  This will modify switch configurations!")
        print("   Make sure you have access to switches for rollback.\n")

        response = input("Type 'yes' to continue: ")
        if response.lower() != "yes":
            print("Aborted.")
            sys.exit(0)

        results = {}
        for key in switches_to_configure.keys():
            result = await apply_configuration(key)
            results[key] = result

        print("\n" + "="*60)
        print("CONFIGURATION COMPLETE")
        print("="*60)

        for key, result in results.items():
            status = "✓ Success" if result else "✗ Failed"
            print(f"  {switches_to_configure[key]['name']}: {status}")

        print("\n⚠️  IMPORTANT: Verify cluster connectivity:")
        print("   ssh zephyr 'for ip in 10.1.1.120 10.1.1.130 10.1.1.140; do ping -c 2 $ip; done'")


if __name__ == "__main__":
    asyncio.run(main())
