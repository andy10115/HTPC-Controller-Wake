#!/bin/bash
# uninstall.sh - removes everything installed by HTPC Controller Wake.

set -euo pipefail

RULE_FILE="${HTPC_WAKE_RULE_FILE:-/etc/udev/rules.d/99-controller-wakeup.rules}"
CONFIG_DIR="${HTPC_WAKE_CONFIG_DIR:-/etc/htpc-controller-wake}"
SUSPEND_DROPIN_DIR="${HTPC_WAKE_SUSPEND_DROPIN_DIR:-/etc/systemd/system/systemd-suspend.service.d}"
SUSPEND_DROPIN="${HTPC_WAKE_SUSPEND_DROPIN:-$SUSPEND_DROPIN_DIR/htpc-controller-wake.conf}"
LIB_DIR="${HTPC_WAKE_LIB_DIR:-/usr/local/lib/htpc-controller-wake}"
DOC_DIR="${HTPC_WAKE_DOC_DIR:-/usr/local/share/doc/htpc-controller-wake}"
SETUP_DEST="${HTPC_WAKE_SETUP_DEST:-/usr/local/bin/htpc-controller-wake-setup}"
STATUS_DEST="${HTPC_WAKE_STATUS_DEST:-/usr/local/bin/htpc-controller-wake-status}"
UNINSTALL_DEST="${HTPC_WAKE_UNINSTALL_DEST:-/usr/local/bin/htpc-controller-wake-uninstall}"
LEGACY_HELPER="${HTPC_WAKE_LEGACY_HELPER:-/usr/local/bin/enable-usb-wakeup.sh}"
SUSPEND_GUARD_DEST="${HTPC_WAKE_SUSPEND_GUARD_DEST:-/usr/local/bin/htpc-controller-wake-suspend-guard}"

as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

if (( EUID != 0 )) && ! command -v sudo >/dev/null 2>&1; then
    echo "Error: sudo is required when uninstalling as a non-root user."
    exit 1
fi

cat <<EOF2
This will remove HTPC Controller Wake:
  - $RULE_FILE
  - $CONFIG_DIR
  - $SUSPEND_DROPIN
  - $LIB_DIR
  - $SUSPEND_GUARD_DEST
  - $SETUP_DEST
  - $STATUS_DEST
  - $UNINSTALL_DEST
  - $DOC_DIR
EOF2

echo
read -rp "Continue? (y/n) " confirm
[[ "$confirm" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

as_root rm -f "$RULE_FILE" "$SUSPEND_DROPIN" "$SETUP_DEST" "$STATUS_DEST" "$LEGACY_HELPER" "$SUSPEND_GUARD_DEST"
as_root rm -rf "$CONFIG_DIR" "$LIB_DIR" "$DOC_DIR"
as_root rmdir "$SUSPEND_DROPIN_DIR" 2>/dev/null || true

if command -v udevadm >/dev/null 2>&1; then
    as_root udevadm control --reload-rules || true
fi
if command -v systemctl >/dev/null 2>&1; then
    as_root systemctl daemon-reload || true
fi

# Remove ourselves last. The running process remains valid after unlinking.
as_root rm -f "$UNINSTALL_DEST"

echo
echo "HTPC Controller Wake has been removed."
echo "Existing power/wakeup values are not force-disabled because those USB"
echo "ancestors may also be wake sources for other devices. They will be"
echo "re-evaluated naturally on device re-enumeration or reboot."
