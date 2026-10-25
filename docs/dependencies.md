# Dependencies

This document explains why a stock Linux installation usually cannot do this,
which libraries are involved, and how to verify that the right build is running.

## The short version

`usbmuxd` is the only component that must be **newer than the distribution
package**. Distros ship release `1.1.1`, published in June 2020. The feature
this project depends on was added to the upstream repository in December 2022
and **has never been included in a release**, so no distro package contains it.

Because the new daemon links against the current development versions of the
libimobiledevice stack, the whole stack is built together, in order.

## Why the package is not enough

`usbmuxd` can ask an Apple device to switch its USB configuration. That is what
makes the iPad expose a network interface instead of only the media/usbmux
functions.

The switch is controlled by an environment variable:

```text
USBMUXD_DEFAULT_DEVICE_MODE
```

| Fact | Value |
|------|-------|
| Latest upstream release | `1.1.1`, 2020-06-15 |
| Commit that introduced the variable | `6d0183d`, 2022-12-22 |
| Description of that commit | "Support switching to different modes using vendor specific control messages" |
| Default when the variable is unset | mode `1` |
| Valid range | `1`–`5` |

Since no release has been cut after 2022, every distribution package is built
from code that predates the variable.

Verify on any machine:

```bash
strings /usr/bin/usbmuxd | grep USBMUXD_DEFAULT_DEVICE_MODE
```

No output means that binary cannot switch modes, no matter how it is
configured. On the reference machine, the same command against
`/usr/local/sbin/usbmuxd` does print the variable.

## What mode 3 means

The daemon guesses the device's current mode from its USB configuration
descriptors, then requests the desired one through a vendor-specific control
transfer if they differ.

The guess is based on the number of configurations and the interfaces they
contain:

| Mode | Detected as | Meaning |
|------|-------------|---------|
| `1` | ≤ 4 configurations | Initial / default Apple mode |
| `2` | 5 configurations, Valeria + usbmux | Valeria transport |
| `3` | 5 configurations, **CDC-NCM + usbmux** | **USB Ethernet, usbmux preserved** |
| `4` | 6 configurations | USB Ethernet + CDC-NCM |
| `5` | 1 configuration | CDC-NCM only |

Mode `3` is the useful one: the device exposes CDC-NCM for networking while
keeping the Apple USB multiplexor available, so management and pairing still
work alongside the network link.

In the log this appears as:

```text
Found CDC-NCM and Apple USB Multiplexor in device ... configuration 5
Skipping switch device ... mode from 3 to 3
```

The second line means the device was already in the requested mode, which is
normal after the first successful switch or when the iPad remembers the state.

If the device's mode cannot be guessed, the daemon logs a failure and continues
in the current mode. That is the case to investigate when the variable is set
correctly but no network interface appears.

## The stack

Build order matters: each library is discovered by the next one through
`pkg-config`.

| # | Component | Role |
|---|-----------|------|
| 1 | `libplist` | Reads and writes Apple's property-list format |
| 2 | `libimobiledevice-glue` | Shared helpers used by the rest of the stack |
| 3 | `libusbmuxd` | Client side of the usbmux protocol |
| 4 | `libtatsu` | TSS/signing support, required by current `libimobiledevice` |
| 5 | `libimobiledevice` | High-level device communication |
| 6 | `usbmuxd` | The daemon that owns the USB device and switches its mode |

`libusb` comes from the system and is not part of this stack.

### Build dependencies

| Package | Debian/Ubuntu | Arch |
|---------|---------------|------|
| Compiler and basic tools | `build-essential` | `base-devel` |
| `autoconf` | `autoconf` | `autoconf` |
| `automake` | `automake` | `automake` |
| `libtool` | `libtool` / `libtool-bin` | `libtool` |
| `pkg-config` | `pkg-config` | `pkgconf` |
| libusb headers | `libusb-1.0-0-dev` | `libusb` |
| OpenSSL headers | `libssl-dev` | `openssl` |
| libcurl headers | `libcurl4-openssl-dev` | `curl` |
| udev headers | `udev` | `systemd-libs` |
| Git | `git` | `git` |

## Installing to `/usr/local`

The stack is installed under `/usr/local`, which no package manager owns. This
avoids file conflicts with distribution packages and keeps the custom build
isolated.

The consequence is that `pacman` (or `apt`) will never upgrade these files, and
the system package remains installed but unused. That is intentional: it gives
a clean fallback and a clean uninstall path.

`pkg-config` must find the new libraries before each build:

```bash
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
```

The dynamic linker must find them at runtime as well. On most distributions
`/usr/local/lib` is already in the search path; if it is not:

```bash
sudo ldconfig
```

## Starting the right binary

The distribution's systemd unit points at `/usr/bin/usbmuxd`. A drop-in
overrides both the binary and the environment:

```ini
# /etc/systemd/system/usbmuxd.service.d/ncm.conf
[Service]
Environment=USBMUXD_DEFAULT_DEVICE_MODE=3
ExecStart=
ExecStart=/usr/local/sbin/usbmuxd --user usbmux --systemd
```

The empty `ExecStart=` is required to clear the inherited value before setting
the new one.

Apply it:

```bash
sudo systemctl daemon-reload
sudo systemctl restart usbmuxd
```

## Verifying the installation

```bash
# The running daemon uses the custom binary
systemctl cat usbmuxd | grep ExecStart

# The effective environment includes the mode
systemctl show usbmuxd -p Environment

# The binary is the one we built
/usr/local/sbin/usbmuxd --version

# It links against the libraries in /usr/local
ldd /usr/local/sbin/usbmuxd | grep -E 'plist|usbmux|imobiledevice'

# The mode switch was attempted or confirmed
journalctl -u usbmuxd --since "5 minutes ago" | grep -iE 'ncm|mode'
```

Expected versions at the time of writing:

```text
usbmuxd 1.1.1-72-g3ded00c
```

The suffix after the release number is the number of commits since the tag and
the current commit hash. Any build from 2022-12-22 onwards contains the feature.

## How this project uses it

The CLI does **not** compile anything automatically. It only:

1. detects whether the installed `usbmuxd` supports the variable;
2. reports a clear, distro-specific explanation if it does not;
3. verifies that the running service points at the capable binary.

Automatic compilation is deliberately out of scope, because a script that
builds six projects from source is a liability on a rolling distribution.
Packaging it (AUR, COPR, PPA) is the better long-term answer.

## Uninstalling

Remove the drop-in first, then the stack in reverse order:

```bash
sudo rm /etc/systemd/system/usbmuxd.service.d/ncm.conf
sudo systemctl daemon-reload
sudo systemctl restart usbmuxd
```

Then, inside each source directory from 6 down to 1:

```bash
sudo make uninstall
```

Finally:

```bash
sudo ldconfig
```

The distribution package remains installed and takes over again.
