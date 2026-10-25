# Video pipeline

This document covers layers 3 and 4: turning a virtual output into a stream the
iPad can display.

## Why the virtual output is the missing piece

On X11 the usual trick is to force an HDMI connector on and drive it with
`xrandr`. Wayland has no equivalent, and on Hyprland the supported mechanism is
the headless backend:

```bash
hyprctl output create headless IPAD
```

This asks the compositor to allocate a new output. It behaves like a real
monitor: it has a resolution, a position, a scale and its own workspaces. It is
not visible on the laptop panel, which is exactly what we want.

Remove it with:

```bash
hyprctl output remove IPAD
```

### Two behaviours that shape the design

**Ephemeral.** The output lives only in the running compositor session. A
restart, a crash or a `hyprctl output remove` destroys it. Nothing in the
configuration file recreates it automatically, which is why a setup that
"worked yesterday" shows a black stream today.

**Unstable generated names.** Without an explicit name the compositor assigns
`HEADLESS-1`, `HEADLESS-2`, ... from a monotonic counter. The counter never
reuses a value within a session, so destroying and recreating the output yields
a different name. Pointing Sunshine at `HEADLESS-1` is therefore a race that
eventually loses.

Passing the name (`... headless IPAD`) makes it deterministic. Use that.

## Configuring the output

The mode, position and scale can be set at runtime. The exact command depends
on how Hyprland is configured:

**Legacy configuration (`hyprland.conf`)**

```bash
hyprctl keyword monitor IPAD,1920x1334@60,1920x0,1
```

**Lua configuration (Hyprland 0.56+)**

```bash
hyprctl eval 'hl.monitor({output="IPAD", mode="1920x1334@60", position="1920x0", scale=1.0})'
```

Note that `hyprctl keyword` fails with `keyword can't work with non-legacy
parsers` when a Lua config is active. The CLI detects the dialect instead of
assuming one.

The position is computed from the current layout rather than hardcoded, so the
virtual monitor lands to the right of the laptop panel regardless of its
resolution.

## Asking the client for its resolution

Hardcoding a resolution is wrong: the iPad's panel is not 16:9, and Moonlight
can request a different size. Sunshine exposes the client's requested values to
prep commands through environment variables, including width, height and
refresh rate.

The tool registers a pair of hooks in `~/.config/sunshine/sunshine.conf`:

```ini
output_name = IPAD
global_prep_cmd = [{"do":"ivm display prep","undo":"ivm display cleanup"}]
```

- `display prep` creates `IPAD` at the requested size and focus target.
- `display cleanup` removes it when the session ends.

The hooks must be idempotent: Sunshine may run them more than once, and a
failed previous session may have left an output behind.

### Ordering matters

Sunshine resolves `output_name` when it starts capturing. The prep command runs
before that, which is why the output must be created there and not after the
connection is accepted. If the output is missing at capture time, the stream
fails even though the network is healthy.

## Sunshine configuration

Minimum relevant keys:

```ini
capture = wlr
output_name = IPAD
```

| Key | Meaning |
|-----|---------|
| `capture` | Capture backend. `wlr` uses the wlroots screencopy protocol, which works on Hyprland without extra privileges. |
| `output_name` | Which output to capture. Must match the virtual output's name. |
| `encoder` | Video encoder. Leave it on auto until the stream works, then tune. |
| `minimum_fps_target` | Lower bound for frame pacing. |

Encoder choice on hybrid laptops:

- `vaapi` encodes on the integrated GPU, which usually also renders the
  compositor output. Cheapest path, no cross-GPU copy.
- `nvenc` uses the discrete NVIDIA GPU. It can produce better quality per bit
  at the cost of copying frames across GPUs.

Measure before changing it. A working stream with `vaapi` beats a stuttering
one with `nvenc`.

## Ports

Sunshine listens on all IPv4 interfaces by default, which is required for the
USB path:

| Port | Protocol | Purpose |
|------|----------|---------|
| 47984 | TCP | HTTPS |
| 47989 | TCP | HTTP |
| 48010 | TCP | RTSP |
| 47998–48000 | UDP | Video, control, audio |

Verify:

```bash
ss -lntup | grep -E '47984|47989|48010|47998|47999|48000'
```

The listening address must be `0.0.0.0` (or the USB address), not `127.0.0.1`.

## Workspaces

An output with no workspace is a blank rectangle. Assign dedicated workspaces
so windows can be moved to the iPad deliberately and stay there. See
[hyprland-setup.md](hyprland-setup.md) for the snippet; the repository does not
edit your configuration.

## End-to-end checklist

1. `ip -4 addr show dev usb0` shows `10.42.0.1/24`.
2. `ping` to the iPad succeeds.
3. `hyprctl monitors` lists `IPAD` while streaming.
4. Sunshine logs mention `IPAD`, not a `HEADLESS-n` name.
5. Moonlight connects to `10.42.0.1`, not to the iPad's address.
6. The iPad shows a desktop area, not a copy of the laptop screen.

## Known traps

- **Black screen, healthy network.** The configured output does not exist. Check
  `hyprctl monitors`.
- **Wrong resolution or blurry text.** The output was created at a guessed size.
  Use the client-provided values.
- **Works, then breaks after a reboot or a compositor restart.** Expected: the
  virtual output is gone and nothing recreated it.
- **`hyprctl` works in a terminal but not from Sunshine.** The service does not
  see `HYPRLAND_INSTANCE_SIGNATURE` / `WAYLAND_DISPLAY`. Check the unit's
  environment.
