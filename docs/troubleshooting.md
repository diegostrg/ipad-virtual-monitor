# Troubleshooting

Diagnose in layers, in this order. A problem in layer 1 looks like a problem in
layer 4, so never start with Sunshine.

```text
1. USB link  →  2. IP network  →  3. virtual output  →  4. stream
```

`ivm doctor` (planned) automates this walk. Until then, use the checks below.

## Quick matrix

| Symptom | Most likely layer | First check |
|---------|-------------------|-------------|
| No `usbX` interface appears | 1 — USB link | `lsusb`, `journalctl -u usbmuxd` |
| Interface exists, iPad has no IP | 2 — DHCP/firewall | `ip -4 addr show dev usb0`, UFW UDP/67 |
| Ping fails | 2 — addressing | `ip neigh show dev usb0` |
| Ping works, Moonlight cannot find host | 2/4 — firewall or listening address | `ss -lntup` |
| Moonlight connects, black screen | 3 — virtual output | `hyprctl monitors` |
| Image appears but is blurry | 3 — resolution | output mode vs client request |
| Works after manual setup, breaks after reboot | 3 — ephemeral output | nothing recreates `IPAD` |
| Works in terminal, fails from Sunshine | 4 — service environment | `HYPRLAND_INSTANCE_SIGNATURE` |
| Input does not reach the host | 4 — permissions | uinput / udev rules |

## Layer 1 — no USB network interface

Check that the device is seen at all:

```bash
lsusb | grep -i apple
```

If the iPad is missing, the cable is power-only, the port is not a data port, or
the iPad is locked. Try another cable before anything else.

If the device is present but no `usb*` interface exists:

```bash
journalctl -u usbmuxd --since "5 minutes ago"
ip -br link
```

Look for the NCM line in the log. Absence means `usbmuxd` is not running the
build that understands `USBMUXD_DEFAULT_DEVICE_MODE=3`, or the drop-in is not
being applied.

```bash
systemctl cat usbmuxd
```

The effective unit must show the environment variable and the correct
`ExecStart` path. Re-apply after editing:

```bash
sudo systemctl daemon-reload
sudo systemctl restart usbmuxd
```

## Layer 2 — interface exists, no address

Confirm the host side first:

```bash
nmcli device status
nmcli connection show --active
ip -4 addr show dev usb0
```

`10.42.0.1/24` must be present. If it is not, the shared profile is down or
bound to the wrong interface. Interface names change; recreate the profile
against the current name if necessary.

Next, confirm the iPad is asking for an address:

```bash
sudo tcpdump -ni usb0 'port 67 or port 68'
```

- Requests with no replies → firewall is dropping them.
- No requests at all → layer 1 is not really up, or the wrong interface is
  being watched.

Confirm dnsmasq is listening:

```bash
ss -lunp | grep ':67'
```

Then check the firewall rule:

```bash
sudo ufw status numbered
```

There must be an inbound UDP/67 rule scoped to the USB interface. The rule must
not be limited to the unicast address, because DHCP requests are broadcast.

The handshake is complete when the NetworkManager log shows
`DHCPDISCOVER`, `DHCPOFFER`, `DHCPREQUEST` and `DHCPACK`.

### The iPad's address keeps changing

Expected. The lease is not reserved. Never hardcode the iPad's address; only
`10.42.0.1` (the host) is stable. To find the current address:

```bash
ip neigh show dev usb0
```

### `usb1` keeps trying to connect

That is Apple's private interface. Mark it unmanaged in NetworkManager instead
of letting it negotiate:

```ini
# /etc/NetworkManager/conf.d/99-ipad-private-unmanaged.conf
[keyfile]
unmanaged-devices=interface-name:usb1
```

## Layer 3 — no virtual output

```bash
hyprctl monitors
hyprctl monitors all
```

`IPAD` must be listed while a stream is active. If it is missing, Sunshine has
nothing to capture and the client sees a black screen.

Check the name Sunshine is configured to use:

```bash
grep -E 'output_name|capture' ~/.config/sunshine/sunshine.conf
```

If it points at `HEADLESS-1` (or any other stale name), it will never match.
The generated `HEADLESS-n` names are not stable; use the explicit `IPAD` name.

Check the compositor dialect before issuing runtime commands:

```bash
hyprctl keyword monitor IPAD,1920x1334@60,1920x0,1   # legacy configs
hyprctl eval 'hl.monitor({output="IPAD", mode="1920x1334@60", position="1920x0", scale=1.0})'   # Lua configs
```

`keyword can't work with non-legacy parsers` means you are on the Lua dialect.

### The output exists but nothing is rendered

Confirm it has a workspace and is enabled:

```bash
hyprctl monitors all -j | jq '.[] | {name, disabled, width, height}'
hyprctl workspaces -j
```

A disabled output is still listed by `monitors all` but is not rendered.

## Layer 4 — stream

Confirm Sunshine is running and listening on all interfaces:

```bash
systemctl --user status sunshine
ss -lntup | grep -E '47984|47989|48010'
```

`127.0.0.1:47989` means it is bound to loopback only; the iPad will never reach
it. It must be `0.0.0.0:47989` or the USB address.

Confirm the firewall allows Sunshine's ports on the USB interface. The safest
approach is to scope the rules to `usb0` rather than opening them globally.

### Moonlight cannot find the host

Automatic discovery often fails across point-to-point interfaces. Add the host
manually:

```text
10.42.0.1
```

Do not enter the iPad's own address.

### Connection works, black screen

The output is missing (see layer 3), or Sunshine is capturing a different
output. Enable verbose logging:

```bash
journalctl --user -u sunshine -f
```

Look for the output name Sunshine selected at capture start.

### `hyprctl` fails when called from Sunshine

Sunshine needs the compositor's environment. A user service started outside the
graphical session may not have it:

```bash
systemctl --user show-environment | grep -E 'HYPRLAND|WAYLAND'
```

If those variables are missing, fix how the service is started rather than
hardcoding them.

### Input does not work

Mouse and keyboard injection needs `/dev/uinput`. Check the permissions and the
udev rule shipped with Sunshine. This is independent of the display pipeline.

## Collecting a useful bug report

```bash
ivm doctor --report      # planned
```

Until then, include:

- distro and kernel version,
- Hyprland version and config dialect,
- Sunshine version and the relevant config keys,
- `ip -br link`, `ip -4 addr`, `ip neigh`,
- `hyprctl monitors all`,
- the last 50 lines of `journalctl -u usbmuxd` and NetworkManager,
- whether `ping` to the iPad works.

Remove serial numbers and MAC addresses before publishing.
