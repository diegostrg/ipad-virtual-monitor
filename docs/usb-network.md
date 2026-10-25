# USB network

This document explains how the iPad gets an IP address over the cable, and why
that is the hardest part of the whole setup.

## Why the iPad needs a special USB mode

When an iPad is plugged into a Linux host it normally exposes:

- a USB mass-storage-like interface for photos and media,
- the usbmux protocol, used by `libimobiledevice` for backups and management.

Neither is a network card. The network function exists in the hardware, but it
must be requested by the host through `usbmuxd`.

`usbmuxd` accepts `USBMUXD_DEFAULT_DEVICE_MODE`, which selects the USB
configuration the device should switch to. Mode `3` enables CDC-NCM, the
standard USB Ethernet protocol Apple uses for tethering.

Most distribution packages predate this option or do not enable it, so the
daemon must be built from upstream and started with the variable set. Once the
mode is active, the kernel binds `cdc_ncm` and creates the interfaces.

Verify the mode was applied:

```bash
journalctl -u usbmuxd --since "5 minutes ago" | grep -i ncm
```

A healthy log contains a line similar to:

```text
Found CDC-NCM and Apple USB Multiplexor in device ... configuration ...
```

Check that the kernel created the interfaces:

```bash
ip -br link | grep -E '^usb[0-9]'
```

## The two interfaces

The iPad exposes two CDC-NCM functions:

| Interface | Purpose | What to do |
|-----------|---------|------------|
| `usb0` (data) | Carries the actual network traffic | Give it an address and DHCP |
| `usb1` (private) | Apple internal services | Leave unmanaged |

Names are not guaranteed. They can differ between machines, kernel versions and
reconnects, and the kernel may use predictable names such as
`enp118s0f3u1c5i2` instead. Always identify the interface by inspecting it, not
by assuming `usb0`.

Useful identifiers:

```bash
ip -br link
ip -d link show
udevadm info --query=property --name=usb0 | grep -E 'ID_USB_DRIVER|ID_NET_DRIVER'
```

The data interface is the one whose driver is `cdc_ncm` and which carries the
DHCP exchange. The private one must be excluded in NetworkManager:

```ini
# /etc/NetworkManager/conf.d/99-ipad-private-unmanaged.conf
[keyfile]
unmanaged-devices=interface-name:usb1
```

Prefer matching the interface name locally; if it changes, match by driver and
MAC address instead.

## Sharing the connection

`ipv4.method shared` tells NetworkManager to act as the DHCP server and router
for that interface. It is not "internet sharing" in the usual sense here: both
ends are the same cable, and the iPad only needs an address to reach Sunshine.

Create the profile once:

```bash
nmcli connection add \
  type ethernet \
  con-name iPad-USB-Tethering \
  ifname usb0 \
  ipv4.method shared \
  ipv6.method disabled
```

Activate it:

```bash
nmcli connection up iPad-USB-Tethering
```

NetworkManager then assigns the host address and starts dnsmasq:

```bash
ip -4 addr show dev usb0        # expect 10.42.0.1/24
ss -lunp | grep ':67'           # dnsmasq listening for DHCP
```

The `10.42.0.0/24` subnet is NetworkManager's default for shared mode. The
iPad receives an address from the DHCP pool (`10.42.0.10`–`10.42.0.254` in
practice) and its address can change on every reconnect.

## The firewall trap

Symptom: the interface exists, dnsmasq is listening, but the iPad keeps asking
and never gets an address.

DHCP clients send from `0.0.0.0` to the broadcast address on UDP/67. A
default-deny firewall drops those packets before dnsmasq sees them. A rule
scoped to the USB interface is enough:

```bash
ufw allow in on usb0 proto udp to any port 67 comment 'iPad USB DHCP'
```

Do not open DHCP globally and do not disable the firewall. If UFW is not in
use, the equivalent rule belongs in whatever firewall manager is active.

Confirm the full handshake in the logs:

```bash
journalctl -u NetworkManager --since "2 minutes ago" | grep -E 'DHCP(OFFER|ACK)'
```

A working exchange looks like:

```text
DHCPDISCOVER(usb0) ...
DHCPOFFER(usb0) 10.42.0.42 ...
DHCPREQUEST(usb0) 10.42.0.42 ...
DHCPACK(usb0) 10.42.0.42 ... iPad
```

## Verifying connectivity

```bash
ip neigh show dev usb0          # the iPad's current address
ping -c 4 <ipad-address>
```

Latency over the cable is typically around 1–3 ms with no packet loss.

## Which address goes where

| Address | Belongs to | Used by |
|---------|-----------|---------|
| `10.42.0.1` | Linux host | Moonlight connects here |
| `10.42.0.x` | iPad (DHCP) | Only for diagnostics |

The most common mistake is entering the iPad's own address in Moonlight. The
client must connect to the **host**.

## Failure checklist

1. Does the cable support data? Some USB-C cables are power-only.
2. Is the iPad unlocked and trusted?
3. Is `usbmuxd` running the build with NCM mode enabled?
4. Did the kernel create the interfaces? (`ip -br link`)
5. Is the NetworkManager profile bound to the correct interface?
6. Does the host have `10.42.0.1/24`?
7. Is DHCP allowed through the firewall?
8. Does the iPad have a lease? (`ip neigh`, NetworkManager logs)
9. Does `ping` work?
