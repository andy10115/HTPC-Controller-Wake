#!/bin/bash
# setup-controller-wakeup.sh
#
# Interactively selects one or more USB controller receivers and installs a
# udev rule that enables wakeup for the exact VID:PID pair. The helper also
# enables wakeup on USB ancestors/hubs that expose power/wakeup.

set -euo pipefail

RULE_FILE="/etc/udev/rules.d/99-controller-wakeup.rules"
LIB_DIR="/usr/local/lib/htpc-controller-wake"
HELPER_DEST="$LIB_DIR/enable-usb-wakeup.sh"
SETUP_DEST="/usr/local/bin/htpc-controller-wake-setup"
STATUS_DEST="/usr/local/bin/htpc-controller-wake-status"
UNINSTALL_DEST="/usr/local/bin/htpc-controller-wake-uninstall"
DOC_DIR="/usr/local/share/doc/htpc-controller-wake"
LEGACY_HELPER="/usr/local/bin/enable-usb-wakeup.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_HELPER="$SCRIPT_DIR/bin/enable-usb-wakeup.sh"
SOURCE_STATUS="$SCRIPT_DIR/check-wakeup-status.sh"
SOURCE_UNINSTALL="$SCRIPT_DIR/uninstall.sh"
SOURCE_README="$SCRIPT_DIR/README.md"

# When launched from the permanent command, the support files are already
# installed. When launched from a checkout/tarball, these sources exist and
# are refreshed during setup.
RUNNING_FROM_SOURCE=0
[[ -f "$SOURCE_HELPER" && -f "$SOURCE_STATUS" && -f "$SOURCE_UNINSTALL" ]] && RUNNING_FROM_SOURCE=1

declare -a SEL_VID=()
declare -a SEL_PID=()
declare -a SEL_NAME=()

as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

need_command() {
    local cmd="$1"
    local hint="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' was not found."
        [[ -n "$hint" ]] && echo "$hint"
        exit 1
    fi
}

check_dependencies() {
    need_command lsusb "Install the 'usbutils' package, then run setup again."
    need_command udevadm "udevadm is required; install your distro's udev/systemd-udev package."
    need_command install "The standard 'install' utility (coreutils) is required."
    need_command readlink "The standard 'readlink' utility (coreutils) is required."

    if (( EUID != 0 )); then
        need_command sudo "Run this script as root or install/configure sudo."
    fi
}

get_devices() {
    # Root hubs are not useful choices and make the list noisier.
    local line lower
    while IFS= read -r line; do
        lower="${line,,}"
        [[ "$lower" == *"root hub"* ]] && continue
        printf '%s\n' "$line"
    done < <(lsusb)
}

parse_lsusb_line() {
    local line="$1"
    # Typical format:
    # Bus 001 Device 004: ID 2dc8:3106 8BitDo Ultimate 2 Wireless Controller
    if [[ "$line" =~ ^Bus[[:space:]]+([0-9]+)[[:space:]]+Device[[:space:]]+([0-9]+):[[:space:]]+ID[[:space:]]+([[:xdigit:]]{4}):([[:xdigit:]]{4})([[:space:]]+(.*))?$ ]]; then
        PARSED_VID="${BASH_REMATCH[3],,}"
        PARSED_PID="${BASH_REMATCH[4],,}"
        PARSED_NAME="${BASH_REMATCH[6]:-Unknown USB device}"
        return 0
    fi
    return 1
}

select_device() {
    local -a menu=()
    local line choice

    while IFS= read -r line; do
        [[ -n "$line" ]] && menu+=("$line")
    done < <(get_devices)

    if (( ${#menu[@]} == 0 )); then
        echo
        echo "No non-root-hub USB devices were found."
        echo "Make sure the controller receiver/dongle is plugged in, then try again."
        return 1
    fi

    while true; do
        echo
        echo "Connected USB devices:"
        echo
        local i
        for i in "${!menu[@]}"; do
            printf '  [%d] %s\n' "$i" "${menu[$i]}"
        done
        echo
        read -rp "Which number is your controller/dongle? " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice < ${#menu[@]} )); then
            SELECTED_LINE="${menu[$choice]}"
            if ! parse_lsusb_line "$SELECTED_LINE"; then
                echo "Could not parse that lsusb entry. Please choose another device."
                continue
            fi

            if [[ "${PARSED_NAME,,}" == *"bluetooth"* ]]; then
                echo
                echo "Warning: '$PARSED_NAME' looks like a Bluetooth adapter."
                echo "This tool is intended for a controller's USB receiver/dongle, not"
                echo "for Bluetooth controller wake."
                read -rp "Use this USB device anyway? (y/n) " use_bt
                [[ "$use_bt" =~ ^[Yy] ]] || continue
            fi
            return 0
        fi

        echo "Invalid selection. Enter one of the numbers shown above."
    done
}

already_selected() {
    local vid="$1" pid="$2"
    local i
    for i in "${!SEL_VID[@]}"; do
        if [[ "${SEL_VID[$i]}" == "$vid" && "${SEL_PID[$i]}" == "$pid" ]]; then
            return 0
        fi
    done
    return 1
}

clear_selection() {
    SEL_VID=()
    SEL_PID=()
    SEL_NAME=()
}

load_existing_rules() {
    local line rule_regex comment_regex
    local pending_name="" pending_vid="" pending_pid=""
    local vid pid name

    [[ -f "$RULE_FILE" ]] || return 0

    rule_regex='ATTR\{idVendor\}=="([[:xdigit:]]{4})".*ATTR\{idProduct\}=="([[:xdigit:]]{4})"'
    comment_regex='^#[[:space:]]+(.+)[[:space:]]+\(([[:xdigit:]]{4}):([[:xdigit:]]{4})\)$'

    while IFS= read -r line; do
        if [[ "$line" =~ $comment_regex ]]; then
            pending_name="${BASH_REMATCH[1]}"
            pending_vid="${BASH_REMATCH[2],,}"
            pending_pid="${BASH_REMATCH[3],,}"
            continue
        fi

        if [[ "$line" =~ $rule_regex ]]; then
            vid="${BASH_REMATCH[1],,}"
            pid="${BASH_REMATCH[2],,}"
            name="Existing USB device"
            if [[ "$pending_vid" == "$vid" && "$pending_pid" == "$pid" && -n "$pending_name" ]]; then
                name="$pending_name"
            fi

            if ! already_selected "$vid" "$pid"; then
                SEL_VID+=("$vid")
                SEL_PID+=("$pid")
                SEL_NAME+=("$name")
            fi

            pending_name=""
            pending_vid=""
            pending_pid=""
        fi
    done < "$RULE_FILE"
}

find_sysfs_matches() {
    local vid="$1" pid="$2"
    local node dvid dpid

    for node in /sys/bus/usb/devices/*; do
        [[ -f "$node/idVendor" && -f "$node/idProduct" ]] || continue
        read -r dvid < "$node/idVendor" || continue
        read -r dpid < "$node/idProduct" || continue
        if [[ "$dvid" == "$vid" && "$dpid" == "$pid" ]]; then
            readlink -f "$node"
        fi
    done
}

show_usb_wakeup_chain() {
    local start="$1"
    local current subsystem wake label vid pid product

    current="$(readlink -f "$start")"
    while [[ "$current" == /sys/* && "$current" != /sys ]]; do
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

install_support_files() {
    if (( RUNNING_FROM_SOURCE == 1 )); then
        echo "Installing management commands and helper..."
        as_root install -d -m 755 "$LIB_DIR" "$DOC_DIR"
        as_root install -m 755 "$SOURCE_HELPER" "$HELPER_DEST"
        as_root install -m 755 "$SCRIPT_DIR/setup-controller-wakeup.sh" "$SETUP_DEST"
        as_root install -m 755 "$SOURCE_STATUS" "$STATUS_DEST"
        as_root install -m 755 "$SOURCE_UNINSTALL" "$UNINSTALL_DEST"
        [[ -f "$SOURCE_README" ]] && as_root install -m 644 "$SOURCE_README" "$DOC_DIR/README.md"
        # Remove the helper location used by older releases so there is only
        # one authoritative installed copy.
        as_root rm -f "$LEGACY_HELPER"
    else
        if [[ ! -x "$HELPER_DEST" || ! -x "$STATUS_DEST" || ! -x "$UNINSTALL_DEST" ]]; then
            echo "Error: installed support files are incomplete."
            echo "Re-run the one-line installer or run setup from a fresh repository checkout."
            exit 1
        fi
    fi
}

write_rules() {
    local tmp i name
    tmp="$(mktemp)"

    {
        echo "# HTPC Controller Wake rules"
        echo "# Generated by htpc-controller-wake-setup on $(date -Is 2>/dev/null || date)"
        echo "# Matching exact USB vendor + product IDs; physical USB port is not pinned."
        echo
        for i in "${!SEL_VID[@]}"; do
            name="${SEL_NAME[$i]//$'\n'/ }"
            echo "# $name (${SEL_VID[$i]}:${SEL_PID[$i]})"
            printf 'ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="%s", ATTR{idProduct}=="%s", RUN+="%s %%p"\n' \
                "${SEL_VID[$i]}" "${SEL_PID[$i]}" "$HELPER_DEST"
            echo
        done
    } > "$tmp"

    as_root install -d -m 755 "$(dirname "$RULE_FILE")"
    if ! as_root install -m 644 "$tmp" "$RULE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

apply_current_devices() {
    local i sysfs devpath count failures
    echo
    echo "Applying wakeup settings to the currently connected selection(s)..."

    for i in "${!SEL_VID[@]}"; do
        count=0
        failures=0
        while IFS= read -r sysfs; do
            [[ -n "$sysfs" ]] || continue
            count=$((count + 1))
            devpath="${sysfs#/sys}"
            if ! as_root "$HELPER_DEST" "$devpath"; then
                failures=$((failures + 1))
            fi
        done < <(find_sysfs_matches "${SEL_VID[$i]}" "${SEL_PID[$i]}")

        printf '  %s (%s:%s): ' "${SEL_NAME[$i]}" "${SEL_VID[$i]}" "${SEL_PID[$i]}"
        if (( count == 0 )); then
            echo "not currently connected"
        elif (( failures == 0 )); then
            echo "enabled on $count matching device(s)"
        else
            echo "processed $count device(s), $failures had warnings; inspect status/journal"
        fi
    done
}

verify_current_devices() {
    local i sysfs count
    echo
    echo "Current wakeup state for selected USB path(s):"
    for i in "${!SEL_VID[@]}"; do
        echo
        echo "  ${SEL_NAME[$i]} (${SEL_VID[$i]}:${SEL_PID[$i]})"
        count=0
        while IFS= read -r sysfs; do
            [[ -n "$sysfs" ]] || continue
            count=$((count + 1))
            show_usb_wakeup_chain "$sysfs"
        done < <(find_sysfs_matches "${SEL_VID[$i]}" "${SEL_PID[$i]}")
        (( count > 0 )) || echo "    Device is not currently connected."
    done
}

check_dependencies

echo "=========================================="
echo " HTPC Controller Wake-from-Sleep Setup"
echo "=========================================="
echo
echo "Before continuing:"
echo "  - Power on the controller and pair it to its USB receiver/dongle."
echo "  - Keep the receiver connected while setup runs."
echo "  - This configures wake from system suspend, not power-on from shutdown."
echo "  - USB wake must also be allowed by your hardware/firmware."
echo "  - Bluetooth-only controller connections are not supported by this tool."
echo
echo "The rule matches the selected USB device by vendor + product ID, not by"
echo "physical USB port, so moving the same receiver normally does not require"
echo "re-running setup."
echo
read -rp "Ready to continue? (y/n) " ready
[[ "$ready" =~ ^[Yy] ]] || { echo "Exiting."; exit 0; }

load_existing_rules
add_devices=1
if (( ${#SEL_VID[@]} > 0 )); then
    echo
    echo "Existing configuration found:"
    for i in "${!SEL_VID[@]}"; do
        printf '  - %s (%s:%s)\n' "${SEL_NAME[$i]}" "${SEL_VID[$i]}" "${SEL_PID[$i]}"
    done
    echo
    read -rp "Keep these existing entries? (Y/n) " keep_existing
    if [[ "$keep_existing" =~ ^[Nn] ]]; then
        clear_selection
    else
        read -rp "Add another controller/dongle? (y/n) " add_more_now
        [[ "$add_more_now" =~ ^[Yy] ]] || add_devices=0
    fi
elif [[ -f "$RULE_FILE" ]]; then
    echo
    echo "An existing rule file was found, but it does not contain the exact"
    echo "VID:PID rule format used by this version. It will be replaced if you"
    echo "continue, so select every receiver you want configured."
fi

while (( add_devices == 1 )); do
    select_device || exit 1

    if already_selected "$PARSED_VID" "$PARSED_PID"; then
        echo "That VID:PID (${PARSED_VID}:${PARSED_PID}) is already selected; not adding a duplicate rule."
    else
        SEL_VID+=("$PARSED_VID")
        SEL_PID+=("$PARSED_PID")
        SEL_NAME+=("$PARSED_NAME")
        echo "Added: $PARSED_NAME (${PARSED_VID}:${PARSED_PID})"
    fi

    echo
    read -rp "Add another controller/dongle? (y/n) " more
    [[ "$more" =~ ^[Yy] ]] || break
done

if (( ${#SEL_VID[@]} == 0 )); then
    echo "No devices selected. Nothing to do."
    exit 0
fi

echo
echo "You selected:"
for i in "${!SEL_VID[@]}"; do
    printf '  - %s (%s:%s)\n' "${SEL_NAME[$i]}" "${SEL_VID[$i]}" "${SEL_PID[$i]}"
done

echo
read -rp "Install wakeup rules for these devices? (y/n) " confirm
[[ "$confirm" =~ ^[Yy] ]] || { echo "Aborted. No changes made."; exit 0; }

echo
install_support_files

echo "Writing udev rule: $RULE_FILE"
write_rules

echo "Reloading udev rules..."
as_root udevadm control --reload-rules

# Do not fake an add event for the whole USB subsystem. Apply the helper
# directly to the exact devices selected above; future real add events are
# handled by udev.
apply_current_devices
verify_current_devices

echo
echo "=========================================="
echo " Setup complete"
echo "=========================================="
echo
echo "Installed:"
echo "  Rule:      $RULE_FILE"
echo "  Setup:     $SETUP_DEST"
echo "  Status:    $STATUS_DEST"
echo "  Uninstall: $UNINSTALL_DEST"
echo
echo "A reboot is not required just to activate the rule. You can test now:"
echo "  1. Suspend the system."
echo "  2. Try waking it with the configured controller."
echo
echo "For diagnostics, run:"
echo "  htpc-controller-wake-status"
echo
echo "If wake still fails, check firmware USB-wake settings and the ACPI host"
echo "controller state shown by the status command."
