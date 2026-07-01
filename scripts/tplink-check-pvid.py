#!/usr/bin/env python3
"""Check current PVID settings on TP-Link switch"""

import requests
from requests.auth import HTTPBasicAuth
import re

SWITCH_IP = "10.1.1.13"
USERNAME = "admin"
PASSWORD = "ee80cb9718"

def check_pvid_settings():
    """Check current PVID configuration"""
    print(f"Checking PVID settings on {SWITCH_IP}...")

    session = requests.Session()
    session.auth = HTTPBasicAuth(USERNAME, PASSWORD)

    try:
        # Get the 802.1Q PVID Setting page
        response = session.get(
            f"http://{SWITCH_IP}/qvlanPvidSet.cgi",
            timeout=10
        )
        response.raise_for_status()

        content = response.text

        # Extract PVID information from HTML
        print("\nCurrent PVID Settings:")
        print("-" * 40)

        # Look for PVID settings in the page
        # Pattern: pvid_<port> value
        pvid_pattern = r'name="pvid_(\d)"\s+value="(\d+)"'
        matches = re.findall(pvid_pattern, content)

        if matches:
            for port, pvid in matches:
                print(f"  Port {port}: PVID = {pvid}")
        else:
            print("  Could not parse PVID settings from page")
            print("  All ports likely at default PVID = 1")

        # Also check for JavaScript data structures
        if "pvids" in content or "PVID" in content:
            print("\n  PVID configuration page accessible")
        else:
            print("\n  ⚠ PVID configuration page may not be loading properly")

        return matches

    except Exception as e:
        print(f"Error checking PVID: {e}")
        return None


def explain_pvid_lockout():
    """Explain why PVID change caused lockout"""
    print("\n" + "="*60)
    print("PVID LOCKOUT ANALYSIS")
    print("="*60)
    print("""
WHY PVID 1→99 CAUSED LOCKOUT:

1. Management Interface Behavior:
   - TP-Link switch web UI (HTTP) operates on the native/untagged VLAN
   - By default, this is VLAN 1 (the factory default)
   - The management CPU expects untagged traffic on VLAN 1

2. What Happened When PVID Changed to 99:
   - Port's PVID changed from 1 to 99
   - Untagged traffic from switch CPU now gets tagged with VLAN 99
   - Your computer is on VLAN 1 (or sending untagged frames)
   - Mismatch: Switch sends VLAN 99 tagged, your PC expects untagged/VLAN 1
   - Result: Complete communication failure

3. The Critical Detail:
   - Switch management interface itself stays on VLAN 1 internally
   - But the PORT you're connected to tags everything as VLAN 99
   - Unless your device is configured for VLAN 99, it can't communicate

4. Why Factory Reset Was Needed:
   - No way to access web UI to change PVID back
   - Console port might have worked (if available)
   - Factory reset was the only recovery option

SAFE APPROACH FOR PVID CONFIGURATION:

✓ DO: Change PVID on ports that connect to END DEVICES
        (if those devices are configured for that VLAN)

✗ DON'T: Change PVID on ports that connect to:
        - Your management computer
        - Other switches (unless planning trunk configuration)
        - Any device you need to manage the switch through

RECOMMENDATION:
Keep PVID = 1 for management access. Use tagged VLANs for segmentation.
Only change PVID on specific access ports where needed.
""")

if __name__ == "__main__":
    check_pvid_settings()
    explain_pvid_lockout()
