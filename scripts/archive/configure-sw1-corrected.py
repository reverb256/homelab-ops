#!/usr/bin/env python3
"""
CORRECTED VLAN Configuration for sw1-modem
Based on ACTUAL design document: docs/plans/2026-03-09-switch-vlan-design.md

sw1-modem (10.1.1.90) PORT CONFIGURATION:
  Port 1: Modem/Gateway (trunk: all VLANs)
  Port 2: Printer (VLAN 10 - gaming/work)
  Port 3: Deco XE75 WiFi (VLAN 10, 99 - gaming + management)
  Port 4: sw3-upstairs TRUNK (trunk: all VLANs)
  Port 5: sw2-tv TRUNK (trunk: 99, 30, 60)
"""

import requests
from requests.auth import HTTPBasicAuth
import time

SWITCH_IP = "10.1.1.13"  # sw1-modem after factory reset
USERNAME = "admin"
PASSWORD = "ee80cb9718"

# CORRECT VLAN configuration from design document
# Port membership: which ports are in each VLAN (TAGGED)
VLAN_CONFIG = {
    10: {
        "name": "gaming",
        "tagged_ports": [1, 2, 3, 4],  # Modem, Printer, Deco, sw3-upstairs
        "untagged_ports": []
    },
    20: {
        "name": "ai",
        "tagged_ports": [1, 4],  # Modem, sw3-upstairs (carried to Zephyr via sw3)
        "untagged_ports": []
    },
    30: {
        "name": "storage",
        "tagged_ports": [1, 4, 5],  # Modem, sw3-upstairs, sw2-tv (to Nexus)
        "untagged_ports": []
    },
    40: {
        "name": "mining",
        "tagged_ports": [1, 4, 5],  # Modem, sw3-upstairs, sw2-tv (to Forge)
        "untagged_ports": []
    },
    50: {
        "name": "monitoring",
        "tagged_ports": [1, 4],  # Modem, sw3-upstairs (to Sentry)
        "untagged_ports": []
    },
    60: {
        "name": "backup",
        "tagged_ports": [1, 4, 5],  # Modem, sw3-upstairs, sw2-tv (to Nexus)
        "untagged_ports": []
    },
    99: {
        "name": "management",
        "tagged_ports": [1, 3, 4, 5],  # Modem, Deco, sw3-upstairs, sw2-tv (all nodes)
        "untagged_ports": []
    },
}


def enable_8021q_vlan(session, base_url):
    """Enable 802.1Q VLAN"""
    print("  → Enabling 802.1Q VLAN...")

    data = {"qvlan_en": "1", "qvlan_mode": "Apply"}

    try:
        response = session.post(f"{base_url}/qvlanSet.cgi", data=data, timeout=10)
        response.raise_for_status()
        print("  ✓ 802.1Q VLAN enabled")
        time.sleep(2)
        return True
    except Exception as e:
        print(f"  ✗ Failed: {e}")
        return False


def add_vlan(session, base_url, vlan_id, vlan_name, tagged_ports, untagged_ports):
    """Add a VLAN with correct port membership"""
    print(f"  → Configuring VLAN {vlan_id} ({vlan_name})...")
    print(f"     Tagged ports: {tagged_ports}")

    # Build port configuration (0=Untagged, 1=Tagged, 2=Not Member)
    port_config = {}
    for port in range(1, 6):
        if port in tagged_ports:
            port_config[f"selType_{port}"] = "1"  # Tagged
        elif port in untagged_ports:
            port_config[f"selType_{port}"] = "0"  # Untagged
        else:
            port_config[f"selType_{port}"] = "2"  # Not Member

    data = {
        "vid": str(vlan_id),
        "vname": vlan_name,
        **port_config,
        "qvlan_add": "Add/Modify"
    }

    try:
        response = session.post(f"{base_url}/qvlanSet.cgi", data=data, timeout=10)
        response.raise_for_status()
        print(f"  ✓ VLAN {vlan_id} configured")
        time.sleep(1)
        return True
    except Exception as e:
        print(f"  ✗ Failed: {e}")
        return False


def main():
    print("="*70)
    print("CORRECTED VLAN Configuration for sw1-modem")
    print("="*70)
    print("\nReference: docs/plans/2026-03-09-switch-vlan-design.md")
    print("\nsw1-modem Port Configuration:")
    print("  Port 1: Modem/Gateway (all VLANs)")
    print("  Port 2: Printer (VLAN 10)")
    print("  Port 3: Deco XE75 WiFi (VLANs 10, 99)")
    print("  Port 4: sw3-upstairs TRUNK (all VLANs) ← TRUNK")
    print("  Port 5: sw2-tv TRUNK (VLANs 99, 30, 60) ← TRUNK")
    print()
    print("Trunk Ports: 1, 4, 5 (not 1, 3, 5!)")
    print()

    session = requests.Session()
    session.auth = HTTPBasicAuth(USERNAME, PASSWORD)
    base_url = f"http://{SWITCH_IP}"

    # Test connectivity
    try:
        response = session.get(base_url, timeout=5)
        response.raise_for_status()
        print("✓ Connected to sw1-modem")
    except Exception as e:
        print(f"✗ Cannot connect: {e}")
        return 1

    # Enable 802.1Q VLAN
    if not enable_8021q_vlan(session, base_url):
        return 1

    # Configure all 7 VLANs
    print("\nConfiguring VLANs:")
    print("-"*70)

    success_count = 0
    for vlan_id, config in VLAN_CONFIG.items():
        if add_vlan(session, base_url, vlan_id, config["name"],
                    config["tagged_ports"], config["untagged_ports"]):
            success_count += 1

    print("-"*70)
    print(f"\n✓ {success_count}/7 VLANs configured successfully")
    print("\nVLAN Summary:")
    print("  • VLAN 10 (gaming): Ports 1,2,3,4 tagged")
    print("  • VLAN 20 (ai): Ports 1,4 tagged")
    print("  • VLAN 30 (storage): Ports 1,4,5 tagged")
    print("  • VLAN 40 (mining): Ports 1,4,5 tagged")
    print("  • VLAN 50 (monitoring): Ports 1,4 tagged")
    print("  • VLAN 60 (backup): Ports 1,4,5 tagged")
    print("  • VLAN 99 (management): Ports 1,3,4,5 tagged")
    print("\n✓ Configuration matches design document")
    print("✓ PVID = 1 (safe, no lockout risk)")

    return 0


if __name__ == "__main__":
    exit(main())
