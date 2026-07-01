#!/usr/bin/env python3
"""
TP-Link Switch 802.1Q VLAN API Configuration Script

Uses TP-Link's CGI API to configure 802.1Q VLANs programmatically.

API Discovery (via browser inspection 2026-03-10):
  - Uses GET requests (not POST) to /qvlanSet.cgi
  - Enable 802.1Q:   GET /qvlanSet.cgi?qvlan_en=1&qvlan_mode=Apply
  - Disable 802.1Q:  GET /qvlanSet.cgi?qvlan_en=0&qvlan_mode=Apply
  - Add VLAN:        GET /qvlanSet.cgi?vid=N&vname=NAME&selType_1=X&selType_2=X...&qvlan_add=Add%2FModify
  - Delete VLAN:     GET /qvlanSet.cgi?vid=N&qvlan_del=Delete

  Port membership values (selType_N):
    0 = Untagged
    1 = Tagged
    2 = Not Member (default)

Switch IPs (SEQUENTIAL IPs - 2026-03-10):
  sw1-modem:    10.1.1.10 (Root/Gateway) - TL-SG105E
  sw2-tv:       10.1.1.11 (Access/Nexus) - TL-SG105E
  sw3-upstairs: 10.1.1.12 (Distribution) - TL-SG105E
  sw4-zephyr:   10.1.1.13 (Access/Zephyr) - TL-SG105E

VLANs:
  10  - gaming (VR streaming, gaming traffic)
  20  - ai (AI/ML workloads)
  30  - storage (NFS/cluster storage)
  40  - mining (GPU mining)
  50  - monitoring (Prometheus/Grafana)
  60  - backup (backup operations)
  99  - management (switch management, K8s control plane)

Usage:
    python3 tplink-api-vlan.py --enable        # Enable 802.1Q on all switches
    python3 tplink-api-vlan.py --create-vlans  # Create all 7 VLANs
    python3 tplink-api-vlan.py --status        # Show current VLAN status
    python3 tplink-api-vlan.py --all           # Run full configuration
"""

import argparse
import subprocess
import sys
import time
import re
from pathlib import Path

# Switch configurations (SEQUENTIAL IPs - 2026-03-10)
SWITCHES = {
    "sw1-modem": {
        "ip": "10.1.1.10",
        "name": "sw1-modem-root",
        "role": "root",
        "vlans": ["all"],  # Carries all VLANs
        "trunk_ports": [1, 4, 5],  # Modem, sw3-upstairs, sw2-tv
    },
    "sw2-tv": {
        "ip": "10.1.1.11",
        "name": "sw2-tv-branch",
        "role": "branch",
        "vlans": [99, 30, 60],  # Management, storage, backup
        "trunk_ports": [1],  # sw1-modem
    },
    "sw3-upstairs": {
        "ip": "10.1.1.12",
        "name": "sw3-upstairs",
        "role": "distribution",
        "vlans": ["all"],
        "trunk_ports": [1, 2],  # sw1-modem, sw4-zephyr
    },
    "sw4-zephyr": {
        "ip": "10.1.1.13",
        "name": "sw4-zephyr-end",
        "role": "access",
        "vlans": ["all"],
        "trunk_ports": [1],  # sw3-upstairs
    },
}

# VLAN definitions
VLANS = [
    {"id": 10, "name": "gaming"},
    {"id": 20, "name": "ai"},
    {"id": 30, "name": "storage"},
    {"id": 40, "name": "mining"},
    {"id": 50, "name": "monitoring"},
    {"id": 60, "name": "backup"},
    {"id": 99, "name": "management"},
]

# Default credentials
USERNAME = "admin"
PASSWORD = "ee80cb9718"
COOKIE_FILE = "/tmp/tp-link-cookies.txt"


class SwitchVLANAPI:
    """Configure VLANs on TP-Link Easy Smart Switch via CGI API"""

    def __init__(self, ip, username, password, name):
        self.ip = ip
        self.username = username
        self.password = password
        self.name = name
        self.base_url = f"http://{ip}"

    def _get(self, endpoint):
        """Make a GET request to the switch API"""
        url = f"{self.base_url}/{endpoint}"
        try:
            result = subprocess.run(
                ["curl", "-s", "-b", COOKIE_FILE, url],
                capture_output=True,
                text=True,
                timeout=10
            )
            return result.stdout, result.returncode
        except subprocess.TimeoutExpired:
            return None, -1

    def login(self):
        """Login to the switch and save session cookie"""
        print(f"  → Logging in to {self.ip}...")

        result = subprocess.run([
            "curl", "-s", "-c", COOKIE_FILE,
            f"{self.base_url}/login.cgi",
            "-d", f"username={self.username}",
            "-d", f"password={self.password}",
        ], capture_output=True, text=True)

        # Check for successful login (logonInfo[0] == 0 means success)
        # A failed login shows "logonInfo = new Array(1,..." or "logonInfo = new Array(2,..."
        if re.search(r'logonInfo\s*=\s*new\s+Array\s*\(\s*0\s*,', result.stdout):
            print(f"  ✓ Login successful")
            return True
        elif re.search(r'logonInfo\s*=\s*new\s+Array\s*\(\s*[1-9]\s*,', result.stdout):
            print(f"  ✗ Login failed: Wrong username or password")
            return False
        else:
            print(f"  ! Login response unclear, proceeding anyway")
            return True

    def enable_8021q(self):
        """Enable 802.1Q VLAN globally"""
        print(f"  → Enabling 802.1Q VLAN...")

        _, code = self._get("qvlanSet.cgi?qvlan_en=1&qvlan_mode=Apply")

        if code == 0:
            print(f"  ✓ 802.1Q VLAN enabled")
            time.sleep(1)
            return True
        else:
            print(f"  ✗ Failed to enable 802.1Q VLAN")
            return False

    def disable_8021q(self):
        """Disable 802.1Q VLAN globally"""
        print(f"  → Disabling 802.1Q VLAN...")

        _, code = self._get("qvlanSet.cgi?qvlan_en=0&qvlan_mode=Apply")

        if code == 0:
            print(f"  ✓ 802.1Q VLAN disabled")
            return True
        else:
            print(f"  ✗ Failed to disable 802.1Q VLAN")
            return False

    def create_vlan(self, vlan_id, vlan_name, port_config=None):
        """
        Create a VLAN with optional port configuration.

        Args:
            vlan_id: VLAN ID (1-4094)
            vlan_name: VLAN name (max 10 chars)
            port_config: Dict of {port_num: membership} where:
                        0 = Untagged, 1 = Tagged, 2 = Not Member
                        If None, creates VLAN with no ports (will fail)
        """
        if port_config is None:
            port_config = {}

        # Build the URL parameters
        params = [f"vid={vlan_id}", f"vname={vlan_name}"]

        # Add port configuration
        for port in range(1, 6):  # Ports 1-5
            membership = port_config.get(port, 2)  # Default: Not Member
            params.append(f"selType_{port}={membership}")

        params.append("qvlan_add=Add/Modify")
        url = f"qvlanSet.cgi?{'&'.join(params)}"

        print(f"  → Creating VLAN {vlan_id} ({vlan_name})...")
        # Show port config
        if port_config:
            port_summary = []
            for p in range(1, 6):
                m = port_config.get(p, 2)
                if m == 0:
                    port_summary.append(f"P{p}:U")
                elif m == 1:
                    port_summary.append(f"P{p}:T")
            print(f"     Ports: {' '.join(port_summary)}")

        _, code = self._get(url)

        if code == 0:
            print(f"  ✓ VLAN {vlan_id} created")
            time.sleep(0.5)
            return True
        else:
            print(f"  ✗ Failed to create VLAN {vlan_id}")
            return False

    def delete_vlan(self, vlan_id):
        """Delete a VLAN"""
        print(f"  → Deleting VLAN {vlan_id}...")

        _, code = self._get(f"qvlanSet.cgi?vid={vlan_id}&qvlan_del=Delete")

        if code == 0:
            print(f"  ✓ VLAN {vlan_id} deleted")
            return True
        else:
            print(f"  ✗ Failed to delete VLAN {vlan_id}")
            return False

    def get_vlan_status(self):
        """Get current VLAN status by parsing the HTML response"""
        print(f"  → Getting VLAN status...")

        html, _ = self._get("Vlan8021QRpm.htm")

        if html and "802.1Q VLAN Configuration" in html:
            # Extract qvlan_ds variables
            count_match = re.search(r'qvlan_ds\.count=(\d+)', html)
            state_match = re.search(r'qvlan_ds\.state=(\d+)', html)
            vids_match = re.search(r'qvlan_ds\.vids=\[([^\]]+)\]', html)
            names_match = re.search(r'qvlan_ds\.names=\[([^\]]+)\]', html)

            if count_match:
                count = int(count_match.group(1))
                state = int(state_match.group(1)) if state_match else 0

                vids = []
                names = []

                if vids_match:
                    vids = [int(v.strip()) for v in vids_match.group(1).split(',') if v.strip()]

                if names_match:
                    # Extract quoted strings
                    names = re.findall(r'"([^"]*)"', names_match.group(1))

                enabled = "YES" if state == 1 else "NO"

                print(f"  802.1Q Enabled: {enabled}")
                print(f"  VLAN Count: {count}")

                for vid, name in zip(vids, names):
                    print(f"    VLAN {vid}: {name}")

                return {
                    "enabled": state == 1,
                    "count": count,
                    "vids": vids,
                    "names": names
                }

        print(f"  ! Could not parse VLAN status")
        return None


def get_port_config_for_switch(switch_key, vlan_id):
    """
    Get port configuration for a specific VLAN on a specific switch.
    Returns: Dict of {port_num: membership} (0=Untagged, 1=Tagged, 2=Not Member)
    """
    switch = SWITCHES[switch_key]
    trunk_ports = switch.get("trunk_ports", [])

    # Default: all ports not members
    port_config = {1: 2, 2: 2, 3: 2, 4: 2, 5: 2}

    # For management VLAN (99): all trunk ports tagged
    if vlan_id == 99:
        for p in range(1, 6):
            if p in trunk_ports:
                port_config[p] = 1  # Tagged on trunk
            else:
                port_config[p] = 0  # Untagged on access

    # Configure specific ports based on switch and VLAN
    # sw1-modem - Root switch
    elif switch_key == "sw1-modem":
        if vlan_id == 10:  # Gaming (printer P2, Deco P3)
            port_config = {1: 1, 2: 0, 3: 1, 4: 1, 5: 1}
        elif vlan_id == 99:  # Management
            port_config = {1: 1, 2: 2, 3: 1, 4: 1, 5: 1}
        else:
            # Other VLANs - trunk ports tagged
            for p in trunk_ports:
                port_config[p] = 1

    # sw2-tv - Only carries VLANs 99, 30, 60
    elif switch_key == "sw2-tv":
        if vlan_id in [99, 30, 60]:
            for p in trunk_ports:
                port_config[p] = 1
            port_config[2] = 1  # Nexus trunk

    # sw3-upstairs - Distribution switch
    elif switch_key == "sw3-upstairs":
        for p in trunk_ports:
            port_config[p] = 1
        # Sentry (P4) and Forge (P5)
        if vlan_id == 99:
            port_config[4] = 1  # Sentry
            port_config[5] = 1  # Forge
        elif vlan_id == 40:  # Mining
            port_config[4] = 1  # Sentry
            port_config[5] = 1  # Forge
        elif vlan_id == 50:  # Monitoring
            port_config[4] = 1  # Sentry
        elif vlan_id == 20:  # AI
            port_config[5] = 1  # Forge

    # sw4-zephyr - End switch
    elif switch_key == "sw4-zephyr":
        for p in trunk_ports:
            port_config[p] = 1
        # Zephyr on port 5
        if vlan_id in [99, 10, 20]:
            port_config[5] = 1  # Zephyr trunk

    return port_config


def configure_switch(switch_key, switch_config, enable_only=False, create_vlans=False):
    """Configure a single switch"""
    ip = switch_config["ip"]
    name = switch_config["name"]

    print(f"\n{'='*60}")
    print(f"Configuring: {name} ({ip})")
    print(f"{'='*60}\n")

    api = SwitchVLANAPI(ip, USERNAME, PASSWORD, name)

    # Login
    if not api.login():
        return False

    # Enable 802.1Q
    if not api.enable_8021q():
        return False

    if enable_only:
        return True

    if create_vlans:
        switch_vlans = switch_config.get("vlans", ["all"])

        # Create each VLAN
        for vlan in VLANS:
            vlan_id = vlan["id"]
            vlan_name = vlan["name"]

            # Check if this switch should have this VLAN
            if switch_vlans != "all" and vlan_id not in switch_vlans:
                print(f"  → Skipping VLAN {vlan_id} (not configured for this switch)")
                continue

            # Get port configuration
            port_config = get_port_config_for_switch(switch_key, vlan_id)

            # Create the VLAN
            if not api.create_vlan(vlan_id, vlan_name, port_config):
                print(f"  ! Continuing anyway...")

    return True


def main():
    parser = argparse.ArgumentParser(description="TP-Link Switch 802.1Q VLAN API Configuration")
    parser.add_argument("--enable", action="store_true", help="Enable 802.1Q on all switches")
    parser.add_argument("--disable", action="store_true", help="Disable 802.1Q on all switches")
    parser.add_argument("--create-vlans", action="store_true", help="Create all VLANs on all switches")
    parser.add_argument("--status", action="store_true", help="Show VLAN status")
    parser.add_argument("--switch", help="Configure only this switch (e.g., sw1-modem)")
    parser.add_argument("--all", action="store_true", help="Run full configuration")

    args = parser.parse_args()

    if not any([args.enable, args.disable, args.create_vlans, args.status, args.all]):
        parser.print_help()
        sys.exit(1)

    print("="*60)
    print("TP-Link Switch 802.1Q VLAN API Configuration")
    print("="*60)

    # Filter switches if --switch specified
    switches_to_config = SWITCHES
    if args.switch:
        if args.switch not in SWITCHES:
            print(f"Error: Unknown switch '{args.switch}'")
            print(f"Valid switches: {', '.join(SWITCHES.keys())}")
            sys.exit(1)
        switches_to_config = {args.switch: SWITCHES[args.switch]}

    # Process each switch
    for key, config in switches_to_config.items():
        if args.enable or args.all:
            configure_switch(key, config, enable_only=(not args.create_vlans and not args.all))

        elif args.disable:
            api = SwitchVLANAPI(config["ip"], USERNAME, PASSWORD, config["name"])
            api.login()
            api.disable_8021q()

        elif args.create_vlans:
            configure_switch(key, config, create_vlans=True)

        elif args.status:
            api = SwitchVLANAPI(config["ip"], USERNAME, PASSWORD, config["name"])
            api.login()
            api.get_vlan_status()

    print("\n" + "="*60)
    print("Done!")
    print("="*60)


if __name__ == "__main__":
    main()
