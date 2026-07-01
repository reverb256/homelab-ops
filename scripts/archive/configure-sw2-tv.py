#!/usr/bin/env python3
"""
Configure sw2-tv (10.1.1.11) with Specific 802.1Q VLAN Configuration
VLAN 99 (management): P1=Tagged, P2=Tagged, P3=NotMember, P4=NotMember, P5=NotMember
VLAN 30 (storage): P1=Tagged, P2=Tagged, P3=NotMember, P4=NotMember, P5=NotMember
VLAN 60 (backup): P1=Tagged, P2=Tagged, P3=NotMember, P4=NotMember, P5=NotMember
"""

import requests
from requests.auth import HTTPBasicAuth
import time

SWITCH_IP = "10.1.1.11"
SWITCH_NAME = "sw2-tv"
USERNAME = "admin"
PASSWORD = "ee80cb9718"

# VLAN Configuration
VLAN_CONFIG = {
    99: {"name": "management", "tagged": [1, 2], "untagged": []},
    30: {"name": "storage", "tagged": [1, 2], "untagged": []},
    60: {"name": "backup", "tagged": [1, 2], "untagged": []},
}


def enable_8021q_vlan(session, base_url):
    """Enable 802.1Q VLAN on the switch"""
    print("  → Enabling 802.1Q VLAN...")

    data = {"qvlan_en": "1", "qvlan_mode": "Apply"}

    try:
        response = session.post(f"{base_url}/qvlanSet.cgi", data=data, timeout=10)
        response.raise_for_status()
        print("  ✓ 802.1Q VLAN enabled")
        time.sleep(2)
        return True
    except Exception as e:
        print(f"  ✗ Failed to enable 802.1Q VLAN: {e}")
        return False


def add_vlan(session, base_url, vlan_id, vlan_name, tagged_ports, untagged_ports):
    """Add/Modify a VLAN with port membership"""
    print(f"  → Configuring VLAN {vlan_id} ({vlan_name})...")

    # Build port membership (0=Untagged, 1=Tagged, 2=Not Member)
    port_config = {}
    for port in range(1, 6):
        if port in tagged_ports:
            port_config[f"selType_{port}"] = "1"
        elif port in untagged_ports:
            port_config[f"selType_{port}"] = "0"
        else:
            port_config[f"selType_{port}"] = "2"

    data = {
        "vid": str(vlan_id),
        "vname": vlan_name,
        **port_config,
        "qvlan_add": "Add/Modify"
    }

    try:
        response = session.post(f"{base_url}/qvlanSet.cgi", data=data, timeout=10)
        response.raise_for_status()
        tagged_str = ",".join(map(str, tagged_ports)) if tagged_ports else "none"
        print(f"  ✓ VLAN {vlan_id}: Tagged=[{tagged_str}]")
        time.sleep(1)
        return True
    except Exception as e:
        print(f"  ✗ Failed to create VLAN {vlan_id}: {e}")
        return False


def configure_switch():
    """Configure VLANs on sw2-tv"""
    base_url = f"http://{SWITCH_IP}"

    print(f"{'='*60}")
    print(f"Configuring: {SWITCH_NAME} ({SWITCH_IP})")
    print(f"{'='*60}")

    # Create session
    session = requests.Session()
    session.auth = HTTPBasicAuth(USERNAME, PASSWORD)

    # Test connectivity
    try:
        response = session.get(base_url, timeout=5)
        if response.status_code == 401:
            print(f"  ✗ Authentication failed")
            return False
        response.raise_for_status()
    except Exception as e:
        print(f"  ✗ Cannot connect to switch: {e}")
        print(f"  ⚠ Switch may be offline or at wrong IP")
        return False

    print("  ✓ Connected to switch")

    # Enable 802.1Q VLAN
    if not enable_8021q_vlan(session, base_url):
        return False

    # Configure all VLANs
    success_count = 0
    for vlan_id, config in VLAN_CONFIG.items():
        if add_vlan(session, base_url, vlan_id, config["name"], config["tagged"], config["untagged"]):
            success_count += 1

    print(f"\n  ✓ {success_count}/{len(VLAN_CONFIG)} VLANs configured")

    # Summary
    print(f"\nConfiguration Summary for {SWITCH_NAME}:")
    print("  • 802.1Q VLAN: ENABLED")
    print("  • VLAN 99 (management): Tagged on ports 1,2; NotMember on 3,4,5")
    print("  • VLAN 30 (storage): Tagged on ports 1,2; NotMember on 3,4,5")
    print("  • VLAN 60 (backup): Tagged on ports 1,2; NotMember on 3,4,5")
    print("  ✓ Switch configured successfully")

    return success_count == len(VLAN_CONFIG)


def main():
    print("="*60)
    print(f"Configure {SWITCH_NAME} with 802.1Q VLAN")
    print("="*60)
    print()

    success = configure_switch()

    if success:
        print("\n✓ Switch configured successfully!")
        return 0
    else:
        print("\n✗ Configuration failed")
        print("\nTroubleshooting:")
        print("  • Check switch is powered on")
        print("  • Verify IP address: 10.1.1.11")
        print("  • Test connectivity: ping 10.1.1.11")
        print("  • Check credentials: admin / ee80cb9718")
        return 1


if __name__ == "__main__":
    exit(main())
