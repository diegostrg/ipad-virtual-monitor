# shellcheck shell=bash
#
# The virtual output: geometry, placement, and the commands that create or
# remove it.
#
# The whole design rests on one property: a headless output with an explicit
# name. Hyprland's automatic names (`HEADLESS-1`, `HEADLESS-2`, ...) come from a
# counter that is never reused, so they cannot be referenced from a
# configuration file. Asking for a name makes the output predictable.
#
# Positions are given in layout coordinates, which are logical pixels divided by
# the monitor's scale. That is what `hyprctl monitors` prints and what decides
# whether the pointer can move from one screen to the next.

# The configured output name, which is what everything else refers to.
display_name() {
    printf '%s' "$IVM_OUTPUT_NAME"
}

display_exists() {
    hypr_monitor_exists "$(display_name)"
}

display_enabled() {
    hypr_monitor_enabled "$(display_name)"
}

# Geometry of the output as `widthxheight@rate at position`, or empty.
display_geometry() {
    local geom pos
    geom=$(hypr_monitor_field "$(display_name)" 3)
    pos=$(hypr_monitor_field "$(display_name)" 4)
    [[ -n $geom ]] || return 1
    printf '%s at %s' "$geom" "$pos"
}

# Scale of the output, defaulting to 1 when Hyprland reports nothing usable.
display_scale() {
    local scale
    scale=$(hypr_monitor_field "$(display_name)" 6)
    [[ -n $scale ]] || scale=1
    [[ $scale =~ ^[0-9.]+$ ]] || scale=1
    awk -v s="$scale" 'BEGIN { if (s + 0 > 0) printf "%s", s; else printf "1" }'
}

# Bounding box of every enabled output except the virtual one, in layout
# coordinates, as `min_x min_y max_x max_y`.
#
# The target is excluded on purpose: including it would place the output beyond
# its own right edge and leave a gap the cursor cannot cross.
#
# Prints nothing when no other output is enabled.
display_other_box() {
    hypr_monitor_records | awk -F'|' -v skip="$(display_name)" '
        $5 != "false" || $1 == skip { next }
        $4 !~ /^-?[0-9]+x-?[0-9]+$/ || $3 !~ /^[0-9]+x[0-9]+@/ { next }
        {
            split($3, geom, "@")
            split(geom[1], wh, "x")
            split($4, xy, "x")
            scale = ($6 + 0) > 0 ? $6 + 0 : 1
            w = int(wh[1] / scale + 0.5)
            h = int(wh[2] / scale + 0.5)
            x = xy[1] + 0
            y = xy[2] + 0
            if (!seen++) { minx = x; miny = y; maxx = x + w; maxy = y + h }
            else {
                if (x < minx) minx = x
                if (y < miny) miny = y
                if (x + w > maxx) maxx = x + w
                if (y + h > maxy) maxy = y + h
            }
        }
        END { if (seen) printf "%d %d %d %d\n", minx, miny, maxx, maxy }
    '
}

# Where the output should sit for a size and a side, as `x y`.
#
# Each side is glued to the bounding box of the rest of the desktop, so the new
# screen always touches a real one. Overlaps and gaps look like a working stream
# until the pointer has to cross them.
display_position() {
    local width=$1 height=$2 side=${3:-$IVM_SIDE}
    local box

    box=$(display_other_box)
    if [[ -z $box ]]; then
        # Nothing else is enabled: there is no layout to attach to, and the only
        # sensible origin is the corner.
        printf '0 0'
        return 0
    fi

    local min_x min_y max_x max_y
    read -r min_x min_y max_x max_y <<<"$box"
    case $side in
        left) printf '%s %s' "$((min_x - width))" "$min_y" ;;
        above) printf '%s %s' "$min_x" "$((min_y - height))" ;;
        below) printf '%s %s' "$min_x" "$max_y" ;;
        *) printf '%s %s' "$max_x" "$min_y" ;;
    esac
}

# True when the output is currently at the requested mode and position.
#
# Hyprland accepts a rule silently even when it cannot apply it, so the state has
# to be read back. The rate is compared without decimals because Hyprland prints
# 60 as 60.00000.
display_matches() {
    local width=$1 height=$2 fps=$3 x=$4 y=$5 geom pos rate
    geom=$(hypr_monitor_field "$(display_name)" 3)
    pos=$(hypr_monitor_field "$(display_name)" 4)
    [[ -n $geom && -n $pos ]] || return 1
    [[ ${geom%@*} == "${width}x${height}" ]] || return 1
    [[ $pos == "${x}x${y}" ]] || return 1
    rate=${geom##*@}
    rate=${rate%%.*}
    [[ $rate == "$fps" ]]
}

# Detects the layout mistake that breaks input: a monitor that does not touch any
# other. The cursor cannot cross empty space, so the user sees a working stream
# and a mouse that stops at the edge of the laptop panel.
#
# Sizes are converted to layout coordinates, otherwise a scaled monitor is
# measured with the wrong width and a correct layout looks broken.
#
# Prints `ok`, `gap` or `absent`.
display_adjacency() {
    local name
    name=$(display_name)
    hypr_monitor_records | awk -F'|' -v target="$name" '
        function touches(ax, ay, aw, ah, bx, by, bw, bh) {
            if (ax + aw == bx || bx + bw == ax)
                return (ay < by + bh && by < ay + ah)
            if (ay + ah == by || by + bh == ay)
                return (ax < bx + bw && bx < ax + aw)
            return 0
        }
        $5 == "false" {
            split($3, g, "@"); split(g[1], wh, "x"); split($4, xy, "x")
            scale = ($6 + 0) > 0 ? $6 + 0 : 1
            count++
            n[count] = $1
            x[count] = xy[1] + 0
            y[count] = xy[2] + 0
            w[count] = int(wh[1] / scale + 0.5)
            h[count] = int(wh[2] / scale + 0.5)
        }
        END {
            idx = 0
            for (i = 1; i <= count; i++)
                if (n[i] == target) idx = i
            if (!idx) { print "absent"; exit }
            for (i = 1; i <= count; i++) {
                if (i == idx) continue
                if (touches(x[idx], y[idx], w[idx], h[idx], x[i], y[i], w[i], h[i])) {
                    print "ok"
                    exit
                }
            }
            print "gap"
        }
    '
}

# Size and rate Moonlight asked for, as `width height fps`.
#
# Sunshine exports SUNSHINE_CLIENT_WIDTH, _HEIGHT and _FPS to the prep command.
# They are never trusted blindly: a missing or absurd value falls back to the
# configured size instead of creating an unusable output.
display_client_mode() {
    local width=${SUNSHINE_CLIENT_WIDTH:-} height=${SUNSHINE_CLIENT_HEIGHT:-} fps=${SUNSHINE_CLIENT_FPS:-}
    [[ $IVM_FOLLOW_CLIENT == yes ]] || return 1
    display_is_size "$width" "$height" || return 1
    display_is_fps "$fps" || return 1
    printf '%s %s %s' "$width" "$height" "$fps"
}

display_is_size() {
    local width=$1 height=$2
    [[ $width =~ ^[0-9]+$ && $height =~ ^[0-9]+$ ]] || return 1
    ((width >= 320 && height >= 240))
}

display_is_fps() {
    [[ $1 =~ ^[0-9]+$ ]] || return 1
    (($1 >= 24 && $1 <= 240))
}

display_is_side() {
    case $1 in
        right|left|above|below) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# ivm display
# ---------------------------------------------------------------------------

_display_usage() {
    cat <<'EOF'
Usage:
  ivm display status [--verbose]        Show the output and what would be created
  ivm display create [options]          Create it, or move it to the right place
  ivm display remove                    Remove it
  ivm display prep                      Hook for Sunshine; always succeeds

Options for create:
  --width N      Override the width in pixels
  --height N     Override the height in pixels
  --fps N        Override the refresh rate
  --side S       right (default), left, above or below
  --dry-run      Print the plan without touching the compositor

Size comes from, in this order: the flags, the request Moonlight sent to
Sunshine, then ~/.config/ivm/config.
EOF
}

ivm_display() {
    local sub=${1:-status}
    if (($#)); then shift; fi

    # Every subcommand reads the configuration: even `prep` has to know which
    # name and side to use. A malformed file is a hard stop for an interactive
    # command, but never for the Sunshine hook: aborting it kills the stream, so
    # `prep` loads the config inside its own log and carries on with defaults.
    if [[ $sub != prep ]]; then
        ivm_config_load || return "$IVM_EXIT_PROBLEMS"
    fi

    case $sub in
        status) _display_status "$@" ;;
        create) _display_create "$@" ;;
        remove) _display_remove "$@" ;;
        prep) _display_prep "$@" ;;
        help|-h|--help) _display_usage ;;
        *)
            ivm_error "display: unknown subcommand: $sub"
            _display_usage >&2
            return "$IVM_EXIT_USAGE"
            ;;
    esac
}

# Read-only view: what exists, whether it is usable, and what create would do.
_display_status() {
    local arg
    for arg in "$@"; do
        case $arg in
            --verbose|-v) IVM_VERBOSE=1 ;;
            -h|--help) _display_usage; return "$IVM_EXIT_OK" ;;
            *) ivm_error "display status: unknown argument: $arg"; return "$IVM_EXIT_USAGE" ;;
        esac
    done

    if ! hypr_env_discover; then
        ivm_fail 'cannot reach the Hyprland compositor'
        ivm_detail 'HYPRLAND_INSTANCE_SIGNATURE and WAYLAND_DISPLAY must be readable'
        return "$IVM_EXIT_PROBLEMS"
    fi

    printf '%s%s%s  side: %s\n' "$IVM_C_BOLD" "$(display_name)" "$IVM_C_RESET" "$IVM_SIDE"

    if ! display_exists; then
        ivm_info 'not created (it is created when a client connects)'
    elif ! display_enabled; then
        ivm_info "exists but is disabled: $(display_geometry)"
    else
        ivm_ok "created: $(display_geometry), scale $(display_scale)"
        case $(display_adjacency) in
            ok) ivm_ok 'touches another output, so the pointer can reach it' ;;
            gap)
                ivm_fail 'does not touch another output'
                ivm_detail 'the cursor cannot cross empty space'
                ivm_detail 'run: ivm display create'
                ;;
        esac
    fi

    if sunshine_session_active; then
        ivm_info 'a client is streaming'
    else
        ivm_info 'no client is streaming'
    fi

    local target
    target=$(sunshine_output_name)
    if [[ -z $target ]]; then
        ivm_warn 'Sunshine has no output_name configured'
    elif [[ $target != "$(display_name)" ]]; then
        ivm_warn "Sunshine captures '$target', not '$(display_name)'"
    else
        ivm_detail "Sunshine captures $target"
    fi

    if [[ -z $(sunshine_prep_command) ]]; then
        ivm_warn 'Sunshine has no global_prep_cmd, so nothing creates the output'
    fi

    # The plan, so a wrong side or an unexpected size shows up before a client
    # connects and finds out the hard way.
    local width=$IVM_WIDTH height=$IVM_HEIGHT fps=$IVM_FPS source='config'
    local client box
    if client=$(display_client_mode); then
        read -r width height fps <<<"$client"
        source='client'
    fi
    box=$(display_other_box)
    local x y
    read -r x y <<<"$(display_position "$width" "$height")"
    ivm_detail "create would use ${width}x${height}@${fps} (${source}) at ${x}x${y}"
    if [[ -z $box ]]; then
        ivm_warn 'no other output is enabled, so there is no desktop to attach to'
    fi

    return "$IVM_EXIT_OK"
}

_display_create() {
    local opt_width='' opt_height='' opt_fps='' side='' dry_run=0
    local arg value

    while (($#)); do
        case $1 in
            --width|--height|--fps|--side)
                if (($# < 2)); then
                    ivm_error "display create: $1 needs a value"
                    return "$IVM_EXIT_USAGE"
                fi
                arg=${1#--}
                value=$2
                case $arg in
                    width) opt_width=$value ;;
                    height) opt_height=$value ;;
                    fps) opt_fps=$value ;;
                    side) side=$value ;;
                esac
                shift 2
                ;;
            --dry-run) dry_run=1; shift ;;
            -h|--help) _display_usage; return "$IVM_EXIT_OK" ;;
            *)
                ivm_error "display create: unknown argument: $1"
                return "$IVM_EXIT_USAGE"
                ;;
        esac
    done

    # Explicit flags win over the client's request, which wins over the config.
    local width=$IVM_WIDTH height=$IVM_HEIGHT fps=$IVM_FPS source='the config file'
    local client
    if client=$(display_client_mode); then
        read -r width height fps <<<"$client"
        source='the request from Moonlight'
    fi
    if [[ -n $opt_width || -n $opt_height || -n $opt_fps ]]; then
        width=${opt_width:-$width}
        height=${opt_height:-$height}
        fps=${opt_fps:-$fps}
        source='the command line'
    fi
    side=${side:-$IVM_SIDE}

    if ! display_is_size "$width" "$height"; then
        ivm_error "display create: unusable size '${width}x${height}'"
        return "$IVM_EXIT_USAGE"
    fi
    if ! display_is_fps "$fps"; then
        ivm_error "display create: unusable refresh rate '$fps'"
        return "$IVM_EXIT_USAGE"
    fi
    if ! display_is_side "$side"; then
        ivm_error "display create: side must be right, left, above or below, got '$side'"
        return "$IVM_EXIT_USAGE"
    fi

    if ! hypr_env_discover; then
        ivm_error 'hyprland: cannot reach the compositor; is Hyprland running?'
        return "$IVM_EXIT_PROBLEMS"
    fi

    local x y box
    read -r x y <<<"$(display_position "$width" "$height" "$side")"
    box=$(display_other_box)

    if ((dry_run)); then
        printf 'would create %s at %sx%s@%s, position %sx%s (%s)\n' \
            "$(display_name)" "$width" "$height" "$fps" "$x" "$y" "side $side, size from $source"
        if [[ -z $box ]]; then
            printf 'warning: no other output is enabled, so there is nothing to attach to\n' >&2
        fi
        return "$IVM_EXIT_OK"
    fi

    _display_bring_up "$width" "$height" "$fps" "$side"
}

# The real work, shared by `ivm display create` and the Sunshine hook.
# Prints what it did; returns non-zero only when the output is not usable.
_display_bring_up() {
    local width=$1 height=$2 fps=$3 side=$4
    local name x y

    name=$(display_name)
    read -r x y <<<"$(display_position "$width" "$height" "$side")"

    # Creating an output can move the active window onto it and steal the focus.
    hypr_focus_snapshot || true

    hypr_output_create "$name" || return "$IVM_EXIT_PROBLEMS"
    if ! hypr_apply_monitor_rule "$name" "${width}x${height}@${fps}" "${x}x${y}" 1.0; then
        return "$IVM_EXIT_PROBLEMS"
    fi

    hypr_focus_restore || true

    # Read the state back instead of believing the rule was applied.
    local attempt=0
    until display_matches "$width" "$height" "$fps" "$x" "$y"; do
        attempt=$((attempt + 1))
        ((attempt < 20)) || break
        sleep 0.05
    done

    if ! display_matches "$width" "$height" "$fps" "$x" "$y"; then
        ivm_fail "$name did not take ${width}x${height}@${fps} at ${x}x${y}"
        ivm_detail "the compositor reports: $(display_geometry)"
        ivm_detail 'a monitor rule in the Hyprland config may override the runtime one'
        return "$IVM_EXIT_PROBLEMS"
    fi

    ivm_ok "$name is up: ${width}x${height}@${fps} at ${x}x${y} (side $side)"

    case $(display_adjacency) in
        ok) ivm_ok 'touches another output, so the pointer can reach it' ;;
        gap)
            ivm_fail "$name does not touch another output"
            ivm_detail 'the cursor cannot cross empty space'
            ;;
    esac

    return "$IVM_EXIT_OK"
}

_display_remove() {
    local dry_run=0 arg
    for arg in "$@"; do
        case $arg in
            --dry-run) dry_run=1 ;;
            -h|--help) _display_usage; return "$IVM_EXIT_OK" ;;
            *) ivm_error "display remove: unknown argument: $arg"; return "$IVM_EXIT_USAGE" ;;
        esac
    done

    if ! hypr_env_discover; then
        ivm_error 'hyprland: cannot reach the compositor; is Hyprland running?'
        return "$IVM_EXIT_PROBLEMS"
    fi

    local name
    name=$(display_name)

    # Removing nothing is not a failure: it is already the desired state.
    if ! display_exists; then
        ivm_info "$name does not exist, nothing to remove"
        return "$IVM_EXIT_OK"
    fi

    if ((dry_run)); then
        printf 'would remove %s (%s)\n' "$name" "$(display_geometry)"
        return "$IVM_EXIT_OK"
    fi

    if ! hypr_output_remove "$name"; then
        # Only reached when the output vanished between the check and the call.
        if display_exists; then
            ivm_fail "could not remove $name"
            return "$IVM_EXIT_PROBLEMS"
        fi
        ivm_ok "$name is gone"
        return "$IVM_EXIT_OK"
    fi

    if display_exists; then
        ivm_fail "$name still exists after the removal"
        return "$IVM_EXIT_PROBLEMS"
    fi
    ivm_ok "$name removed; its windows moved to another output"
    return "$IVM_EXIT_OK"
}

# The hook Sunshine runs before it selects a capture target.
#
# This one must never fail: a non-zero exit aborts the connection, so a broken
# compositor would turn into "the iPad cannot connect" with no explanation. Every
# outcome is written to a log instead.
_display_prep() {
    local log
    log=$(ivm_state_dir) || return 0
    [[ -n $log ]] || return 0
    log=$log/display.log

    {
        printf '=== %s prep start ===\n' "$(date '+%F %T')"
        (
            set +e
            _display_prep_body "$@"
        ) 2>&1
        printf '=== %s prep end ===\n' "$(date '+%F %T')"
    } >>"$log" 2>&1 || true

    return 0
}

_display_prep_body() {
    # Inside the log redirect: a malformed config is reported where it can be
    # read later, not in the middle of Sunshine's output.
    ivm_config_load || true

    # The hook inherits Sunshine's environment, which usually has the signature,
    # but a service started before the compositor may not.
    hypr_env_discover || {
        printf -- '-- cannot reach the compositor --\n'
        return 1
    }

    # A broken config must not take the stream down with it: fall back to the
    # known-good values and say so in the log.
    local width=$IVM_WIDTH height=$IVM_HEIGHT fps=$IVM_FPS side=$IVM_SIDE
    local source='config'
    if ! display_is_size "$width" "$height"; then
        printf -- '-- unusable configured size %sx%s, using 1920x1334 --\n' "$width" "$height"
        width=1920
        height=1334
    fi
    if ! display_is_fps "$fps"; then
        printf -- '-- unusable configured rate %s, using 60 --\n' "$fps"
        fps=60
    fi
    if ! display_is_side "$side"; then
        printf -- '-- unusable configured side %s, using right --\n' "$side"
        side=right
    fi

    local client
    if client=$(display_client_mode); then
        read -r width height fps <<<"$client"
        source='client'
    else
        printf -- '-- no usable client size, using %sx%s@%s from the config --\n' "$width" "$height" "$fps"
    fi
    printf -- '-- requested %sx%s@%s (%s) --\n' "$width" "$height" "$fps" "$source"

    _display_bring_up "$width" "$height" "$fps" "$side"
}
