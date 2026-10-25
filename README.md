# iPad Virtual Monitor

Use an iPad as a **second, extended display** on Linux over a single USB-C cable.

No Wi-Fi, no cloud, no dongles. The iPad is not a physical monitor: the host
creates an extra virtual output, Sunshine encodes it, and Moonlight on the iPad
displays it. The same cable carries both the video stream and a private USB
network between the two devices.

```text
        Linux host                                      iPad
┌────────────────────────┐      USB-C / CDC-NCM      ┌──────────────┐
│  IPAD (virtual output) │                           │              │
│  Sunshine              │──── H.264 / HEVC  ──────► │  Moonlight   │
│  10.42.0.1             │◄─── mouse / keyboard ──── │  10.42.0.x   │
└────────────────────────┘      DHCP / 10.42.0.0/24  └──────────────┘
```

## Status

**Early development.** The repository is being built phase by phase; see
[docs/roadmap.md](docs/roadmap.md). At this point it contains the design and the
documented procedure, not a finished CLI.

## Why another guide?

Most existing guides assume X11 and force an HDMI connector through `xrandr`,
or they ask you to compile the entire libimobiledevice stack by hand and follow
a dozen manual steps.

This project targets modern Wayland desktops first (Hyprland) and aims to turn
that manual procedure into one idempotent, inspectable command that you can run,
audit and undo.

## How it works

Four layers, each one useless without the next:

1. **USB link** — Apple devices expose a CDC-NCM network interface only in the
   right USB device mode. `usbmuxd` requests that mode.
2. **Network** — NetworkManager turns the USB interface into a shared network
   and hands the iPad an address over DHCP. The firewall must allow it.
3. **Display** — the compositor creates a virtual output that behaves like a
   real second monitor.
4. **Stream** — Sunshine captures that output and serves it to Moonlight over
   the USB network.

The details of each layer live in [docs/](docs/).

## Requirements

| Component | Notes |
|-----------|-------|
| Linux with systemd | Tested on CachyOS (Arch-based) |
| Wayland compositor | Hyprland is the first supported target |
| NetworkManager | Used to share the USB interface |
| `usbmuxd` with NCM support | Distro packages may be too old; the CLI detects this |
| Sunshine | Host-side streaming server |
| Moonlight | iPad app, from the App Store |
| USB-C cable | Must support data, not just power |
| Optional: UFW | Only configured when it is active |

## Documentation

- [Architecture](docs/architecture.md) — how the pieces fit together
- [Dependencies](docs/dependencies.md) — why the distro package is not enough
- [USB network](docs/usb-network.md) — from cable to DHCP lease
- [Video pipeline](docs/video-pipeline.md) — virtual output and capture
- [Hyprland setup](docs/hyprland-setup.md) — what to add to your dotfiles
- [Troubleshooting](docs/troubleshooting.md) — symptom → cause → fix
- [Roadmap](docs/roadmap.md) — what is done and what comes next

## Credits

The USB networking approach is inspired by
[hkfuertes/virtual-screen](https://github.com/hkfuertes/virtual-screen), which
documents the `usbmuxd` device mode and the NetworkManager shared connection.
That guide targets X11; this project adapts the idea to Wayland.

## License

MIT — see [LICENSE](LICENSE).
