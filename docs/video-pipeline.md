# Video pipeline

This document covers layers 3 and 4: turning a virtual output into a stream the
iPad can display, and keeping that output alive for exactly as long as a stream
lasts.

## Why the virtual output is the missing piece

On X11 the usual trick is to force an HDMI connector on and drive it with
`xrandr`. Wayland has no equivalent, and on Hyprland the supported mechanism is
the headless backend:

```bash
hyprctl output create headless MOONLIGHT
```

This asks the compositor to allocate a new output. It behaves like a real
monitor: it has a resolution, a position, a scale and its own workspaces. It is
not visible on the laptop panel, which is exactly what we want.

Remove it with:

```bash
hyprctl output remove MOONLIGHT
```

Two practical details, confirmed on real hardware:

- If an output with that name already exists, creation fails with
  `Name already taken`. That gives idempotency for free: "ensure it exists" is
  create, ignore that specific error, then verify.
- Creating or removing an output takes roughly 10 ms, which is fast enough to do
  it on demand before a stream starts.

If a monitor rule for the output exists in the Hyprland configuration, it is
applied automatically at creation time (mode, position, scale). The tool still
sets them explicitly, because it must not depend on the user's dotfiles.

### Two behaviours that shape the design

**Ephemeral.** The output lives only in the running compositor session. A
restart, a crash or a `hyprctl output remove` destroys it. Nothing in the
configuration file recreates it automatically, which is why a setup that
"worked yesterday" shows a black stream today.

**Unstable generated names.** Without an explicit name the compositor assigns
`HEADLESS-1`, `HEADLESS-2`, ... from a monotonic counter
(`CHeadlessBackend::createOutput`). The counter never reuses a value within a
session, so destroying and recreating the output yields a different name.
Pointing Sunshine at `HEADLESS-1` is therefore a race that eventually loses.

Passing the name (`... headless MOONLIGHT`) makes it deterministic. Use that.

## Why `capture = wlr` and not `capture = kms`

This is not a preference. KMS capture does not see headless outputs at all. With
`capture = kms` and `output_name = HEADLESS-1`, Sunshine logs:

```text
Unknown Monitor connector type [HEADLESS]
Couldn't map 'HEADLESS-1'
```

It then falls back to the first monitor it can find (`eDP-1`), and the iPad
shows a **clone** of the laptop screen instead of an extension.

The wlr backend uses `wlr-screencopy-unstable-v1`, which does capture virtual
outputs. The log then shows the enumeration explicitly:

```text
[wlgrab] Monitor 0 is eDP-1
[wlgrab] Monitor 1 is HEADLESS-1
[wlgrab] Selected monitor [ (HEADLESS-1)] for streaming
```

## Configuring the output

The mode, position and scale can be set at runtime. The exact command depends
on how Hyprland is configured:

**Legacy configuration (`hyprland.conf`)**

```bash
hyprctl keyword monitor MOONLIGHT,1920x1334@60,1920x0,1
```

**Lua configuration (Hyprland 0.56+)**

```bash
hyprctl eval 'hl.monitor({output="MOONLIGHT", mode="1920x1334@60", position="1920x0", scale=1.0})'
```

Notes that cost time to discover:

- `hyprctl keyword` fails with `keyword can't work with non-legacy parsers` when
  a Lua config is active.
- In the Lua API the position separator is `XxY` (`"1920x0"`), not `"X,Y"`.
  Passing `"1920,0"` produces `hl.monitor: error applying field 'position'`.
- `hl.monitor` **replaces** the rule for that output instead of merging it, so
  `mode`, `position` and `scale` must be passed together.
- `hyprctl eval` does not print return values, but the Lua state persists
  between calls. A value can be stored in a global and read by a later call.

The position is computed from the current layout rather than hardcoded, so the
virtual monitor lands to the right of the laptop panel regardless of its
resolution.

### Resolution and aspect ratio

The source resolution must match the tablet's aspect ratio or the client will
letterbox. For an iPad Air 11" (2360×1640) the exact equivalent is
**1920×1334** (ratio 1.4390).

Scaling does not change the stream: Sunshine captures the physical resolution
of the `wl_output`. Setting `scale = 1.5` only changes the logical size of the
virtual desktop; the encoded frame stays 1920×1334.

Sunshine exposes the client's requested dimensions to prep commands through
environment variables. The tool prefers those values when present and falls
back to a known profile (1920×1334 for this iPad). This needs to be verified
end to end before it becomes the default; see the roadmap.

## Lifecycle: who creates and destroys the output

The output must exist **before** Sunshine picks the capture target, and should
disappear **after** the stream ends. Both sides of that window are awkward.

### Creation: the prep command

`global_prep_cmd` runs on every stream launch. Measured order on real hardware:

```text
T+0.000   encoder probing starts
T+0.123   Executing [Desktop]        ← prep command runs here
T+0.189   CLIENT CONNECTED
T+0.228   capture target selected    ← ~105 ms after the prep command
```

Creating the output takes ~10 ms, so the margin is sufficient. Without the prep
command the output appears too late and Sunshine captures the laptop panel.

### Destruction: there is no reliable disconnect hook

`global_undo_cmd` is **not** a disconnect hook. It runs in `proc_t::terminate()`
— that is, on the next stream launch or when Sunshine shuts down — never when
the client disconnects. Using it to delete the output causes a
create/delete/create loop.

The log is not a reliable signal either. `CLIENT CONNECTED` is always written,
but `CLIENT DISCONNECTED` usually is not: with the Desktop app (placebo, id 0)
the control loop in `src/stream.cpp` stops iterating before it processes the
disconnect event.

The reliable signal is the set of threads Sunshine creates for a session:

```text
/proc/<sunshine-pid>/task/*/comm
  session::video
  session::audio
  video::capture
```

They exist only while a stream is running. Discarded alternatives: the UDP
control socket stays `UNCONN` even with a client, and the web API does not
expose session state.

### The supervisor

Because creation is event-driven but destruction is not, the tool runs a small
user service that reconciles the desired state with the real one:

```text
every second:
  if a session is active           → ensure MOONLIGHT exists
  else if idle for > grace period  → ensure MOONLIGHT is gone
```

The grace period (20 s in the reference setup) absorbs reconnects, client
resumes and short interruptions without destroying and recreating the monitor.

The supervisor is also a safety net: if the prep command never ran, it still
creates the output while a session is active.

## Focus side effects

Creating a monitor in a live session is not neutral:

- Hyprland moves the focus to the new monitor.
- The **active window moves with it** to the new monitor's workspace, which can
  leave the user typing into a window they can no longer see.

The tool snapshots the focused monitor, the active window address and its
workspace before creating the output, and restores them afterwards. Removing an
output has a smaller side effect: Hyprland centres the cursor on the remaining
monitor.

These are compositor behaviours, not bugs to work around silently; they are
documented so the user is not surprised.

## Sunshine configuration

Minimum relevant keys:

```ini
capture = wlr
output_name = MOONLIGHT
global_prep_cmd = [{"do":"ivm display prep"}]
```

| Key | Meaning |
|-----|---------|
| `capture` | `wlr` for virtual outputs. `kms` cannot see them. |
| `output_name` | Which output to capture. Must match the virtual output's name. |
| `encoder` | Video encoder. Leave it on auto until the stream works, then tune. |
| `minimum_fps_target` | Lower bound for frame pacing. |

Encoder notes from the reference machine (AMD 680M integrated GPU):

- `h264_vaapi` and `hevc_vaapi` work.
- `av1_vaapi` does not.
- A `hevc_vulkan` path was also observed working; measure before choosing.

Encoder choice on hybrid laptops:

- `vaapi` encodes on the integrated GPU, which usually also renders the
  compositor output. Cheapest path, no cross-GPU copy.
- `nvenc` uses the discrete NVIDIA GPU. Better quality per bit at the cost of
  copying frames across GPUs.

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

## Input and audio

Both were verified from the iPad in the end-to-end test:

- **Input** works through Sunshine's virtual HID device (`/dev/uinput`). Mouse
  and keyboard reach the host without extra configuration on this machine.
- **Audio** reaches the iPad, but it is also audible on the host: the captured
  sink keeps playing locally. Users who want it only on the iPad must change the
  audio routing themselves; the tool does not manage audio.

## Workspaces

Hyprland already does the heavy lifting: workspaces bound to a monitor move to
it when it appears, and move back (with their windows) when it disappears.

Two conditions:

- the workspace rules must exist and be loaded;
- the first workspace should use `default = true`, otherwise the new monitor
  takes the next free workspace number instead of the intended one.

See [hyprland-setup.md](hyprland-setup.md) for the snippet. The repository does
not edit your configuration.

## End-to-end checklist

1. `ip -4 addr show dev usb0` shows `10.42.0.1/24`.
2. `ping` to the iPad succeeds.
3. `hyprctl monitors` lists `MOONLIGHT` while streaming.
4. Sunshine's monitor list includes `Monitor N is MOONLIGHT`.
5. Moonlight connects to `10.42.0.1`, not to the iPad's address.
6. The iPad shows a desktop area, not a copy of the laptop screen.
7. The keyboard still works on the laptop after the output is created.
8. After disconnecting, `MOONLIGHT` disappears once the grace period expires.

## Known traps

- **Black screen, healthy network.** The configured output does not exist.
  Check `hyprctl monitors` and the monitor list in Sunshine's log. Note that
  `Selected monitor []` is printed even on successful streams and is not a
  diagnostic signal.
- **Sunshine picks the laptop panel at startup.** If `output_name` names an
  output that does not exist when Sunshine starts, it logs
  `Selected monitor [<first monitor found>]` and keeps going with the laptop
  panel instead of failing. The prep command must have created the output before
  the stream's own capture selection, or the client shows a clone.
- **iPad shows a clone of the laptop.** `capture = kms` cannot see headless
  outputs. Switch to `wlr`.
- **Keyboard stops responding after connecting.** The active window moved to
  the new monitor. Restore focus after creation.
- **Wrong resolution or blurry text.** The output was created at a guessed size.
  Use the client-provided values.
- **Works once, then breaks after a reboot or a compositor restart.** Expected:
  the virtual output is gone and only the supervisor or the prep command can
  recreate it.
- **Output never disappears.** The supervisor is not running, or the grace
  period has not elapsed.
- **`hyprctl` works in a terminal but not from Sunshine.** The service does not
  see `HYPRLAND_INSTANCE_SIGNATURE` / `WAYLAND_DISPLAY`. Check the unit's
  environment.
