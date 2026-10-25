# Architecture

## Goal

Make an iPad behave like a second, extended monitor on Linux, over a single
USB-C cable, with the lowest possible setup effort and no hidden magic.

"Extended" matters: the iPad must show its own desktop area, not a copy of the
laptop screen.

## Non-goals

- Supporting every compositor on day one. Hyprland is the first target; the
  design keeps compositor-specific code isolated so others can be added.
- Replacing Sunshine or Moonlight. They are the video path and they already
  work well.
- Being a GUI application. The tool is a terminal-first CLI.
- Owning the user's dotfiles. The repository documents what to add; it does not
  rewrite Hyprland configuration behind the user's back.
- Working without a cable. Wireless streaming is a different problem and
  already solved by Sunshine/Moonlight on its own.

## The four layers

```text
┌──────────────────────────────────────────────────────────────────────┐
│ 4. Stream      Sunshine ──► USB network ──► Moonlight (iPad)         │
├──────────────────────────────────────────────────────────────────────┤
│ 3. Display     compositor virtual output (MOONLIGHT)                      │
├──────────────────────────────────────────────────────────────────────┤
│ 2. Network     NetworkManager shared + DHCP + firewall               │
├──────────────────────────────────────────────────────────────────────┤
│ 1. USB link    usbmuxd requests CDC-NCM mode, kernel creates usbX    │
└──────────────────────────────────────────────────────────────────────┘
```

Each layer can fail independently and each failure looks different to the
user. That is why the CLI is built around a single diagnostic command
(`ivm doctor`) that walks the layers in order and reports the first broken one.

### Layer 1 — USB link

An iPad connected to a Linux host is, by default, a media device: it exposes
the usbmux protocol for backups and device management, not a network card.

Requesting USB device mode `3` through `usbmuxd` makes the device expose
CDC-NCM interfaces. The Linux kernel then creates two network interfaces,
typically `usb0` (data) and `usb1` (Apple's private channel).

Without this layer there is no network at all, and no amount of Sunshine
configuration will help.

### Layer 2 — Network

The CDC-NCM interfaces provide a link, not an IP network. NetworkManager, in
`shared` mode, supplies both:

- an address for the host (`10.42.0.1/24` by default),
- a DHCP server (dnsmasq) for the iPad.

The firewall is the classic trap: DHCP requests are broadcast to UDP/67, which
a default-deny firewall drops. A single rule scoped to the USB interface fixes
it without weakening the rest of the system.

### Layer 3 — Display

Wayland has no `xrandr`. Hyprland exposes `hyprctl output create headless`,
which creates a real output that the compositor renders and that behaves like
a second monitor.

Two properties of that mechanism drive the whole design:

1. **Virtual outputs are ephemeral.** They disappear when the compositor
   restarts. They must be created when needed, not assumed to exist.
2. **Generated names are not stable.** `HEADLESS-1`, `HEADLESS-2`, ... come
   from a counter that is never reused within a session. A fixed
   `output_name = HEADLESS-1` in Sunshine therefore breaks the first time the
   output is recreated.

The tool creates the output with an explicit name (`MOONLIGHT`), which makes the
name predictable and lets Sunshine point at it permanently.

### Layer 4 — Stream

Sunshine captures the `MOONLIGHT` output and encodes it to H.264/HEVC. Moonlight on
the iPad connects to the host's USB address (`10.42.0.1`), not to the iPad's own
address.

`capture = wlr` is mandatory: the KMS backend does not see headless outputs and
silently falls back to the laptop panel, producing a clone instead of an
extension.

### Cross-cutting — Lifecycle

The output must exist before capture starts and disappear when the session ends.
Sunshine only provides the first half of that contract:

- `global_prep_cmd` runs before the capture target is selected (about 105 ms of
  margin), so it can create the output.
- `global_undo_cmd` runs at process termination, not on disconnect, so it cannot
  clean up.
- The disconnect event is not reliably logged when the Desktop app is used.

The tool therefore runs a small supervisor that reconciles the desired state
with the real one every second, using the session threads Sunshine exposes in
`/proc/<pid>/task/*/comm`, plus a grace period before removing the output.

## Why not other approaches

| Approach | Why it is not the default |
|----------|---------------------------|
| Mirroring the main screen | Does not extend the desktop |
| `xrandr` + forced HDMI connector | X11 only; not available on Wayland |
| `evdi` / DisplayLink driver | Out-of-tree kernel module, fragile across kernel upgrades |
| A fake HDMI dongle | Extra hardware; fixed resolution |
| Streaming the whole desktop | Still mirroring, and the iPad becomes a scaled copy |

## Design decisions

**D1 — Manage the output lifecycle, do not persist it.**
Creating a permanent virtual monitor at login leaves an invisible region on the
desktop and a monitor the user cannot see. Creating it only while streaming
keeps the desktop honest.

**D2 — Deterministic output name.**
`hyprctl output create headless MOONLIGHT` gives a name the tool controls.
Sunshine's `output_name` never has to change.

**D3 — Prefer the client's resolution, with a known fallback.**
Sunshine exposes the client's requested width, height and refresh rate to prep
commands. When those values are available the output is created at that exact
size, which keeps pixels 1:1. When they are not, the tool falls back to a known
profile (1920×1334 for an iPad Air 11"). Today the fallback is the verified path;
the client-driven path must be validated end to end before it becomes the
default.

**D4 — Idempotent operations.**
`up` twice must be harmless. `down` when nothing is running must succeed.
Every action checks the current state first.

**D5 — Detect, never assume.**
Interface names (`usb0` today, something else tomorrow), config dialects
(Lua vs legacy Hyprland), binary paths (`/usr/local/sbin/usbmuxd` vs
`/usr/bin/usbmuxd`) and service managers are discovered at runtime.

**D6 — Read-only by default.**
`doctor` and `status` never change the system. System changes happen only in
explicit commands, and the CLI prints the exact commands it is about to run
before using `sudo`.

**D7 — The repository does not own your dotfiles.**
Hyprland snippets are documented in
[hyprland-setup.md](hyprland-setup.md) and installed manually by the user.
This keeps upgrades safe and makes the project easy to remove.

**D8 — Supervise the lifecycle; do not trust logs.**
Creation is triggered by Sunshine's prep command. Destruction is driven by the
presence of Sunshine's session threads plus a grace period. Log parsing is a
hint only, because the disconnect event is usually missing.

**D9 — Do not steal the user's focus.**
Creating an output moves the active window to it. The tool snapshots and
restores the focused monitor and the active window, so plugging in the iPad does
not take the keyboard away from the laptop.

## Runtime model

The CLI is a thin orchestrator plus one small user service:

```text
ivm up       = ensure network → ensure Sunshine configuration → print endpoint
ivm status   = inspect each layer, report state
ivm down     = remove the virtual output → optionally bring the network down
ivm watch    = reconcile the output with Sunshine's session state (service)
```

`watch` is the only long-running component. It runs as a systemd user unit, holds
no privileges, and exits safely when the compositor is unreachable.

State is derived from the system (`ip`, `nmcli`, `hyprctl`, `systemctl`, `/proc`)
rather than stored. A small runtime file is used only for values that cannot be
discovered, such as when the output was created, which the grace period needs.

## Security notes

- The DHCP rule is scoped to the USB interface and UDP/67. The firewall is never
  disabled and no port is opened on other interfaces.
- The tool never touches Sunshine credentials or pairing data.
- No traffic is routed to the internet through the iPad; `shared` mode is used
  only to provide addressing on the point-to-point link.

## Compatibility

| Component | Target | Notes |
|-----------|--------|-------|
| Compositor | Hyprland ≥ 0.4x (Wayland) | Virtual output support required |
| Hyprland config | Legacy `.conf` and Lua (≥ 0.56) | Detected at runtime |
| Init | systemd | Required by usbmuxd and Sunshine |
| Network | NetworkManager | `shared` mode |
| Firewall | UFW optional | Other firewalls reported, not modified |
| Distro | Arch-based first | Detection is generic; packaging is not |

See [roadmap.md](roadmap.md) for what is implemented today.
