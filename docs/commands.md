# Commands

`ivm help` lists the commands; `ivm help <command>` prints the usage of one of
them, exactly as `<command> --help` does. Every command accepts `--help`, the
ones that change something accept `--dry-run`, and the ones that need root print
their plan and ask once.

| Command | Root | Read-only |
|---------|------|-----------|
| `ivm up` / `ivm down` | no | no |
| `ivm status` | no | yes |
| `ivm doctor` | no | yes |
| `ivm net status` | no | yes |
| `ivm net up` / `down` | yes | no |
| `ivm deps status` | no | yes |
| `ivm deps build` | yes | no |
| `ivm display status` | no | yes |
| `ivm display create` / `remove` | no | no |
| `ivm watch` | no | no |
| `ivm completion` | no | yes |

Exit codes: `0` fine, `1` something is broken, `2` bad usage.

## `ivm up` and `ivm down`

`ivm up` prepares the host. It is the only command that writes outside the
compositor, and it says so line by line:

- starts the Sunshine user service if it is not running;
- sets `capture = wlr` and the `global_prep_cmd` hook in the Sunshine
  configuration, keeping a timestamped backup next to it — credentials and
  pairing data are never read or touched;
- installs, enables and starts the supervisor's user unit.

It never asks for root. Anything that needs it is printed as the command to run.

`ivm down` undoes the runtime state — output removed, supervisor stopped — and
leaves the configuration alone, so the next `ivm up` is instant. `ivm down --all`
also stops Sunshine.

## `ivm status`

One short screen with the state of every layer. It exits non-zero when a stream
is running without the virtual output, because that stream is a clone of the
laptop panel and everything else about it looks healthy.

## `ivm doctor`

Walks the four layers in dependency order and the first `fail` is the one to fix,
because everything below it is a precondition.

```text
Layer 1 — USB device
  ok   iPad on the USB bus (product 12ab)
  ok   usbmuxd supports USB device mode 3
Layer 2 — USB network
  ok   usb0 has 10.42.0.1/24
  ok   a DHCP server is listening on UDP/67
Layer 3 — Virtual output
  ok   MOONLIGHT exists: 2360x1640@60.00000 at 1920x0
Layer 4 — Stream
  ok   capture backend is wlr

Summary  19 ok, 0 warnings, 0 failures
```

`--verbose` adds the paths and commands behind each check.

### `--report`

Runs the same survey as plain text for an issue. Always verbose, never coloured,
and **sanitized**: addresses, MACs, the hostname, your user name and home paths
become `<ip>`, `<mac>`, `<host>` and `<user>` placeholders. The shape survives, so
`<ip>/24` still says there is a subnet. Nothing is uploaded by the tool.

## `ivm net`

The link itself needs no setup once the machine has it: NetworkManager brings the
shared network back every time the iPad appears, even across reboots. What can
still be wrong is its configuration, and that is what `ivm net` looks at.

```bash
ivm net status              # link, address, profile, DHCP, firewall
ivm net up --dry-run        # the plan, without running anything
ivm net up                  # show the plan, ask once, then apply it
ivm net down                # deactivate the shared connection
```

`ivm net up` only touches what is wrong. On a machine that already works it has
nothing to do and says so; otherwise it explains the change first:

```text
  plan sudo nmcli connection modify iPad-USB-Tethering ipv4.method shared ...
  plan sudo ufw allow in on usb0 to any port 67 proto udp

Apply 3 command(s) with sudo? [y/N]
```

It never removes anything you configured and never changes the firewall beyond
one rule scoped to the USB interface. `--yes` skips the question for scripts;
without a terminal it refuses to apply anything at all.

## `ivm deps`

The distribution's `usbmuxd` cannot switch the iPad into the USB mode that
exposes its network interface: the feature landed upstream in December 2022 and
no release has been cut since. `ivm` detects that and can build the stack.

```bash
ivm deps status            # read-only: tools, libraries, daemon, service
ivm deps build --dry-run   # print every command, change nothing
ivm deps build             # print the plan again, ask once, then build
```

`build` clones the six projects into `~/src/ivm-deps`, builds them in the
documented order, installs into `/usr/local`, writes the systemd drop-in for
`USBMUXD_DEFAULT_DEVICE_MODE=3` and restarts the daemon. It needs network access
and `sudo` for the installations; nothing runs before you see it. Re-running
continues from what is already built, and `--force` rebuilds after upstream
changes.

The manual recipe, the versions the reference machine was built with, and the
uninstall steps are in [dependencies.md](dependencies.md).

## `ivm display`

```bash
ivm display status                 # what exists, and what would be created
ivm display create --dry-run       # print the plan, change nothing
ivm display create                 # create it at the size the client asked for
ivm display create --side left --width 1920 --height 1334
ivm display create --width 2360 --height 1640 --scale 1.6
ivm display remove
```

The size comes from, in this order: the flags, the request Moonlight sent to
Sunshine (`SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS`), then the configuration file.
Positions are computed from your real layout so the new screen always touches an
existing one — a gap or an overlap looks like a working stream until the pointer
has to cross it.

The scale has one constraint that is easy to miss: Hyprland divides the mode by
it to get the layout size and needs whole pixels, so a scale that does not divide
both dimensions exactly is applied as an integer instead. `2360x1640` at `1.6` is
`1475x1025` and works; `1920x1334` at `1.6` is `833.75` and would become `2`.
`ivm` checks this before touching the compositor and falls back to `1.0` with a
message rather than let the layout drift.

Creating the output takes the focus away from what you were doing, so the tool
snapshots the focused monitor and the active window and puts them back.

## `ivm watch`

Hyprland never removes the output by itself, and Sunshine has no disconnect hook.
`ivm watch` is the piece that closes the loop:

```bash
ivm watch                # foreground: removes MOONLIGHT 20 s after a disconnect
ivm watch --once         # reconcile right now and exit
```

`ivm up` installs it as a user service, so it survives a closed terminal and
starts with your session:

```bash
systemctl --user status ivm-watch
journalctl --user -u ivm-watch -f     # the removals as they happen
```

To keep it by hand instead:

```bash
cp share/systemd/ivm-watch.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now ivm-watch
```

The unit expects `ivm` on your `PATH`; adjust `ExecStart` if you prefer an
absolute path.

### Why it also restarts Sunshine

Sunshine runs `global_prep_cmd` when it **launches the app** of a session, not on
every client connection, and the desktop app it streams is a placebo that never
exits. A Sunshine that is still running therefore believes the app is alive,
skips the prep on the next connection, finds no `MOONLIGHT`, and quietly streams
a clone of the laptop panel instead.

So when the supervisor removes the output, it also restarts Sunshine. With
nobody connected that costs a few seconds and arms the hook for the next
connection. Because it happens in the background, it warns you:

```text
Restarting Sunshine
Wait a few seconds before reconnecting from Moonlight.
```

That notice appears about two seconds *into* the restart, not before it:
removing the output makes Hyprland move the workspaces back to the laptop panel,
and a popup raised during that switch is sometimes swallowed. The delay runs in
its own process, so it never holds the restart up. It needs `notify-send` and a
notification daemon, stays silent when either is missing, and `NOTIFY=no` turns
it off.

The full reasoning is in [video-pipeline.md](video-pipeline.md).

## `ivm completion`

Prints a script for the shell you name. They are plain text kept with the source,
so there is no generated file, no install hook and nothing to rebuild.

```bash
# bash
ivm completion bash > ~/.local/share/bash-completion/completions/ivm

# zsh (the file must be named _ivm and its directory must be in $fpath)
mkdir -p ~/.zfunc
ivm completion zsh > ~/.zfunc/_ivm
# in ~/.zshrc, before compinit runs: fpath=(~/.zfunc $fpath)

# fish
ivm completion fish > ~/.config/fish/completions/ivm.fish
```

For the current session only, after `compinit` has run:
`eval "$(ivm completion zsh)"`, or `eval "$(ivm completion bash)"` in bash.
