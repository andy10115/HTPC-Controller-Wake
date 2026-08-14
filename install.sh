#!/bin/bash
# install.sh
# One-line installer:
#   curl -fsSL https://raw.githubusercontent.com/andy10115/HTPC-Controller-Wake/main/install.sh | bash

set -euo pipefail

ARCHIVE_URL="https://github.com/andy10115/HTPC-Controller-Wake/archive/refs/heads/main.tar.gz"
TMP_DIR="$(mktemp -d)"
ARCHIVE="$TMP_DIR/repo.tar.gz"
SOURCE_DIR="$TMP_DIR/repo"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for cmd in curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' was not found."
        exit 1
    fi
done

mkdir -p "$SOURCE_DIR"

echo "Downloading HTPC Controller Wake..."
if ! curl -fsSL --retry 3 --connect-timeout 15 "$ARCHIVE_URL" -o "$ARCHIVE"; then
    echo "Error: failed to download the repository archive from GitHub."
    exit 1
fi

if ! tar -xzf "$ARCHIVE" --strip-components=1 -C "$SOURCE_DIR"; then
    echo "Error: downloaded archive could not be extracted."
    exit 1
fi

required=(
    "$SOURCE_DIR/setup-controller-wakeup.sh"
    "$SOURCE_DIR/bin/enable-usb-wakeup.sh"
    "$SOURCE_DIR/bin/suspend-wake-guard.sh"
    "$SOURCE_DIR/check-wakeup-status.sh"
    "$SOURCE_DIR/uninstall.sh"
)
for file in "${required[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "Error: repository archive is missing $(basename "$file")."
        exit 1
    fi
done

chmod +x \
    "$SOURCE_DIR/setup-controller-wakeup.sh" \
    "$SOURCE_DIR/bin/enable-usb-wakeup.sh" \
    "$SOURCE_DIR/bin/suspend-wake-guard.sh" \
    "$SOURCE_DIR/check-wakeup-status.sh" \
    "$SOURCE_DIR/uninstall.sh"

echo "Download complete. Launching interactive setup..."
echo

if [[ -r /dev/tty ]]; then
    "$SOURCE_DIR/setup-controller-wakeup.sh" < /dev/tty
else
    echo "Error: interactive setup requires a terminal (/dev/tty)."
    echo "Run the installer from an interactive shell."
    exit 1
fi
