# Hyprland setup

This repository **does not manage your dotfiles**. Everything below is
documentation: you decide what to add, and you can remove it later without
touching the tool.

Two things are worth configuring:

1. workspace rules, so the virtual output is useful instead of a blank area;
2. cleanup of old experiments that create phantom monitors.

The output itself does **not** need a permanent monitor rule. The CLI sets its
mode, position and scale every time it creates it.

## Which dialect do you have?

Hyprland 0.56 introduced Lua configuration. The two dialects accept different
runtime commands:

| Dialect | Config files | Runtime command |
|---------|--------------|-----------------|
| Legacy | `hyprland.conf` | `hyprctl keyword ...` |
| Lua | `hyprland.lua` + `require("config/...")` | `hyprctl eval '...'` |

Running `hyprctl keyword monitor ...` against a Lua configuration fails with:

```text
keyword can't work with non-legacy parsers. Use eval.
```

Check before copying any snippet:

```bash
hyprctl systeminfo | head -5
ls ~/.config/hypr/hyprland.lua 2>/dev/null
```

## Workspace rules

Dedicate a few workspaces to the iPad. Windows sent there stay there while the
output exists, and Hyprland moves them back to the laptop panel when the stream
ends, so nothing is lost.

`default = true` on the first workspace ensures the output adopts that
workspace when it appears instead of taking the next free number.
`persistent = true` lets Hyprland recreate the workspaces when the output
returns.

### Lua

```lua
-- ~/.config/hypr/config/workspaces.lua
for i = 6, 10 do
  hl.workspace_rule({
    workspace = tostring(i),
    monitor = "IPAD",
    persistent = true,
    default = (i == 6),
  })
end
```

### Legacy

```ini
# ~/.config/hypr/hyprland.conf
workspace = 6, monitor:IPAD, default:true, persistent:true
workspace = 7, monitor:IPAD, persistent:true
workspace = 8, monitor:IPAD, persistent:true
workspace = 9, monitor:IPAD, persistent:true
workspace = 10, monitor:IPAD, persistent:true
```

Reload after editing:

```bash
hyprctl reload
```

## Remove stale virtual-monitor rules

Leftovers from earlier experiments are the most common source of confusion.
A monitor rule that names an output which no longer exists creates a disabled
placeholder that shows up in `hyprctl monitors all` and can make scripts pick
the wrong device.

Look for rules pointing at `Virtual-1`, `HEADLESS-*` or any name you no longer
use:

```bash
grep -rnE 'Virtual-[0-9]|HEADLESS-' ~/.config/hypr/
```

If you find any, delete the corresponding `hl.monitor({...})` block (Lua) or
`monitor = ...` line (legacy). The tool uses `IPAD` exclusively and does not
depend on those names.

Check the result:

```bash
hyprctl monitors all
hyprctl configerrors
```

## Optional: status indicator

If you use a bar, a small status line is handy:

```bash
ivm status --short
```

This is planned, not implemented yet; see [roadmap.md](roadmap.md).

## Optional: autostart

Nothing is required at login. The virtual output is created when a stream
starts, so an autostart entry only adds a phantom monitor you cannot see.

If you prefer to bring the network up automatically:

```bash
systemctl --user enable --now ivm-network.service   # planned
```

## Reverting

Because nothing here is installed into your configuration by the tool:

1. remove the workspace rules,
2. remove any leftover monitor rules,
3. `hyprctl reload`.

The desktop returns to its previous layout immediately.
