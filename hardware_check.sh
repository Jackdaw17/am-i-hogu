#!/usr/bin/env bash
# New PC hardware check (for Ubuntu "Try Ubuntu" live session)
# Usage: sudo bash hardware_check.sh
set -u

HOURS_LIMIT=4   # power-on hours above this get a warning

if [ "$(id -u)" -ne 0 ]; then
  echo "Root needed. Run it like this: sudo bash $0"
  exit 1
fi

# Save the report next to this script (survives reboot when the script is on a USB stick).
# Fall back to the home folder if that place is not writable.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$SCRIPT_DIR/hardware_report_$STAMP.txt"
if ! touch "$REPORT" 2>/dev/null; then
  REPORT="/home/${SUDO_USER:-ubuntu}/hardware_report_$STAMP.txt"
fi
exec > >(tee "$REPORT") 2>&1

section() { echo; echo "==================== $1 ===================="; }

# ---- 0. Install tools ----
need=()
command -v smartctl  >/dev/null || need+=(smartmontools)
command -v dmidecode >/dev/null || need+=(dmidecode)
if [ ${#need[@]} -gt 0 ]; then
  echo "Installing: ${need[*]}"
  apt-get update -qq && apt-get install -y -qq "${need[@]}" \
    || echo "!! Install failed. Check the internet connection. Disk section may be empty."
fi

# ---- 1. Disk usage history ----
section "1. DISK HISTORY (new: power-on 0-${HOURS_LIMIT}h, almost nothing written)"
for dev in /dev/nvme[0-9]n1 /dev/sd[a-z]; do
  [ -b "$dev" ] || continue
  model=$(lsblk -dno MODEL "$dev" 2>/dev/null | xargs)
  if [ "$(lsblk -dno TRAN "$dev" 2>/dev/null)" = "usb" ]; then
    echo "--- $dev ($model): USB device, skipped (probably the live USB)"
    continue
  fi
  echo "--- $dev"
  out=$(smartctl -a "$dev" 2>/dev/null)
  echo "$out" | grep -E "^(Model Number|Device Model|Serial Number|Firmware Version|Total NVM Capacity|User Capacity):"
  echo "$out" | grep -E "^(Power On Hours|Power Cycles|Data Units Written|Data Units Read|Unsafe Shutdowns|Percentage Used|Media and Data Integrity Errors):"
  echo "$out" | awk '$2 ~ /^(Power_On_Hours|Power_Cycle_Count|Total_LBAs_Written|Reallocated_Sector_Ct)$/ {print $2": "$10}'

  hours=$(echo "$out" | awk -F: '/^Power On Hours/ {gsub(/[ ,]/,"",$2); print $2}')
  [ -z "$hours" ] && hours=$(echo "$out" | awk '$2=="Power_On_Hours" {print $10}' | grep -oE '^[0-9]+')
  if [ -z "$hours" ]; then
    echo "  [?] Could not read power-on hours for this disk"
  elif [ "$hours" -gt "$HOURS_LIMIT" ]; then
    echo "  [!] Power-on ${hours}h: more than the ${HOURS_LIMIT}h limit"
  else
    echo "  [OK] Power-on ${hours}h: within ${HOURS_LIMIT}h"
  fi
done

# ---- 2. CPU / GPU ----
section "2. CPU / GPU"
lscpu | grep -E "^Model name|^CPU\(s\)"
lspci | grep -Ei "vga|3d controller|display"

# ---- 3. Motherboard ----
section "3. MOTHERBOARD (compare serial with the box sticker)"
dmidecode -t baseboard | grep -E "Manufacturer|Product Name|Version|Serial Number"
echo "BIOS version: $(dmidecode -s bios-version)  /  date: $(dmidecode -s bios-release-date)"

# ---- 4. RAM ----
section "4. RAM (per slot)"
dmidecode -t 17 | awk -F': ' '
function flush() {
  if (size != "" && size !~ /No Module/)
    printf "  %-14s %-7s %-5s rated %-11s running %-11s maker %s / part %s / SN %s\n", loc, size, type, spd, cfg, mfr, part, sn
  size = loc = type = spd = cfg = mfr = part = sn = ""
}
/^Memory Device/ { flush() }
{ sub(/^[ \t]+/, "") }
$1 == "Size"                    { size = $2 }
$1 == "Locator"                 { loc  = $2 }
$1 == "Type"                    { type = $2 }
$1 == "Speed"                   { spd  = $2 }
$1 == "Configured Memory Speed" { cfg  = $2 }
$1 == "Manufacturer"            { mfr  = $2 }
$1 == "Part Number"             { part = $2 }
$1 == "Serial Number"           { sn   = $2 }
END { flush() }'
free -h | awk 'NR==2 {print "  Total memory seen: "$2}'

# ---- 5. Visual check ----
section "5. VISUAL CHECK (power off, check by eye)"
echo "  [ ] Seal stickers intact"
echo "  [ ] GPU gold fingers: scratches? Heatsink: dust?"
echo "  [ ] PSU / case screws: marks from being opened many times?"

chown "${SUDO_USER:-ubuntu}": "$REPORT" 2>/dev/null
echo
echo "Report saved: $REPORT"
