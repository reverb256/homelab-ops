#!/usr/bin/env python3
"""
Switch IP Reassignment Script

Reassigns switch IPs to sequential addresses:
- sw1-modem (MAC 8C:90:2D:AE:4D:27): 10.1.1.12 → 10.1.1.10
- sw3-upstairs (MAC 60:83:E7:F7:F4:6C): 10.1.1.95 → 10.1.1.12

Strategy:
1. First change sw1-modem from .12 to .10
2. Then change sw3-upstairs from .95 to .12

Uses curl to POST to TP-Link switch API endpoints.
"""

import subprocess
import time
import sys

SWITCHES = {
    "sw1-modem": {
        "current_ip": "10.1.1.12",
        "new_ip": "10.1.1.10",
        "mac": "8C:90:2D:AE:4D:27",
        "username": "admin",
        "password": "ee80cb9718",
    },
    "sw3-upstairs": {
        "current_ip": "10.1.1.95",
        "new_ip": "10.1.1.12",
        "mac": "60:83:E7:F7:F4:6C",
        "username": "admin",
        "password": "ee80cb9718",
    },
}

def set_switch_ip(switch_name, switch_config):
    """Set static IP on a TP-Link switch using curl"""
    current_ip = switch_config["current_ip"]
    new_ip = switch_config["new_ip"]
    username = switch_config["username"]
    password = switch_config["password"]

    print(f"\n{'='*60}")
    print(f"Configuring: {switch_name}")
    print(f"  Current IP: {current_ip}")
    print(f"  New IP: {new_ip}")
    print(f"{'='*60}")

    # First, login to get session cookie
    login_cmd = [
        "curl", "-s", "-c", "/tmp/tp-link-cookies.txt",
        f"http://{current_ip}/login.cgi",
        "-d", f"username={username}",
        "-d", f"password={password}",
    ]

    print(f"  → Logging in to {current_ip}...")
    result = subprocess.run(login_cmd, capture_output=True, text=True)

    if "logon" in result.stdout or result.returncode != 0:
        print(f"  ✗ Login failed")
        return False

    print(f"  ✓ Login successful")

    # Wait a moment for session to establish
    time.sleep(1)

    # Now set the IP address
    ip_cmd = [
        "curl", "-s", "-b", "/tmp/tp-link-cookies.txt",
        f"http://{current_ip}/IpSettingRpm.htm",
        "-d", "dhcpConfig=Disable",
        "-d", f"ip={new_ip}",
        "-d", "mask=255.255.255.0",
        "-d", "gateway=10.1.1.1",
    ]

    print(f"  → Setting IP to {new_ip}...")
    result = subprocess.run(ip_cmd, capture_output=True, text=True)

    if "error" in result.stdout.lower() or result.returncode != 0:
        print(f"  ✗ IP change failed")
        print(f"  Output: {result.stdout}")
        return False

    print(f"  ✓ IP change initiated")

    # Wait for the switch to apply the change
    print(f"  → Waiting for switch to apply changes...")
    time.sleep(5)

    # Test connectivity at the new IP
    print(f"  → Testing connectivity at {new_ip}...")
    test_cmd = ["curl", "-s", f"http://{new_ip}/", "--max-time", "3"]
    result = subprocess.run(test_cmd, capture_output=True, text=True)

    if result.returncode == 0:
        print(f"  ✓ Switch is responding at {new_ip}")
        return True
    else:
        print(f"  ! Switch not yet reachable at {new_ip} (may need reboot)")
        return False

def main():
    print("="*60)
    print("Switch IP Reassignment")
    print("="*60)

    # Step 1: Change sw1-modem from .12 to .10
    print("\nStep 1: Move sw1-modem (.12 → .10)")
    sw1_result = set_switch_ip("sw1-modem", SWITCHES["sw1-modem"])

    if sw1_result:
        print("\n✓ sw1-modem successfully moved to 10.1.1.10")
        print("  Waiting 10 seconds before proceeding...")
        time.sleep(10)
    else:
        print("\n✗ sw1-modem IP change may not have worked")
        print("  Manual intervention may be required")
        response = input("\nContinue with sw3-upstairs? (y/n): ")
        if response.lower() != 'y':
            print("Aborted.")
            sys.exit(1)

    # Step 2: Change sw3-upstairs from .95 to .12
    print("\nStep 2: Move sw3-upstairs (.95 → .12)")
    sw3_result = set_switch_ip("sw3-upstairs", SWITCHES["sw3-upstairs"])

    print("\n" + "="*60)
    print("Summary:")
    print("="*60)
    print(f"  sw1-modem: {'✓ Success' if sw1_result else '! May need manual check'}")
    print(f"  sw3-upstairs: {'✓ Success' if sw3_result else '! May need manual check'}")
    print()
    print("Expected final state:")
    print("  sw1-modem:    10.1.1.10")
    print("  sw2-tv:       10.1.1.11 (unchanged)")
    print("  sw3-upstairs: 10.1.1.12")
    print("  sw4-zephyr:   10.1.1.13 (unchanged)")
    print("="*60)

if __name__ == "__main__":
    main()
