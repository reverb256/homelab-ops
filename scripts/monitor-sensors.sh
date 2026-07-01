#!/usr/bin/env bash
# Comprehensive sensor monitoring for MSI X570 TOMAHAWK
# Shows CPU, GPU, Motherboard, NVMe, and Fan status

clear
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║           MSI X570 TOMAHAWK - Sensor Monitor                     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

HWMON="/sys/class/hwmon/hwmon6"

while true; do
    clear
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           MSI X570 TOMAHAWK - Sensor Monitor                     ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} System Status"
    echo "─────────────────────────────────────────────────────────────────"

    # CPU Temps
    tctl=$(cat $HWMON/temp13_input 2>/dev/null | awk '{printf "%.1f", $1/1000}')
    cputin=$(cat $HWMON/temp2_input 2>/dev/null | awk '{printf "%.1f", $1/1000}')
    systin=$(cat $HWMON/temp1_input 2>/dev/null | awk '{printf "%.1f", $1/1000}')

    # Color based on temp
    if (( $(echo "$tctl > 80" | bc -l) )); then
        cpu_color=$RED
    elif (( $(echo "$tctl > 65" | bc -l) )); then
        cpu_color=$YELLOW
    else
        cpu_color=$GREEN
    fi

    echo -e "  CPU (Core):    ${cpu_color}${tctl}°C${NC}  (Socket: ${cputin}°C)"
    echo -e "  System:        ${systin}°C"

    # NVMe temps
    nvme1=$(cat /sys/class/hwmon/hwmon0/temp1_input 2>/dev/null | awk '{printf "%.1f", $1/1000}')
    nvme2=$(cat /sys/class/hwmon/hwmon1/temp1_input 2>/dev/null | awk '{printf "%.1f", $1/1000}')
    echo -e "  NVMe:          ${nvme1}°C  ${nvme2}°C"

    echo ""
    echo -e "${CYAN}GPU Status${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    nvidia-smi --query-gpu=index,name,temperature.gpu,fan.speed,power.draw,enforced.power.limit,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | while IFS=, read -r idx name temp fan power plimit util; do
        temp=$(echo $temp | tr -d ' ')
        fan=$(echo $fan | tr -d ' ')
        power=$(echo $power | tr -d ' ')
        plimit=$(echo $plimit | tr -d ' ')
        util=$(echo $util | tr -d ' ')

        if (( temp > 80 )); then
            gpu_color=$RED
        elif (( temp > 65 )); then
            gpu_color=$YELLOW
        else
            gpu_color=$GREEN
        fi

        printf "  GPU %s: ${gpu_color}%s°C${NC}  Fan: %3s%%  Power: %3sW/%sW  Load: %s%%\n" "$idx" "$temp" "$fan" "$power" "$plimit" "$util"
        echo "         $name"
    done

    echo ""
    echo -e "${CYAN}AIO Cooler Status${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    if command -v liquidctl &>/dev/null; then
        # Get AIO status - need to stop OpenRGB temporarily if running
        OPENRGB_RUNNING=false
        if systemctl is-active --quiet openrgb 2>/dev/null; then
            systemctl stop openrgb 2>/dev/null
            OPENRGB_RUNNING=true
            sleep 0.5
        fi

        # Get liquid temp and pump speed - use sed to clean Unicode and extract values
        aio_output=$(liquidctl --match "Hydro" status 2>/dev/null)
        liquid_temp=$(echo "$aio_output" | grep "Liquid temperature" | sed 's/[^0-9.]//g' | awk '{printf "%.1f", $1}')
        pump_speed=$(echo "$aio_output" | grep "Pump speed" | grep -oE '[0-9]{2,5}' | head -1)

        # Restart OpenRGB if it was running
        if [ "$OPENRGB_RUNNING" = true ]; then
            systemctl start openrgb 2>/dev/null
        fi

        if [ -n "$liquid_temp" ]; then
            if (( $(echo "$liquid_temp > 45" | bc -l) )); then
                aio_color=$RED
            elif (( $(echo "$liquid_temp > 38" | bc -l) )); then
                aio_color=$YELLOW
            else
                aio_color=$GREEN
            fi
            echo -e "  Liquid Temp:  ${aio_color}${liquid_temp}°C${NC}"
            echo -e "  Pump Speed:   ${pump_speed} RPM"
        else
            echo -e "  ${YELLOW}AIO not detected${NC}"
        fi
    else
        echo -e "  ${YELLOW}liquidctl not available${NC}"
    fi

    echo ""
    echo -e "${CYAN}Fan Status${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    printf "  %-10s  %6s  %5s  %6s\n" "Fan" "RPM" "PWM" "Percent"
    echo "  ───────────────────────────────────────────────────────────"

    for i in {1..7}; do
        rpm=$(cat $HWMON/fan${i}_input 2>/dev/null || echo "0")
        pwm=$(cat $HWMON/pwm${i} 2>/dev/null || echo "0")
        pct=$((pwm * 100 / 255))
        label=$(cat $HWMON/fan${i}_label 2>/dev/null || echo "Fan$i")

        # Color based on PWM
        if (( pct > 80 )); then
            fan_color=$RED
        elif (( pct > 50 )); then
            fan_color=$YELLOW
        else
            fan_color=$NC
        fi

        printf "  %-10s: %6d  ${fan_color}%5d${NC}  %6d%%\n" "$label" "$rpm" "$pwm" "$pct"
    done

    echo ""
    echo -e "${BLUE}Press Ctrl+C to exit${NC}"
    sleep 3
done
