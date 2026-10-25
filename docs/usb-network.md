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

Most distribution packages predate this option, so the daemon must be built from
upstream and started with the variable set. The exact reason, the full stack and
the verification commands are in [dependencies.md](dependencies.md).

Once the mode is active, the kernel binds `cdc_ncm` and creates the interfaces.

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

## The first seconds after plugging in

Plugging the cable is not instantaneous, and the sequence explains a confusion
that costs time: for a few seconds the iPad is on the bus with **no `usbN`
interface at all**.

1. The kernel enumerates the device in its default configuration.
2. `usbmuxd` detects it and asks for the data mode; the device re-enumerates.
3. The CDC-NCM interfaces appear (`usb0` for data, `usb1` for the Apple
   multiplexor).
4. NetworkManager activates the shared profile and starts its DHCP server.
5. The iPad asks for an address and gets one.

Between steps 1 and 3 there is nothing to inspect, so a report issued in that
window is not evidence of a fault. `ivm` waits instead of failing: `ivm net up`
waits up to 10 seconds for the interface and says it is waiting, `ivm net status`
gives it 3 seconds and then reports a `warn` rather than a `fail`, and `ivm up`
and `ivm doctor` wait before deciding the same thing.

Measured on the reference machine by sampling sysfs every half second while
unplugging and replugging: the gap was **under one second**, and the address and
the peer were there in the next sample. It is easy to catch anyway, because
plugging the cable and typing a command take about the same time — which is
exactly how it was found. The timeouts above are margin for a colder plug, not a
measurement of the gap.

If the interface never appears, the problem is `usbmuxd`: it must be the build
that requests the device mode. See [dependencies.md](dependencies.md).

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

**The rule must not name an address.** This is the trap that costs the most time,
because it almost works:

```text
### this allows renewals, not new leases
-A ufw-user-input -i usb0 -p udp -d 10.42.0.1 --dport 67 -j ACCEPT
### this allows the whole exchange
-A ufw-user-input -i usb0 -p udp --dport 67 -j ACCEPT
```

A client with a lease renews it by talking straight to the server, so the first
rule passes. A client with no lease has no address yet: it sends from `0.0.0.0`
to `255.255.255.255`, and a rule restricted to `10.42.0.1` does not match that
packet. The symptom is an iPad that works until it reconnects and then never gets
an address again. `ivm net status` reports the two cases separately, and
`ivm net up` adds the interface-wide rule without removing yours.

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

## Doing all of this with `ivm net`

Everything on this page can be inspected and repaired from the CLI:

```bash
ivm net status     # read-only report: link, address, profile, DHCP, firewall
ivm net up         # converge it: plan, one question, then apply
ivm net down       # deactivate the shared connection, keep the configuration
```

The interesting part is how `up` handles root. Almost every repair here needs it
— the connection profile, the NetworkManager configuration, the firewall rule —
so the tool derives a plan from the current state, prints the exact commands, and
asks once before running any of them:

```text
  plan sudo nmcli connection modify iPad-USB-Tethering ipv4.method shared ...
  plan sudo tee /etc/NetworkManager/conf.d/99-ivm-usb.conf
       [keyfile]
       unmanaged-devices=interface-name:usb1
  plan sudo ufw allow in on usb0 to any port 67 proto udp

Apply 3 command(s) with sudo? [y/N]
```

Three properties are worth knowing:

- **It adopts what is already there.** The profile is the one NetworkManager has
  on the interface, whatever its name; a healthy profile produces no command at
  all. Nothing is renamed, recreated or removed.
- **It reads the result back.** A plan that reports success is followed by the
  address, the DHCP listener and a ping, so "it ran" and "it works" are not
  confused.
- **It refuses to act silently.** `--dry-run` stops after the plan, `--yes`
  applies it without asking, and without a terminal nothing is applied.

`down` deactivates the shared connection and leaves every configuration file in
place, so the next `net up` (or the next time the cable is plugged in) is
instant. It exists for testing: if the network layer is not the problem, turning
it off and on again should not change the symptom.

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
