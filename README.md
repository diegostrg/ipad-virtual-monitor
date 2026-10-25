# iPad Virtual Monitor (ivm)

Use your iPad as a **second, extended display** on Linux over a single USB-C
cable!

The iPad is not a physical monitor: the host creates an extra virtual output,
Sunshine encodes it, and Moonlight on the iPad displays it. The same cable
carries the video stream and a private USB network between the two devices.

It is built to keep working: turn on the PC, plug in the iPad, open Moonlight,
connect!!! :)))

---


![A laptop with the iPad on a stand beside it, the iPad showing a terminal as an extended desktop](docs/images/laptop-and-ipad.jpg)

*Extended, not mirrored: the iPad has its own workspace, windows and cursor.*

![Moonlight statistics: 2360x1640 at 60 fps, HEVC, 0% frames dropped, 2 ms of network latency](docs/images/moonlight-latency.png)

*2360x1640 at 60 fps, HEVC, no dropped frames, 2 ms of network latency.*

---
## How it works


Four layers, each one useless without the next:

1. **USB link** — `usbmuxd` puts the iPad in the USB mode that exposes a CDC-NCM
   network interface.
2. **Network** — NetworkManager shares that interface and hands the iPad an
   address over DHCP; the firewall allows it.
3. **Display** — the compositor creates a virtual output that behaves like a real
   second monitor.
4. **Stream** — Sunshine captures that output and serves it to Moonlight over the
   USB network.

Each layer has its own document under [docs/](docs/).


---
## Requirements

| Component | Notes |
|-----------|-------|
| Linux with systemd | Tested on CachyOS (Arch-based) |
| Wayland compositor | Hyprland is the first supported target |
| NetworkManager | Used to share the USB interface |
| `usbmuxd` with NCM support | Distro packages cannot switch the USB mode; `ivm deps` detects it and can build the stack |
| Sunshine | Host-side streaming server |
| Moonlight | iPad app, from the App Store |
| USB-C cable | Must carry data, not just power |

Optional: UFW, which is only configured when it is already active.

---
## Install

One command. It runs as your user, prints its plan first, and asks once:

```bash
curl -fsSL https://raw.githubusercontent.com/diegostrg/ipad-virtual-monitor/main/install.sh | bash
```

It installs the tool into `~/.local/share/ipad-virtual-monitor` and links `ivm`
into `~/.local/bin`, builds the Apple USB stack when needed, installs Sunshine,
sets up the USB network and prepares the streaming host. Steps already done are
skipped, so a second run is boring. Privileged steps call `sudo` one command at a
time, after you have seen them.

Plug the iPad in before the first run: the network step needs it. Without the
cable everything else is done and the installer tells you to run it again.

To read it before trusting it:

```bash
curl -fsSLO https://raw.githubusercontent.com/diegostrg/ipad-virtual-monitor/main/install.sh
less install.sh
bash install.sh --dry-run   # the plan, printed and nothing else
bash install.sh
```

---
## Usage

```bash
ivm up        # prepare the host
ivm status    # where things stand
ivm doctor    # walk every layer when something is wrong
```

Then connect from Moonlight. `status` and `doctor` are read-only, so run them as
often as you like.

```text
ivm status 0.1.0-dev
  host         CachyOS, hyprland 0.56.2
  network      usb0 10.42.0.1/24, iPad at 10.42.0.42
  sunshine     running, capturing with wlr
  prep hook    [{"do":"/home/you/.local/bin/ivm display prep"}]
  display      absent (created when a client connects)
  supervisor   running
```

| Command | What it does |
|---------|--------------|
| `ivm up` / `down` | prepare the host / undo the runtime state |
| `ivm status` | one short screen with the state of every layer |
| `ivm doctor` | read-only survey; `--report` prints a sanitized copy for an issue |
| `ivm net` | report, set up or tear down the USB network (asks before `sudo`) |
| `ivm deps` | inspect the Apple USB stack, or build it from source |
| `ivm display` | create, remove and inspect the virtual output by hand |
| `ivm watch` | the supervisor: removes the output when the stream ends |
| `ivm completion` | a completion script for bash, zsh or fish |

`ivm help` lists the commands and `ivm help <command>` explains one of them.
Every command also accepts `--help`, and the ones that change something accept
`--dry-run`. The full reference, with sample output, is in
[docs/commands.md](docs/commands.md).

---
## Configuration

`ivm` reads `~/.config/ivm/config` if it exists. Every key is optional:

```ini
OUTPUT_NAME=MOONLIGHT   # name of the virtual output
SIDE=right              # right, left, above or below the laptop panel
WIDTH=2360              # fallback size when the client does not ask for one
HEIGHT=1640
FPS=60
SCALE=1.6               # 0.5 to 4; must divide the size exactly
FOLLOW_CLIENT=yes       # prefer the size and rate Moonlight requests
GRACE=20                # seconds to wait before removing the output
NOTIFY=yes              # desktop notice before Sunshine is restarted
```

Values are validated and the file is parsed, never sourced.

A scale only sticks when it divides both dimensions into whole pixels, so pair it
with the size it divides: `2360x1640` at `1.6` works, `1920x1334` falls back to
`1.0` and says so. With `FOLLOW_CLIENT=yes`, Moonlight's own resolution setting
still wins: *Full / Safe Area* keeps the scale, *PC/Game resolution* drops it.

---
## Something is wrong?

```bash
ivm doctor            # the first fail is the one to fix
ivm doctor --report   # sanitized, ready to paste into an issue
```

[docs/troubleshooting.md](docs/troubleshooting.md) maps symptoms to causes. When
the iPad shows a clone of the laptop panel, `ivm status` says so explicitly.

---
## Documentation

- [Commands](docs/commands.md) — every command, its flags and its output
- [Architecture](docs/architecture.md) — how the pieces fit together
- [Dependencies](docs/dependencies.md) — why the distro package is not enough
- [USB network](docs/usb-network.md) — from cable to DHCP lease
- [Video pipeline](docs/video-pipeline.md) — virtual output and capture
- [Hyprland setup](docs/hyprland-setup.md) — what to add to your dotfiles
- [Troubleshooting](docs/troubleshooting.md) — symptom → cause → fix
- [Roadmap](docs/roadmap.md) — what is done and what comes next

---
## Soooome Credits!

The USB networking approach is inspired by
[hkfuertes/virtual-screen](https://github.com/hkfuertes/virtual-screen), which
documents the `usbmuxd` device mode and the NetworkManager shared connection.
That guide targets X11; this project adapts the idea to Wayland. Take a look if
you are on X11 or Linux Mint.

---
## Status

Early development, verified on Hyprland under CachyOS. Other compositors are
planned but not claimed; reports from other setups are welcome. See
[docs/roadmap.md](docs/roadmap.md).

---
## License

MIT — see [LICENSE](LICENSE). Fork it, change it, ship it, sell it: the only
condition is keeping the copyright notice. A mention is appreciated, but not
required! :)
