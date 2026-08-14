# HTPC Controller Wake-from-Sleep

Wake a Linux HTPC from suspend using a game controller connected through a USB
receiver/dongle. The project is aimed at gaming-focused HTPC setups such as
Bazzite and CachyOS, but it only depends on Bash, udev/systemd tooling, and the
standard Linux USB sysfs interface.

The setup tool lets you choose one or more USB controller receivers, resolves
each selected receiver to its current USB topology, discovers every USB node in
that path that actually exposes `power/wakeup`, and creates udev rules that keep
those wake-capable nodes enabled.

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

### USB topology

The selected receiver is used to discover the USB path that must remain
wake-capable. The generated rules target the wake-capable nodes in that path
(such as an intermediate hub or root hub), rather than depending on the
receiver's product ID remaining constant. If you move the receiver to a
different physical USB path, rerun setup so the new wake path can be discovered.

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
   wake settings to the discovered USB wake path(s), and prints their current
   USB wakeup chain.
7. Suspend and test the controller.

Setup also installs a pre-suspend guard automatically. There are no additional
prompts or configuration steps for it.

A reboot is **not required just to activate the newly installed rule**. Future
USB `add` events for the discovered hub/root-hub nodes (including boot) will
reassert their `power/wakeup=enabled` state.

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

- whether the installed rule/helper/suspend guard/management commands exist
- the current udev rule
- configured controllers and their selected USB paths
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

During setup, the selected receiver is resolved from its `lsusb` bus/device
identity to its current sysfs USB node. Setup then walks upward through the USB
ancestry and records only nodes that expose `power/wakeup`. A controller node
that does not expose that attribute is skipped automatically.

For example, if the selected receiver is under an intermediate hub and only the
hub and root hub expose wake controls, the generated rules look conceptually
like this:

```udev
ACTION=="add", SUBSYSTEM=="usb", KERNEL=="5-1", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
ACTION=="add", SUBSYSTEM=="usb", KERNEL=="usb5", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
```

The exact `KERNEL` values are discovered from the machine during setup; they are
not hard-coded by the project. Multiple selected controllers can share wake
targets, and duplicate targets are written only once.

The selected receiver's VID:PID is retained as descriptive configuration
metadata for status/reconfiguration, but the persistent wake rule does not rely
on an exact product ID. This matters for receivers that enumerate with different
product IDs in different modes or pairing states.

The installed helper remains available for support/troubleshooting and can walk
a supplied USB sysfs path to enable every wake-capable USB ancestor.

### Pre-suspend quiet window

Some controller receivers generate USB activity while the controller is powering
off. If that happens while the kernel is entering suspend, the activity can be
seen as a wake event and abort the suspend transition.

To avoid that race, setup saves the discovered wake-capable topology nodes and
installs a drop-in for `systemd-suspend.service`. Immediately before the actual
suspend operation, the guard temporarily sets only those configured wake paths
to `disabled`, waits **10 seconds** for controller/receiver shutdown traffic to
settle, then sets the same paths back to `enabled` and allows suspend to
continue. The guard re-arms the paths on interruption as well, so a canceled or
failed suspend does not intentionally leave controller wake disabled.

This does not globally suppress wake sources such as the system power button;
it only disarms the USB topology nodes configured by this project during the
quiet window.

## Troubleshooting

First run:

```bash
htpc-controller-wake-status
```

Things to look for:

- The configured receiver or its configured USB path should appear under
  **Configured device matches**.
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

Because broad USB wake rules can create unwanted wakeups from mice, storage, or
other devices. This project discovers the specific USB path used by the selected
receiver and enables only wake-capable nodes in that path.

## Files installed

```text
/etc/udev/rules.d/99-controller-wakeup.rules
/etc/htpc-controller-wake/wake-targets
/etc/systemd/system/systemd-suspend.service.d/htpc-controller-wake.conf
/usr/local/lib/htpc-controller-wake/enable-usb-wakeup.sh
/usr/local/bin/htpc-controller-wake-suspend-guard
/usr/local/bin/htpc-controller-wake-setup
/usr/local/bin/htpc-controller-wake-status
/usr/local/bin/htpc-controller-wake-uninstall
/usr/local/share/doc/htpc-controller-wake/README.md
```

## License

MIT
