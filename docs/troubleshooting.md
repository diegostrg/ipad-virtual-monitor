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
| Sunshine's monitor list has no `MOONLIGHT` | 3 — output missing | `hyprctl monitors`, supervisor state |
| iPad shows a clone of the laptop | 4 — capture backend | `capture` must be `wlr`, not `kms` |
| Image appears but is blurry | 3 — resolution | output mode vs client request |
| Keyboard stops responding after connecting | 3 — focus side effect | active window moved to `MOONLIGHT` |
| Keyboard and mouse work from the iPad, but the host cursor cannot reach it | 3 — layout | gap or overlap in `hyprctl monitors` |
| Works after manual setup, breaks after reboot | 3 — ephemeral output | nothing recreates `MOONLIGHT` |
| Output never disappears after disconnect | lifecycle — supervisor | `systemctl --user status ivm-watch` |
| Works in terminal, fails from Sunshine | 4 — service environment | `HYPRLAND_INSTANCE_SIGNATURE` |
| Input does not reach the host | 4 — permissions | uinput / udev rules |
| Nothing works after a reboot, Moonlight cannot reach the host | 4 — Sunshine not running | `systemctl --user status ...Sunshine` |

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

`MOONLIGHT` must be listed while a stream is active. If it is missing, Sunshine has
nothing to capture and the client sees a black screen.

Check the name Sunshine is configured to use:

```bash
grep -E 'output_name|capture' ~/.config/sunshine/sunshine.conf
```

If it points at `HEADLESS-1` (or any other stale name), it will never match.
The generated `HEADLESS-n` names are not stable; use the explicit `MOONLIGHT` name.

Check the compositor dialect before issuing runtime commands:

```bash
hyprctl keyword monitor MOONLIGHT,1920x1334@60,1920x0,1   # legacy configs
hyprctl eval 'hl.monitor({output="MOONLIGHT", mode="1920x1334@60", position="1920x0", scale=1.0})'   # Lua configs
```

`keyword can't work with non-legacy parsers` means you are on the Lua dialect.

### The output exists but nothing is rendered

Confirm it has a workspace and is enabled:

```bash
hyprctl monitors all -j | jq '.[] | {name, disabled, width, height}'
hyprctl workspaces -j
```

A disabled output is still listed by `monitors all` but is not rendered.

### Sunshine's monitor list does not contain `MOONLIGHT`

At stream start Sunshine prints the outputs it can see:

```text
[wlgrab] Monitor 0 is eDP-1: AUO 0x1234  (eDP-1)
[wlgrab] Monitor 1 is MOONLIGHT:
```

If `MOONLIGHT` is missing from that list, nothing will be captured. Check whether the
output exists and whether the supervisor is running:

```bash
hyprctl monitors                          # does MOONLIGHT exist and is it enabled?
grep -E 'output_name|capture' ~/.config/sunshine/sunshine.conf
systemctl --user status ivm-watch         # is the supervisor running?
```

### Do not diagnose with `Selected monitor []`

Sunshine prints this line even when the stream works correctly:

```text
[wlgrab] Selected monitor [] for streaming
```

It appears on successful sessions too. It is noise from the capture backend, not
a status. Use the monitor list and the actual image instead.

### Overlapping virtual monitors

A leftover virtual output (for example a `vkms` connector) can be enabled at the
same position as `MOONLIGHT`. Two monitors overlapping in the layout cause windows to
land on an invisible area. Check for duplicates:

```bash
hyprctl monitors all -j | jq '.[] | "\(.name) x=\(.x) y=\(.y) disabled=\(.disabled)"'
```

### The host cursor cannot reach the iPad

The stream works, the image is correct, but the mouse stops at the edge of the
laptop panel and never enters the virtual output. The desktop layout is broken:
the outputs are not adjacent.

```bash
hyprctl monitors -j | jq -r '.[] | select(.disabled|not) | "\(.name) \(.x)..\(.x + .width)"'
```

```text
eDP-1      0..1920
MOONLIGHT  3840..6200     ← gaps between 1920 and 3840
```

The cursor cannot cross empty space. Two mistakes produce this:

- Computing the new position from a bounding box that **includes the virtual
  output itself**, so it lands to the right of where it already was.
- Placing the output at a hardcoded coordinate while the laptop panel has a
  different width.

The fix is to compute the position from everything except the virtual output,
and to pick the edge the user actually wants:

| Value | Position |
|-------|----------|
| `right` | `x = max(right edge)`, `y = min(y)` |
| `left` | `x = min(x) - width`, `y = min(y)` |
| `above` | `x = min(x)`, `y = min(y) - height` |
| `below` | `x = min(x)`, `y = max(bottom)` |

Overlapping outputs cause the opposite symptom: the cursor enters a monitor that
is not the one expected, and windows land on an invisible area.

### The keyboard stops responding after connecting

Creating an output moves the focus to it and takes the active window along. The
window still exists; it is on the virtual monitor's workspace, which is not
visible on the laptop panel.

Recover it without touching the mouse:

```bash
hyprctl clients -j | jq -r '.[] | "\(.address) \(.workspace.id) \(.title)"'
hyprctl dispatch movewindowtomonitor eDP-1
hyprctl dispatch focusmonitor eDP-1
```

The tool prevents this by snapshotting the focused monitor and active window
before creating the output and restoring them afterwards. If it happens anyway,
the snapshot/restore step failed — check the supervisor log.

## Layer 4 — stream

Confirm Sunshine is running and listening on all interfaces:

```bash
systemctl --user status sunshine
ss -lntup | grep -E '47984|47989|48010'
```

`127.0.0.1:47989` means it is bound to loopback only; the iPad will never reach
it. It must be `0.0.0.0:47989` or the USB address.

Only the TCP ports are permanent. `47998`, `47999` and `48000` are UDP and only
open while a client is streaming, so their absence when idle is normal and not a
fault to chase.

Confirm the firewall allows Sunshine's ports on the USB interface. The safest
approach is to scope the rules to `usb0` rather than opening them globally.

### Sunshine is not running after a reboot

A user service ordered only against `default.target` can start **before** the
compositor. Sunshine then has no Wayland display to talk to and gives up:

```text
Error: Unable to initialize capture method
Error: Platform failed to initialize
Fatal: Unable to find display or encoder during startup.
```

It exits and, because the exit status is success, `Restart=on-failure` does not
bring it back. Moonlight never finds the host, and every other layer looks fine.

Check the uptime of the process against the session:

```bash
systemctl --user is-active app-dev.lizardbyte.app.Sunshine.service
journalctl --user -u app-dev.lizardbyte.app.Sunshine.service -b | grep -E 'Fatal|Found display'
```

`Found display [wayland-N]` must appear. If it does not, start the service by
hand once the desktop is up. A robust setup orders the unit after the
compositor's session target, or keeps a supervisor that starts it when needed.

### The iPad shows a clone of the laptop

The capture backend cannot see the virtual output and fell back to the laptop
panel. This happens with `capture = kms`, which logs:

```text
Unknown Monitor connector type [HEADLESS]
Couldn't map 'HEADLESS-1'
```

Set `capture = wlr` in `~/.config/sunshine/sunshine.conf` and restart Sunshine.
The wlr backend captures virtual outputs through `wlr-screencopy`.

### The output never disappears after disconnecting

Expected if nothing is supervising the lifecycle. `global_undo_cmd` is not a
disconnect hook: Sunshine runs it when the process terminates, not when the
client leaves. Check the supervisor:

```bash
systemctl --user status ivm-watch
journalctl --user -u ivm-watch -n 30
```

The output is removed only after the grace period, by design, so a quick
reconnect does not destroy and recreate the monitor.

### The disconnect never appears in the Sunshine log

Known behaviour, and the reason the lifecycle cannot be driven by logs.
`CLIENT DISCONNECTED` appears only when the client closes the session cleanly:

```text
2026-10-24 23:53:25.477 Info: CLIENT DISCONNECTED   ← quit from the app
```

Network loss, a killed app or a suspended tablet produce no line at all. Do not
build automation on that log line. Use the session threads instead:

```bash
pid=$(pgrep -x sunshine | head -1)
for t in /proc/"$pid"/task/*/comm; do cat "$t"; done | grep -E 'session::|video::capture'
```

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
