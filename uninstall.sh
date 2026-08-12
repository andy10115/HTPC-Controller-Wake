#!/bin/bash
# uninstall.sh - removes everything installed by HTPC Controller Wake.

set -euo pipefail

RULE_FILE="/etc/udev/rules.d/99-controller-wakeup.rules"
LIB_DIR="/usr/local/lib/htpc-controller-wake"
DOC_DIR="/usr/local/share/doc/htpc-controller-wake"
SETUP_DEST="/usr/local/bin/htpc-controller-wake-setup"
STATUS_DEST="/usr/local/bin/htpc-controller-wake-status"
UNINSTALL_DEST="/usr/local/bin/htpc-controller-wake-uninstall"
LEGACY_HELPER="/usr/local/bin/enable-usb-wakeup.sh"

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
  - $LIB_DIR
  - $SETUP_DEST
  - $STATUS_DEST
  - $UNINSTALL_DEST
  - $DOC_DIR
EOF2

echo
read -rp "Continue? (y/n) " confirm
[[ "$confirm" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

as_root rm -f "$RULE_FILE" "$SETUP_DEST" "$STATUS_DEST" "$LEGACY_HELPER"
as_root rm -rf "$LIB_DIR" "$DOC_DIR"

if command -v udevadm >/dev/null 2>&1; then
    as_root udevadm control --reload-rules || true
fi

# Remove ourselves last. The running process remains valid after unlinking.
as_root rm -f "$UNINSTALL_DEST"

echo
echo "HTPC Controller Wake has been removed."
echo "Existing power/wakeup values are not force-disabled because those USB"
echo "ancestors may also be wake sources for other devices. They will be"
echo "re-evaluated naturally on device re-enumeration or reboot."
