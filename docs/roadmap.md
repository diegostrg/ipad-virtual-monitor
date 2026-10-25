# Roadmap

The project is built in phases, each one usable on its own. Nothing is written
before the previous phase is verified on real hardware.

## Phase 0 — Scaffolding

- [x] Local git repository
- [x] README, license, documentation structure
- [x] Architecture, USB network, video pipeline and troubleshooting documents
- [x] Dependency documentation: why the distro `usbmuxd` cannot switch modes
- [x] Findings from earlier attempts verified and folded into the design docs
- [x] End-to-end verification on real hardware: headless output, `capture = wlr`,
      extended desktop, input and audio
- [x] On-demand creation verified: the output is created by the prep command
      while Sunshine is already running, and the stream lands on it
- [x] Clean-boot verification: after removing `vkms`, a reboot, and a single
      connection from the iPad, the whole path worked with no manual steps
- [x] Client-provided size and refresh rate verified
      (`SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS`)
- [ ] Repository published on GitHub (deferred until the tool works)

## Phase 1 — Diagnosis

- [ ] `ivm doctor`: read-only, walks all four layers
- [ ] Detect distro, compositor, config dialect, Sunshine, NetworkManager, UFW
- [ ] Detect `usbmuxd` build and whether it supports device mode 3
- [ ] Detect support by inspecting the binary, not by guessing from a version
- [ ] Report the first broken layer with a suggested fix
- [ ] `--report`: sanitized output for bug reports
- [ ] Exit codes suitable for scripting

## Phase 2 — Network

- [ ] Detect the iPad data interface without hardcoding `usb0`
- [ ] `ivm net up` / `ivm net down` / `ivm net status`, idempotent
- [ ] Create or repair the NetworkManager shared profile
- [ ] Mark the Apple private interface unmanaged
- [ ] Add the scoped DHCP firewall rule only if a known firewall is active
- [ ] Verify the DHCP handshake and report the iPad's address
- [ ] Instructions for `usbmuxd` (no automatic compilation yet)

## Phase 3 — Display

- [ ] `ivm display create` / `remove` / `status`
- [ ] Use the explicit `MOONLIGHT` output name
- [ ] Compute position and scale from the current layout
- [ ] Support Lua and legacy Hyprland dialects
- [ ] Idempotent creation: `Name already taken` counts as success
- [ ] `ivm display prep` hook for Sunshine (create before capture)
- [ ] Resolution and refresh rate from the client request
      (`SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS`), with the 1920×1334@60 fallback
- [ ] Fixed size and rate as an explicit user override
- [ ] Configurable side: `right`, `left`, `above`, `below`
- [ ] Read back the applied mode instead of trusting the request
- [ ] Snapshot and restore the focused monitor and the active window
- [ ] Reconcile with existing monitor rules (`hl.monitor` replaces them)
- [ ] Verify that Sunshine passes the client's dimensions to prep commands

## Phase 4 — Orchestration

- [ ] `ivm up` / `ivm down` / `ivm status`
- [ ] Ensure Sunshine is running: it can die at boot before the compositor is up
      and `Restart=on-failure` does not bring it back
- [ ] Configure Sunshine hooks with a backup, without touching credentials
- [ ] `ivm watch`: supervisor as a systemd user unit
- [ ] Session detection from Sunshine's `/proc/<pid>/task/*/comm` threads
- [ ] Grace period before removing the output (default 20 s, configurable)
- [ ] Human-readable status table
- [ ] Shell completions (bash, zsh, fish)

## Phase 5 — Hardening and release

- [ ] `bats` test suite for detection and idempotency logic
- [ ] `shellcheck` clean, `shfmt` formatted
- [ ] Remove the user's stale `Virtual-1` / `HEADLESS-*` rules during migration
- [ ] Guided migration from the earlier `vkms` setup: unload the module, remove
      `modules-load.d` persistence and the obsolete `virtual-display.service`
- [ ] Detect and report leftover units and scripts from earlier attempts
- [ ] Rewrite the private Spanish notes into public English documentation
- [ ] Publish on GitHub with screenshots and a short demo
- [ ] Package for Arch (AUR) if there is demand

## Out of scope for v1

- Compositors other than Hyprland (structure allows it, code does not)
- X11 desktops
- Windows and macOS hosts
- Wireless-only operation
- Automatic compilation of the libimobiledevice stack
- A graphical interface

## Open questions

- Should `ivm up` also start a stream, or only prepare the host and leave the
  click to Moonlight? (Current assumption: prepare only; the client starts the
  stream.)
- Should the network layer stay up permanently or follow the stream lifecycle?
  (Current assumption: stay up; it is harmless and makes reconnects instant.)
- Should the tool ship a systemd drop-in that makes Sunshine survive a boot
  race, or only detect and start it on demand? A drop-in is invasive; starting
  it from the tool is not enough if the user never runs the tool.
- How to handle iPads whose panel resolution does not match the requested
  stream size: letterbox or scale?
