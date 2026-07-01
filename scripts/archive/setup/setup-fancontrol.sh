#!/usr/bin/env bash
# Setup script for pwmconfig on MSI X570 TOMAHAWK
# WARNING: This temporarily disables BIOS fan control

set -e

HWMON="/sys/class/hwmon/hwmon6"

echo "=========================================="
echo "Fan Control Setup for MSI X570 TOMAHAWK"
echo "=========================================="
echo ""
echo "This script will:"
echo "1. Switch fans from BIOS auto mode to manual mode"
echo "2. Run pwmconfig to detect fans and set up curves"
echo "3. Start fancontrol service"
echo ""
echo "WARNING: Fans will briefly stop during detection!"
echo "Press Ctrl+C to cancel, or Enter to continue..."
read

echo ""
echo "Step 1: Switching PWM to manual mode..."
for i in 1 2 3 4 5 6 7; do
  mode_file="$HWMON/pwm${i}_mode"
  if [ -f "$mode_file" ]; then
    current=$(cat "$mode_file")
    if [ "$current" = "1" ]; then
      echo "  PWM $i: switching from auto to manual"
      echo 0 > "$mode_file"
    else
      echo "  PWM $i: already in manual mode"
    fi
  fi
done

echo ""
echo "Step 2: Running pwmconfig..."
echo "Follow the prompts to identify your fans."
echo ""

sudo pwmconfig

echo ""
echo "Step 3: Starting fancontrol service..."
sudo systemctl start fancontrol.service
sudo systemctl status fancontrol.service --no-pager

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Useful commands:"
echo "  fan-get        - Check current fan speeds"
echo "  temp-get       - Check temperatures"
echo "  systemctl status fancontrol - Check service"
echo ""
echo "To adjust fan curves, edit /etc/fancontrol and reload:"
echo "  sudo systemctl restart fancontrol"
