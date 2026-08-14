#!/bin/bash
# setup-controller-wakeup.sh
#
# Interactively selects one or more USB controller receivers, discovers the
# wake-capable USB topology above each selected device, and installs udev rules
# that keep those specific USB nodes wake-enabled.

set -euo pipefail

RULE_FILE="${HTPC_WAKE_RULE_FILE:-/etc/udev/rules.d/99-controller-wakeup.rules}"
LIB_DIR="${HTPC_WAKE_LIB_DIR:-/usr/local/lib/htpc-controller-wake}"
HELPER_DEST="$LIB_DIR/enable-usb-wakeup.sh"
SETUP_DEST="${HTPC_WAKE_SETUP_DEST:-/usr/local/bin/htpc-controller-wake-setup}"
STATUS_DEST="${HTPC_WAKE_STATUS_DEST:-/usr/local/bin/htpc-controller-wake-status}"
UNINSTALL_DEST="${HTPC_WAKE_UNINSTALL_DEST:-/usr/local/bin/htpc-controller-wake-uninstall}"
DOC_DIR="${HTPC_WAKE_DOC_DIR:-/usr/local/share/doc/htpc-controller-wake}"
LEGACY_HELPER="${HTPC_WAKE_LEGACY_HELPER:-/usr/local/bin/enable-usb-wakeup.sh}"
SYSFS_ROOT="${HTPC_WAKE_SYSFS_ROOT:-/sys}"
USB_DEVICES_DIR="$SYSFS_ROOT/bus/usb/devices"

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
declare -a SEL_PATH=()
declare -a SEL_TARGETS=()

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
        PARSED_BUS="${BASH_REMATCH[1]}"
        PARSED_DEV="${BASH_REMATCH[2]}"
        PARSED_VID="${BASH_REMATCH[3],,}"
        PARSED_PID="${BASH_REMATCH[4],,}"
        PARSED_NAME="${BASH_REMATCH[6]:-Unknown USB device}"
        return 0
    fi
    return 1
}

resolve_lsusb_sysfs() {
    local bus="$1" devnum="$2"
    local node node_bus node_dev

    for node in "$USB_DEVICES_DIR"/*; do
        [[ -f "$node/busnum" && -f "$node/devnum" ]] || continue
        read -r node_bus < "$node/busnum" || continue
        read -r node_dev < "$node/devnum" || continue

        # Compare numerically so lsusb's zero padding does not matter.
        if (( 10#$node_bus == 10#$bus && 10#$node_dev == 10#$devnum )); then
            readlink -f "$node"
            return 0
        fi
    done
    return 1
}

find_sysfs_matches() {
    local vid="$1" pid="$2"
    local node dvid dpid

    for node in "$USB_DEVICES_DIR"/*; do
        [[ -f "$node/idVendor" && -f "$node/idProduct" ]] || continue
        read -r dvid < "$node/idVendor" || continue
        read -r dpid < "$node/idProduct" || continue
        if [[ "$dvid" == "$vid" && "$dpid" == "$pid" ]]; then
            readlink -f "$node"
        fi
    done
}

discover_wake_targets() {
    local start="$1"
    local current subsystem

    current="$(readlink -f "$start" 2>/dev/null || true)"
    [[ -n "$current" && -d "$current" ]] || return 1

    while [[ "$current" == "$SYSFS_ROOT"/* && "$current" != "$SYSFS_ROOT" ]]; do
        subsystem=""
        [[ -L "$current/subsystem" ]] && subsystem="$(basename "$(readlink -f "$current/subsystem")")"

        if [[ "$subsystem" == "usb" && -e "$current/power/wakeup" ]]; then
            basename "$current"
        fi

        current="$(dirname "$current")"
    done
}

select_device() {
    local -a menu=()
    local line choice use_bt selected_sysfs
    local -a wake_targets=()

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

            selected_sysfs="$(resolve_lsusb_sysfs "$PARSED_BUS" "$PARSED_DEV" 2>/dev/null || true)"
            if [[ -z "$selected_sysfs" ]]; then
                echo "Could not resolve that USB device in sysfs. Please choose it again."
                continue
            fi

            mapfile -t wake_targets < <(discover_wake_targets "$selected_sysfs")
            if (( ${#wake_targets[@]} == 0 )); then
                echo "No wake-capable USB nodes were found above that device. Please choose another device."
                continue
            fi

            PARSED_PATH="$(basename "$selected_sysfs")"
            PARSED_TARGETS="${wake_targets[*]}"
            return 0
        fi

        echo "Invalid selection. Enter one of the numbers shown above."
    done
}

already_selected() {
    local vid="$1" pid="$2" path="${3:-}"
    local i

    # Physical USB path is authoritative in the topology-based format. This
    # intentionally allows two identical receivers (same VID:PID) on different
    # ports to be configured independently.
    if [[ -n "$path" ]]; then
        for i in "${!SEL_PATH[@]}"; do
            if [[ -n "${SEL_PATH[$i]}" && "${SEL_PATH[$i]}" == "$path" ]]; then
                return 0
            fi
        done
        return 1
    fi

    # VID:PID is only a fallback for legacy entries that have no saved path.
    for i in "${!SEL_VID[@]}"; do
        if [[ -z "${SEL_PATH[$i]}" && "${SEL_VID[$i]}" == "$vid" && "${SEL_PID[$i]}" == "$pid" ]]; then
            return 0
        fi
    done
    return 1
}

clear_selection() {
    SEL_VID=()
    SEL_PID=()
    SEL_NAME=()
    SEL_PATH=()
    SEL_TARGETS=()
}

add_selection() {
    local vid="$1" pid="$2" name="$3" path="$4" targets="$5"
    already_selected "$vid" "$pid" "$path" && return 0
    SEL_VID+=("$vid")
    SEL_PID+=("$pid")
    SEL_NAME+=("$name")
    SEL_PATH+=("$path")
    SEL_TARGETS+=("$targets")
}

derive_selection_from_sysfs() {
    local vid="$1" pid="$2" name="$3" sysfs="$4"
    local -a targets=()
    [[ -n "$sysfs" && -d "$sysfs" ]] || return 1
    mapfile -t targets < <(discover_wake_targets "$sysfs")
    (( ${#targets[@]} > 0 )) || return 1
    add_selection "$vid" "$pid" "$name" "$(basename "$sysfs")" "${targets[*]}"
}

load_existing_rules() {
    local line controller_regex path_regex targets_regex legacy_rule_regex
    local pending_name="" pending_vid="" pending_pid="" pending_path="" pending_targets=""
    local vid pid name sysfs
    local found_new=0

    [[ -f "$RULE_FILE" ]] || return 0

    controller_regex='^#[[:space:]]+(.+)[[:space:]]+\(([[:xdigit:]]{4}):([[:xdigit:]]{4})\)$'
    path_regex='^#[[:space:]]+Device[[:space:]]+path:[[:space:]]+([^[:space:]]+)$'
    targets_regex='^#[[:space:]]+Wake[[:space:]]+targets:[[:space:]]+(.+)$'
    legacy_rule_regex='ATTR\{idVendor\}=="([[:xdigit:]]{4})".*ATTR\{idProduct\}=="([[:xdigit:]]{4})"'

    while IFS= read -r line; do
        if [[ "$line" =~ $controller_regex ]]; then
            # Flush a completed current-format block before starting the next.
            if [[ -n "$pending_vid" && -n "$pending_path" && -n "$pending_targets" ]]; then
                add_selection "$pending_vid" "$pending_pid" "$pending_name" "$pending_path" "$pending_targets"
                found_new=1
            fi
            pending_name="${BASH_REMATCH[1]}"
            pending_vid="${BASH_REMATCH[2],,}"
            pending_pid="${BASH_REMATCH[3],,}"
            pending_path=""
            pending_targets=""
            continue
        fi

        if [[ "$line" =~ $path_regex ]]; then
            pending_path="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "$line" =~ $targets_regex ]]; then
            pending_targets="${BASH_REMATCH[1]}"
            continue
        fi
    done < "$RULE_FILE"

    if [[ -n "$pending_vid" && -n "$pending_path" && -n "$pending_targets" ]]; then
        add_selection "$pending_vid" "$pending_pid" "$pending_name" "$pending_path" "$pending_targets"
        found_new=1
    fi

    (( found_new == 1 )) && return 0

    # Migrate the previous exact-VID:PID format when possible. The old rule may
    # have been created for a receiver mode whose PID later changes, so first
    # try the exact pair, then a single unambiguous device from the same vendor.
    pending_name=""
    pending_vid=""
    pending_pid=""
    while IFS= read -r line; do
        if [[ "$line" =~ $controller_regex ]]; then
            pending_name="${BASH_REMATCH[1]}"
            pending_vid="${BASH_REMATCH[2],,}"
            pending_pid="${BASH_REMATCH[3],,}"
            continue
        fi

        if [[ "$line" =~ $legacy_rule_regex ]]; then
            vid="${BASH_REMATCH[1],,}"
            pid="${BASH_REMATCH[2],,}"
            name="${pending_name:-Existing USB device}"
            sysfs="$(find_sysfs_matches "$vid" "$pid" | head -n1 || true)"

            if [[ -z "$sysfs" ]]; then
                local -a vendor_matches=()
                local node dvid
                for node in "$USB_DEVICES_DIR"/*; do
                    [[ -f "$node/idVendor" && -f "$node/idProduct" ]] || continue
                    read -r dvid < "$node/idVendor" || continue
                    [[ "$dvid" == "$vid" ]] || continue
                    vendor_matches+=("$(readlink -f "$node")")
                done
                if (( ${#vendor_matches[@]} == 1 )); then
                    sysfs="${vendor_matches[0]}"
                fi
            fi

            if [[ -n "$sysfs" ]]; then
                derive_selection_from_sysfs "$vid" "$pid" "$name" "$sysfs" || true
            fi

            pending_name=""
            pending_vid=""
            pending_pid=""
        fi
    done < "$RULE_FILE"
}

show_usb_wakeup_chain() {
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
    local tmp i name target
    local -a ordered_targets=()
    declare -A seen_targets=()

    tmp="$(mktemp)"

    {
        echo "# HTPC Controller Wake rules"
        echo "# Generated by htpc-controller-wake-setup on $(date -Is 2>/dev/null || date)"
        echo "# Wake-capable USB topology is discovered from the selected receiver(s)."
        echo

        for i in "${!SEL_VID[@]}"; do
            name="${SEL_NAME[$i]//$'\n'/ }"
            echo "# $name (${SEL_VID[$i]}:${SEL_PID[$i]})"
            echo "# Device path: ${SEL_PATH[$i]}"
            echo "# Wake targets: ${SEL_TARGETS[$i]}"
            echo

            for target in ${SEL_TARGETS[$i]}; do
                [[ -n "$target" ]] || continue
                if [[ -z "${seen_targets[$target]+x}" ]]; then
                    seen_targets[$target]=1
                    ordered_targets+=("$target")
                fi
            done
        done

        for target in "${ordered_targets[@]}"; do
            printf 'ACTION=="add", SUBSYSTEM=="usb", KERNEL=="%s", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"\n' "$target"
        done
    } > "$tmp"

    as_root install -d -m 755 "$(dirname "$RULE_FILE")"
    if ! as_root install -m 644 "$tmp" "$RULE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

enable_wake_target() {
    local target="$1"
    local wake_file="$USB_DEVICES_DIR/$target/power/wakeup"

    [[ -e "$wake_file" ]] || return 2
    if as_root sh -c 'printf "%s\n" enabled > "$1"' sh "$wake_file"; then
        return 0
    fi
    return 1
}

apply_current_devices() {
    local i target count failures
    echo
    echo "Applying wakeup settings to the currently connected selection(s)..."

    for i in "${!SEL_VID[@]}"; do
        count=0
        failures=0
        for target in ${SEL_TARGETS[$i]}; do
            [[ -n "$target" ]] || continue
            if enable_wake_target "$target"; then
                count=$((count + 1))
            else
                case $? in
                    2) ;; # Node is not currently enumerated; udev will handle future add events.
                    *) failures=$((failures + 1)) ;;
                esac
            fi
        done

        printf '  %s (%s:%s): ' "${SEL_NAME[$i]}" "${SEL_VID[$i]}" "${SEL_PID[$i]}"
        if (( count == 0 && failures == 0 )); then
            echo "not currently connected"
        elif (( failures == 0 )); then
            echo "enabled on $count wake-capable USB node(s)"
        else
            echo "enabled $count node(s), $failures had warnings; inspect status"
        fi
    done
}

verify_current_devices() {
    local i path target wake
    echo
    echo "Current wakeup state for selected USB path(s):"
    for i in "${!SEL_VID[@]}"; do
        echo
        echo "  ${SEL_NAME[$i]} (${SEL_VID[$i]}:${SEL_PID[$i]})"
        path="$USB_DEVICES_DIR/${SEL_PATH[$i]}"
        if [[ -e "$path" ]]; then
            show_usb_wakeup_chain "$path"
        else
            for target in ${SEL_TARGETS[$i]}; do
                if [[ -e "$USB_DEVICES_DIR/$target/power/wakeup" ]]; then
                    wake="$(cat "$USB_DEVICES_DIR/$target/power/wakeup" 2>/dev/null || echo unreadable)"
                    printf '    %-49s wakeup=%s\n' "$target" "$wake"
                fi
            done
        fi
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
    echo "An existing rule file was found, but its configured USB path could not"
    echo "be resolved. It will be replaced if you continue, so select every"
    echo "receiver you want configured."
fi

while (( add_devices == 1 )); do
    select_device || exit 1

    if already_selected "$PARSED_VID" "$PARSED_PID" "$PARSED_PATH"; then
        echo "That controller/dongle is already selected; not adding a duplicate rule."
    else
        add_selection "$PARSED_VID" "$PARSED_PID" "$PARSED_NAME" "$PARSED_PATH" "$PARSED_TARGETS"
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

# Apply the same wake-capable topology that was persisted in the udev rules.
# Future real USB add events will reassert these values automatically.
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
