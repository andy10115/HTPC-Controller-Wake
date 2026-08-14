#!/bin/bash
# check-wakeup-status.sh
#
# Diagnostic tool for HTPC Controller Wake.

set -u

RULE_FILE="${HTPC_WAKE_RULE_FILE:-/etc/udev/rules.d/99-controller-wakeup.rules}"
LIB_DIR="${HTPC_WAKE_LIB_DIR:-/usr/local/lib/htpc-controller-wake}"
HELPER_DEST="$LIB_DIR/enable-usb-wakeup.sh"
SETUP_DEST="${HTPC_WAKE_SETUP_DEST:-/usr/local/bin/htpc-controller-wake-setup}"
STATUS_DEST="${HTPC_WAKE_STATUS_DEST:-/usr/local/bin/htpc-controller-wake-status}"
UNINSTALL_DEST="${HTPC_WAKE_UNINSTALL_DEST:-/usr/local/bin/htpc-controller-wake-uninstall}"
SYSFS_ROOT="${HTPC_WAKE_SYSFS_ROOT:-/sys}"
USB_DEVICES_DIR="$SYSFS_ROOT/bus/usb/devices"

print_header() {
    echo "=========================================="
    echo " HTPC Controller Wake Status"
    echo "=========================================="
    echo
}

show_usb_chain() {
    local start="$1"
    local current subsystem wake label vid pid product

    current="$(readlink -f "$start" 2>/dev/null || true)"
    [[ -n "$current" ]] || return 1

    while [[ "$current" == "$SYSFS_ROOT"/* && "$current" != "$SYSFS_ROOT" ]]; do
        subsystem=""
        [[ -L "$current/subsystem" ]] && subsystem="$(basename "$(readlink -f "$current/subsystem")")"

        if [[ "$subsystem" == "usb" ]]; then
            wake="n/a"
            [[ -e "$current/power/wakeup" ]] && wake="$(cat "$current/power/wakeup" 2>/dev/null || echo unreadable)"

            vid=""; pid=""; product=""
            [[ -f "$current/idVendor" ]] && read -r vid < "$current/idVendor" || true
            [[ -f "$current/idProduct" ]] && read -r pid < "$current/idProduct" || true
            [[ -f "$current/product" ]] && read -r product < "$current/product" || true

            label="$(basename "$current")"
            [[ -n "$product" ]] && label="$product ($label)"
            if [[ -n "$vid" && -n "$pid" ]]; then
                printf '    %-38s %s:%s  wakeup=%s\n' "$label" "$vid" "$pid" "$wake"
            else
                printf '    %-49s wakeup=%s\n' "$label" "$wake"
            fi
        fi

        current="$(dirname "$current")"
    done
}

print_header

echo "Installed components:"
printf '  %-10s %s\n' "Rule:" "$([[ -f "$RULE_FILE" ]] && echo yes || echo no)"
printf '  %-10s %s\n' "Helper:" "$([[ -x "$HELPER_DEST" ]] && echo yes || echo no)"
printf '  %-10s %s\n' "Setup:" "$([[ -x "$SETUP_DEST" ]] && echo yes || echo no)"
printf '  %-10s %s\n' "Status:" "$([[ -x "$STATUS_DEST" ]] && echo yes || echo no)"
printf '  %-10s %s\n' "Uninstall:" "$([[ -x "$UNINSTALL_DEST" ]] && echo yes || echo no)"
echo

if [[ -f "$RULE_FILE" ]]; then
    echo "--------------------------------------------"
    echo "Installed udev rule:"
    echo "--------------------------------------------"
    cat "$RULE_FILE"
    echo
else
    echo "No wake rule is installed."
    if [[ -x "$SETUP_DEST" ]]; then
        echo "Run: htpc-controller-wake-setup"
    else
        echo "Run setup-controller-wakeup.sh from the repository or use the one-line installer."
    fi
    echo
fi

echo "--------------------------------------------"
echo "Configured device matches currently present:"
echo "--------------------------------------------"

found_config=0
controller_regex='^#[[:space:]]+(.+)[[:space:]]+\(([[:xdigit:]]{4}):([[:xdigit:]]{4})\)$'
path_regex='^#[[:space:]]+Device[[:space:]]+path:[[:space:]]+([^[:space:]]+)$'
targets_regex='^#[[:space:]]+Wake[[:space:]]+targets:[[:space:]]+(.+)$'
legacy_rule_regex='ATTR\{idVendor\}=="([[:xdigit:]]{4})".*ATTR\{idProduct\}=="([[:xdigit:]]{4})"'

declare -a CFG_NAME=()
declare -a CFG_VID=()
declare -a CFG_PID=()
declare -a CFG_PATH=()
declare -a CFG_TARGETS=()

pending_name=""; pending_vid=""; pending_pid=""; pending_path=""; pending_targets=""
if [[ -f "$RULE_FILE" ]]; then
    while IFS= read -r rule_line; do
        if [[ "$rule_line" =~ $controller_regex ]]; then
            if [[ -n "$pending_vid" && -n "$pending_path" && -n "$pending_targets" ]]; then
                CFG_NAME+=("$pending_name")
                CFG_VID+=("$pending_vid")
                CFG_PID+=("$pending_pid")
                CFG_PATH+=("$pending_path")
                CFG_TARGETS+=("$pending_targets")
            fi
            pending_name="${BASH_REMATCH[1]}"
            pending_vid="${BASH_REMATCH[2],,}"
            pending_pid="${BASH_REMATCH[3],,}"
            pending_path=""
            pending_targets=""
            continue
        fi
        [[ "$rule_line" =~ $path_regex ]] && { pending_path="${BASH_REMATCH[1]}"; continue; }
        [[ "$rule_line" =~ $targets_regex ]] && { pending_targets="${BASH_REMATCH[1]}"; continue; }
    done < "$RULE_FILE"

    if [[ -n "$pending_vid" && -n "$pending_path" && -n "$pending_targets" ]]; then
        CFG_NAME+=("$pending_name")
        CFG_VID+=("$pending_vid")
        CFG_PID+=("$pending_pid")
        CFG_PATH+=("$pending_path")
        CFG_TARGETS+=("$pending_targets")
    fi
fi

if (( ${#CFG_VID[@]} > 0 )); then
    found_config=1
    for i in "${!CFG_VID[@]}"; do
        echo
        echo "  Configured VID:PID ${CFG_VID[$i]}:${CFG_PID[$i]}"
        dev="$USB_DEVICES_DIR/${CFG_PATH[$i]}"
        if [[ -e "$dev" ]]; then
            product="${CFG_NAME[$i]}"
            current_vid=""; current_pid=""
            [[ -f "$dev/product" ]] && read -r product < "$dev/product" || true
            [[ -f "$dev/idVendor" ]] && read -r current_vid < "$dev/idVendor" || true
            [[ -f "$dev/idProduct" ]] && read -r current_pid < "$dev/idProduct" || true
            if [[ -n "$current_vid" && -n "$current_pid" && ( "$current_vid" != "${CFG_VID[$i]}" || "$current_pid" != "${CFG_PID[$i]}" ) ]]; then
                echo "    $product (currently $current_vid:$current_pid at ${CFG_PATH[$i]})"
            else
                echo "    $product"
            fi
            show_usb_chain "$dev"
        else
            present_targets=0
            for target in ${CFG_TARGETS[$i]}; do
                wake_file="$USB_DEVICES_DIR/$target/power/wakeup"
                if [[ -e "$wake_file" ]]; then
                    present_targets=1
                    wakeup="$(cat "$wake_file" 2>/dev/null || echo unreadable)"
                    printf '    %-49s wakeup=%s\n' "$target" "$wakeup"
                fi
            done
            (( present_targets == 1 )) || echo "    Not currently connected."
        fi
    done
fi

# Backward-compatible diagnostics for the previous exact-VID:PID rule format.
if (( found_config == 0 )) && [[ -f "$RULE_FILE" ]]; then
    declare -A seen_pairs=()
    while IFS= read -r rule_line; do
        if [[ "$rule_line" =~ $legacy_rule_regex ]]; then
            vid="${BASH_REMATCH[1],,}"
            pid="${BASH_REMATCH[2],,}"
            pair="$vid:$pid"
            [[ -n "${seen_pairs[$pair]+x}" ]] && continue
            seen_pairs[$pair]=1
            found_config=1

            echo
            echo "  Configured VID:PID $pair"
            matches=0
            for dev in "$USB_DEVICES_DIR"/*; do
                [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
                read -r dvid < "$dev/idVendor" || continue
                read -r dpid < "$dev/idProduct" || continue
                if [[ "$dvid" == "$vid" && "$dpid" == "$pid" ]]; then
                    matches=1
                    product="Unknown USB device"
                    [[ -f "$dev/product" ]] && read -r product < "$dev/product" || true
                    echo "    $product"
                    show_usb_chain "$dev"
                fi
            done
            (( matches == 1 )) || echo "    Not currently connected."
        fi
    done < "$RULE_FILE"
fi

if (( found_config == 0 )); then
    echo "  No parseable configured controller rules found."
fi

echo
echo "--------------------------------------------"
echo "All USB device wakeup flags:"
echo "--------------------------------------------"
for dev in "$USB_DEVICES_DIR"/*; do
    [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
    read -r vid < "$dev/idVendor" || continue
    read -r pid < "$dev/idProduct" || continue
    name="Unknown USB device"
    [[ -f "$dev/product" ]] && read -r name < "$dev/product" || true
    wakeup="n/a"
    [[ -e "$dev/power/wakeup" ]] && wakeup="$(cat "$dev/power/wakeup" 2>/dev/null || echo unreadable)"
    printf '  %-34s %s:%s  wakeup=%s\n' "$name" "$vid" "$pid" "$wakeup"
done

echo
echo "--------------------------------------------"
echo "Suspend mode:"
echo "--------------------------------------------"
if [[ -f "$SYSFS_ROOT/power/mem_sleep" ]]; then
    cat "$SYSFS_ROOT/power/mem_sleep"
    echo "The bracketed value is active. 'deep' is suspend-to-RAM/S3 on ACPI systems;"
    echo "'s2idle' is suspend-to-idle. USB wake can work with either when supported."
else
    echo "Not available on this system."
fi

echo
echo "--------------------------------------------"
echo "ACPI USB host-controller wake sources:"
echo "--------------------------------------------"
if [[ -f /proc/acpi/wakeup ]]; then
    acpi_matches=0
    while IFS= read -r acpi_line; do
        acpi_lower="${acpi_line,,}"
        if [[ "$acpi_lower" == *xhc* || "$acpi_lower" == *ehc* || "$acpi_lower" == *usb* ]]; then
            echo "$acpi_line"
            acpi_matches=1
        fi
    done < /proc/acpi/wakeup
    (( acpi_matches == 1 )) || echo "No USB-related ACPI entries found."
    echo
    echo "A disabled XHC/EHC entry means that ACPI wake source is currently disabled;"
    echo "it does not by itself prove an unchangeable BIOS block. Firmware settings,"
    echo "kernel behavior, and platform support can still determine whether USB wake works."
else
    echo "Not available on this system."
fi

if command -v journalctl >/dev/null 2>&1; then
    echo
    echo "--------------------------------------------"
    echo "Recent helper log entries:"
    echo "--------------------------------------------"
    journalctl -t htpc-controller-wake -n 20 --no-pager 2>/dev/null || \
        echo "No readable journal entries found (or journal access is restricted)."
fi
