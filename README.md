# HTPC Controller Wake-from-Sleep

Wake a Linux HTPC from suspend using a game controller connected through a USB
receiver/dongle. The project is aimed at gaming-focused HTPC setups such as
Bazzite and CachyOS, but it only depends on Bash, udev/systemd tooling, and the
standard Linux USB sysfs interface.

The setup tool lets you choose one or more USB controller receivers, creates a
udev rule for each exact USB **vendor ID + product ID**, and enables
`power/wakeup` on the selected USB device plus the USB hubs/ancestors above it.

## Before you start

### Firmware still matters

Your motherboard/firmware must allow USB devices to wake the system. Relevant
settings are often named something like:

- **Wake from USB** / **USB Wake Support**
- **ErP** / **Deep Sleep**

Exact names and behavior vary by motherboard. A disabled or unsupported USB
wake path cannot always be repaired by a udev rule.

### Suspend only

This project configures wake from **system suspend**. Depending on your system,
that may be `s2idle` or `deep`/suspend-to-RAM (S3 on ACPI systems).

It does **not** configure power-on from a full shutdown (S5). USB controller
wake from shutdown is firmware-dependent and much less consistently supported.

### USB receiver/dongle connections

This project is intended for controllers whose wake signal arrives through a
USB device, normally a 2.4 GHz receiver/dongle. It does not configure a
Bluetooth controller's wireless wake path.

### USB ports are not pinned

Rules match the selected receiver by VID:PID, not by physical port. Moving the
same receiver to another USB port normally does **not** require setup again.
The helper discovers the receiver's current USB ancestor chain each time the
receiver is enumerated.

## Install

One-line installer:

```bash
curl -fsSL https://raw.githubusercontent.com/andy10115/HTPC-Controller-Wake/main/install.sh | bash
```

The installer downloads a temporary copy only for setup, then installs permanent
management commands on the system. You do not need to keep the repository
checkout afterward.

Manual install:

```bash
git clone https://github.com/andy10115/HTPC-Controller-Wake.git
cd HTPC-Controller-Wake
chmod +x setup-controller-wakeup.sh bin/enable-usb-wakeup.sh check-wakeup-status.sh uninstall.sh
./setup-controller-wakeup.sh
```

## Setup flow

1. Power on the controller and pair it to its USB receiver/dongle.
2. Run the installer or `./setup-controller-wakeup.sh`.
3. Choose the controller/dongle from the displayed `lsusb` list. Devices whose
   name looks like a Bluetooth adapter are explicitly warned about before they
   can be selected.
4. Add any additional receivers you want to configure.
5. Confirm the selection. If a current-format configuration already exists,
   setup offers to keep those entries before you add or replace devices.
6. The script installs the rule and helper, reloads udev, immediately applies
   wake settings to the currently connected device(s), and prints their current
   USB wakeup chain.
7. Suspend and test the controller.

A reboot is **not required just to activate the newly installed rule**. Future
real USB `add` events (including boot and reconnects) will run the helper again.

## Installed commands

After a successful setup:

```bash
htpc-controller-wake-setup
```

Reconfigure the selected controller receiver(s). Existing current-format rules
are offered for preservation so adding a new receiver does not silently remove
previously configured ones.

```bash
htpc-controller-wake-status
```

Show:

- whether the installed rule/helper/management commands exist
- the current udev rule
- configured VID:PID devices that are currently connected
- wakeup state for each configured device and its USB ancestor chain
- wakeup state for all USB devices
- active suspend mode
- USB-related ACPI wake-source state, where available
- recent helper messages from the system journal

```bash
htpc-controller-wake-uninstall
```

Remove the rule, helper, documentation, and installed management commands.

## How it works

The generated udev rule looks conceptually like this:

```udev
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="2dc8", ATTR{idProduct}=="3106", RUN+="/usr/local/lib/htpc-controller-wake/enable-usb-wakeup.sh %p"
```

Matching both vendor and product ID keeps the rule scoped to the selected type
of receiver instead of every USB product made by the same vendor.

When the receiver is added, the helper starts at that sysfs USB device and walks
up its ancestor chain. It only touches ancestors whose subsystem is `usb`, and
for each one that exposes `power/wakeup`, it attempts to write `enabled`.
Intermediate/root hubs can matter because some systems gate downstream wake
through them.

The helper logs successful and failed wakeup writes with the journal tag:

```text
htpc-controller-wake
```

You can inspect those messages directly with:

```bash
journalctl -t htpc-controller-wake
```

## Troubleshooting

First run:

```bash
htpc-controller-wake-status
```

Things to look for:

- The configured receiver should appear under **Configured device matches**.
- Relevant entries in its USB ancestor chain should normally show
  `wakeup=enabled` when they expose a wakeup attribute.
- If the receiver is absent, make sure it is connected and that you selected the
  correct `lsusb` entry.
- If an ACPI XHC/EHC wake source is shown as disabled, that means the ACPI wake
  source is currently disabled. It does not by itself prove that firmware has
  permanently blocked it; platform firmware, kernel behavior, and ACPI policy
  can all affect the result.
- Some hardware simply cannot wake from a given USB path or suspend mode even
  when the visible Linux wake flags look correct.

## Dependencies

Setup checks for the commands it needs and reports missing components. The main
non-core utility is `lsusb`, normally provided by your distro's `usbutils`
package.

The one-line bootstrap installer requires `curl` and `tar` but does not require
Git.

## Why not enable wakeup on every USB device?

Because broad USB wake rules can create unwanted wakeups from mice, hubs, storage
re-enumeration, or other devices. This project deliberately scopes the udev rule
to the receiver VID:PID values you selected while enabling only the necessary
USB ancestor chain for that receiver.

## Files installed

```text
/etc/udev/rules.d/99-controller-wakeup.rules
/usr/local/lib/htpc-controller-wake/enable-usb-wakeup.sh
/usr/local/bin/htpc-controller-wake-setup
/usr/local/bin/htpc-controller-wake-status
/usr/local/bin/htpc-controller-wake-uninstall
/usr/local/share/doc/htpc-controller-wake/README.md
```

## License

MIT
