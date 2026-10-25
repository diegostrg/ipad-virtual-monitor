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
│ 3. Display     compositor virtual output (IPAD)                      │
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

The tool creates the output with an explicit name (`IPAD`), which makes the
name predictable and lets Sunshine point at it permanently.

### Layer 4 — Stream

Sunshine captures the `IPAD` output with its wlr backend and encodes it to
H.264/HEVC. Moonlight on the iPad connects to the host's USB address
(`10.42.0.1`), not to the iPad's own address.

Because the output is created on demand, the tool registers Sunshine
`global_prep_cmd` / `global_undo_cmd` hooks:

- before a stream starts, create `IPAD` at the resolution the client asked for;
- when the stream ends, remove it.

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
`hyprctl output create headless IPAD` gives a name the tool controls.
Sunshine's `output_name` never has to change.

**D3 — Let the client decide the resolution.**
Sunshine exposes the client's requested width, height and refresh rate to prep
commands. The output is created at that exact size instead of a hardcoded guess,
which keeps pixels 1:1 and avoids scaling blur.

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

## Runtime model

The CLI is a thin orchestrator. There is no long-running daemon of its own:

```text
ivm up      = ensure network → ensure output → ensure Sunshine → print endpoint
ivm status  = inspect each layer, report state
ivm down    = stop stream-dependent output → optionally bring network down
```

State is derived from the system (`ip`, `nmcli`, `hyprctl`, `systemctl`) rather
than stored. A small runtime file is used only to remember values that cannot
be discovered, such as the refresh rate chosen for the current session.

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
