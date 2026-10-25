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
virtual monitor lands beside the laptop panel regardless of its resolution.

### Placement matters as much as the mode

Two enabled outputs that are not adjacent break input in a way that looks like a
Streaming bug but is pure geometry: the cursor cannot cross empty space, so it
stops at the edge of the laptop panel and never reaches the tablet.

```text
eDP-1      0..1920
MOONLIGHT  3840..6200      ← nothing between 1920 and 3840
```

The placement must therefore be computed from the bounding box of the **other**
enabled outputs, never from a box that includes the virtual output itself: if
the output already exists from an earlier session, including it pushes the new
position past its own right edge and opens exactly that gap.

The side is a user preference, not a constant. Someone with the tablet to the
left of the laptop needs `left`, or the cursor never reaches it:

| Side | Position |
|------|----------|
| `right` (default) | `x = max(right edge of others)`, `y = min(y)` |
| `left` | `x = min(x) - width`, `y = min(y)` |
| `above` | `x = min(x)`, `y = min(y) - height` |
| `below` | `x = min(x)`, `y = max(bottom)` |

Overlapping outputs produce the mirror symptom: the cursor enters a monitor the
user did not expect, and windows appear in an invisible area.

### Resolution, refresh rate and aspect ratio

The source resolution should match the tablet's panel or the client letterboxes
or rescales. For an iPad Air 11" the native size is **2360×1640**; `1920×1334`
is its exact 1.4390 equivalent, which is cheaper to encode and looks the same at
normal viewing distance.

Scaling does not change the stream: Sunshine captures the physical resolution of
the `wl_output`. Setting `scale = 1.5` only changes the logical size of the
virtual desktop; the encoded frame keeps its pixel size.

All three values come from the client. Sunshine passes them to prep commands as
environment variables, verified on real hardware with two different Moonlight
sessions:

```text
SUNSHINE_CLIENT_WIDTH=1920   SUNSHINE_CLIENT_HEIGHT=1334   SUNSHINE_CLIENT_FPS=60
SUNSHINE_CLIENT_WIDTH=2360   SUNSHINE_CLIENT_HEIGHT=1640   SUNSHINE_CLIENT_FPS=60
```

Moonlight on iPad exposes this as *PC/Game resolution* (`1920x1334`, or *Full /
Safe Area* for the native 2360×1640), so the user chooses it from the client and
the host follows. A fixed size and rate must still be configurable for clients
that request something unusable, and `1920×1334@60` is the fallback profile.

Refresh rate matters for ProMotion tablets: an iPad Pro asks for 120 Hz, and a
headless output accepts it. A mode the compositor cannot produce falls back to
the closest available, so the tool must read back what was actually applied
instead of assuming the request succeeded.

## Lifecycle: who creates and destroys the output

The output must exist **before** Sunshine picks the capture target, and should
disappear **after** the stream ends. Both sides of that window are awkward.

### Creation: the prep command

`global_prep_cmd` runs on every stream launch. Measured order on real hardware,
with the virtual output absent when the client connected:

```text
23:48:37.188   encoder probing starts
23:48:37.233   Executing [Desktop]        ← prep command runs here
23:48:37.480   CLIENT CONNECTED
23:48:37.481   Monitor 0 is eDP-1
23:48:37.481   Monitor 1 is MOONLIGHT    ← created 248 ms earlier
23:48:37.490   Creating encoder [hevc_vaapi]
               Resolution: 1920x1334
```

The decisive detail is that Sunshine re-enumerates the outputs at
`CLIENT CONNECTED`, not only at process start. An output created by the prep
command therefore takes part in that enumeration, and the stream ends up on the
virtual monitor with no leftover clone.

This is the whole on-demand design working: the monitor did not exist before the
client connected, nothing was running beforehand, and the result was a real
extended desktop, not a copy of the laptop panel.

### Destruction: there is no reliable disconnect hook

`global_undo_cmd` is **not** a disconnect hook. It runs in `proc_t::terminate()`
— that is, on the next stream launch or when Sunshine shuts down — never when
the client disconnects. Using it to delete the output causes a
create/delete/create loop.

The log is not a reliable signal either. `CLIENT DISCONNECTED` is written when the
client closes the session cleanly (quitting the app), as observed on
2026-10-24 at 23:53:25 after disconnecting from the iPad. It is **not** written
when the client disappears uncleanly: network loss, a killed app or a suspended
tablet leave no line at all. A tool that waits for that line will keep the
virtual output alive forever after a crash.

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

| Port | Protocol | Purpose | When it is open |
|------|----------|---------|-----------------|
| 47984 | TCP | HTTPS | always |
| 47989 | TCP | HTTP | always |
| 48010 | TCP | RTSP | always |
| 47998 | UDP | Video | only during a session |
| 47999 | UDP | Control | only during a session |
| 48000 | UDP | Audio | only during a session |

The TCP ports are opened at startup. The UDP media ports appear when a client
starts streaming and disappear when it stops, so checking them while idle says
nothing about the host's health — a common false alarm.

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
