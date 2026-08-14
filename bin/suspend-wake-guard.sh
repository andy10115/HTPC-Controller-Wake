#!/bin/bash
# suspend-wake-guard.sh
#
# Runs immediately before systemd performs a normal suspend. Temporarily
# disarms only the USB wake-capable topology nodes configured by this project,
# gives controller/receiver shutdown traffic time to settle, then re-arms the
# same nodes before the kernel enters suspend.
#
# This deliberately never blocks suspend on a missing node or failed sysfs
# write. Any node that still exists is re-enabled before exit, including when
# the guard is interrupted.

set -u

TAG="htpc-controller-wake"
SYSFS_ROOT="${HTPC_WAKE_SYSFS_ROOT:-/sys}"
USB_DEVICES_DIR="$SYSFS_ROOT/bus/usb/devices"
TARGETS_FILE="${HTPC_WAKE_TARGETS_FILE:-/etc/htpc-controller-wake/wake-targets}"
QUIET_SECONDS="${HTPC_WAKE_QUIET_SECONDS:-5}"

log() {
    local message="$*"
    if command -v logger >/dev/null 2>&1; then
        logger -t "$TAG" -- "$message" || true
    fi
}

read_targets() {
    local line target
    [[ -r "$TARGETS_FILE" ]] || return 0
    while IFS= read -r line; do
        target="${line%%#*}"
        # Generated entries never contain whitespace; use the first token so
        # hand-edited comments or spacing cannot become part of a sysfs path.
        target="${target%%[[:space:]]*}"
        [[ -n "$target" ]] && printf '%s\n' "$target"
    done < "$TARGETS_FILE"
}

set_targets() {
    local state="$1"
    local target wake_file
    local changed=0 failed=0

    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        wake_file="$USB_DEVICES_DIR/$target/power/wakeup"
        [[ -e "$wake_file" ]] || continue

        if { printf '%s\n' "$state" > "$wake_file"; } 2>/dev/null; then
            changed=$((changed + 1))
        else
            failed=$((failed + 1))
        fi
    done < <(read_targets)

    if (( failed > 0 )); then
        log "Suspend guard set $changed wake target(s) to $state; $failed write(s) failed."
    fi
}

rearm_and_exit() {
    set_targets enabled
}

# Always leave configured wake paths armed, even if the delay is interrupted.
trap rearm_and_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

if [[ ! -r "$TARGETS_FILE" ]]; then
    exit 0
fi

# Do not allow a malformed override to stall suspend indefinitely.
if [[ ! "$QUIET_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    QUIET_SECONDS=5
fi

set_targets disabled
log "Suspend guard disarmed configured USB wake path(s) for ${QUIET_SECONDS}s."
sleep "$QUIET_SECONDS"
set_targets enabled
log "Suspend guard re-armed configured USB wake path(s); continuing suspend."

# The EXIT trap intentionally reasserts enabled once more.
exit 0
