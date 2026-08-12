#!/bin/bash
# enable-usb-wakeup.sh
#
# Internal udev helper. Receives a udev device path (%p), then enables
# power/wakeup on that USB device and every USB ancestor that exposes the
# attribute (including intermediate/root hubs). Non-USB ancestors are left
# untouched.

set -u

TAG="htpc-controller-wake"
devpath="${1:-}"

log() {
    local message="$*"
    if command -v logger >/dev/null 2>&1; then
        logger -t "$TAG" -- "$message" || true
    fi
}

if [[ -z "$devpath" ]]; then
    log "No devpath provided; helper exiting."
    exit 1
fi

# udev passes %p as /devices/...; accepting /sys/... as well makes manual
# troubleshooting less error-prone.
if [[ "$devpath" == /sys/* ]]; then
    current="$(readlink -f "$devpath" 2>/dev/null || true)"
else
    current="$(readlink -f "/sys${devpath}" 2>/dev/null || true)"
fi

if [[ -z "$current" || ! -d "$current" ]]; then
    log "Device path not found: $devpath"
    exit 1
fi

found_usb=0
wake_files=0
enabled_any=0
failed_any=0

while [[ "$current" == /sys/* && "$current" != /sys ]]; do
    subsystem=""
    if [[ -L "$current/subsystem" ]]; then
        subsystem="$(basename "$(readlink -f "$current/subsystem")")"
    fi

    if [[ "$subsystem" == "usb" ]]; then
        found_usb=1
        wake_file="$current/power/wakeup"

        if [[ -e "$wake_file" ]]; then
            wake_files=$((wake_files + 1))
            if printf '%s\n' enabled 2>/dev/null > "$wake_file"; then
                enabled_any=1
                log "Enabled wakeup: $current"
            else
                failed_any=1
                log "Failed to enable wakeup: $current"
            fi
        fi
    fi

    parent="$(dirname "$current")"
    [[ "$parent" == "$current" ]] && break
    current="$parent"
done

if (( found_usb == 0 )); then
    log "No USB device found in ancestor chain for: $devpath"
    exit 1
fi

if (( wake_files == 0 )); then
    log "No USB power/wakeup attributes found for: $devpath"
    exit 2
fi

if (( enabled_any == 0 )); then
    log "No USB power/wakeup attribute could be enabled for: $devpath"
    exit 3
fi

if (( failed_any == 1 )); then
    log "Wakeup enabled on part of the USB chain, but one or more writes failed: $devpath"
    exit 4
fi

exit 0
