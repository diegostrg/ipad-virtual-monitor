# shellcheck shell=bash
#
# `ivm status` — one screen, no scrolling, no root.
#
# `doctor` is for repairing: it walks every check and explains what to fix. This
# is for the everyday question "is it ready right now?", so it stays short and
# never repeats doctor's reasoning.

ivm_status() {
    local arg
    for arg in "$@"; do
        case $arg in
            --verbose|-v) IVM_VERBOSE=1 ;;
            -h|--help)
                printf 'Usage: ivm status [--verbose]\n\nShort, read-only summary. Use doctor to diagnose.\n'
                return "$IVM_EXIT_OK"
                ;;
            *) ivm_error "status: unknown argument: $arg"; return "$IVM_EXIT_USAGE" ;;
        esac
    done

    ivm_config_load || return "$IVM_EXIT_PROBLEMS"

    printf '%sivm status%s %s\n' "$IVM_C_BOLD" "$IVM_C_RESET" "$IVM_VERSION"

    _status_row 'host' "$(platform_distro), $(platform_compositor) $(platform_hyprland_version)"
    _status_usb
    _status_stream
    _status_display
    _status_supervisor

    printf '\n'
    if sunshine_session_active 2>/dev/null; then
        printf 'A client is streaming.\n'
    elif display_exists 2>/dev/null; then
        printf 'Idle. %s exists; the supervisor removes it after %ss of inactivity.\n' \
            "$(display_name)" "$IVM_GRACE"
    else
        printf 'Idle. Connect from Moonlight and the output appears on its own.\n'
    fi
    return "$IVM_EXIT_OK"
}

# Aligned `label value` row. The labels are short by design.
_status_row() {
    printf '  %-12s %s\n' "$1" "$2"
}

_status_usb() {
    local iface cidr peer
    if ! usb_ipad_present; then
        _status_row 'ipad' 'not connected (no Apple device on the USB bus)'
        return 0
    fi

    iface=$(usb_data_interface)
    if [[ -z $iface ]]; then
        _status_row 'ipad' 'connected, but it exposes no network interface'
        return 0
    fi

    cidr=$(net_ipv4_cidr "$iface")
    peer=$(net_peer_address "$iface")
    if [[ -n $peer ]]; then
        _status_row 'network' "$iface $cidr, iPad at $peer"
    else
        _status_row 'network' "$iface ${cidr:-without an address}"
    fi
}

_status_stream() {
    local unit
    if ! unit=$(sunshine_unit); then
        _status_row 'sunshine' 'no user service installed'
        return 0
    fi

    if ! sunshine_active; then
        _status_row 'sunshine' "not running ($unit)"
        return 0
    fi

    local capture
    capture=$(sunshine_conf_get capture)
    if [[ $capture == wlr ]]; then
        _status_row 'sunshine' "running, capturing with wlr"
    else
        _status_row 'sunshine' "running, but capture is '${capture:-unset}' (needs wlr)"
    fi

    local hook
    hook=$(sunshine_prep_command)
    if [[ -z $hook ]]; then
        _status_row 'prep hook' 'missing, so nothing creates the output'
    else
        _status_row 'prep hook' "$hook"
    fi
}

_status_display() {
    if ! hypr_env_discover; then
        _status_row 'display' 'unknown, the compositor is unreachable'
        return 0
    fi

    if ! display_exists; then
        _status_row 'display' 'absent (created when a client connects)'
        return 0
    fi

    local note=''
    case $(display_adjacency) in
        gap) note=', not touching another output' ;;
    esac
    _status_row 'display' "$(display_geometry), scale $(display_scale)$note"
}

_status_supervisor() {
    if ! have systemctl; then
        _status_row 'supervisor' 'no systemd, so nothing removes the output'
        return 0
    fi

    if ! systemctl --user is-enabled --quiet ivm-watch 2>/dev/null &&
        ! systemctl --user is-active --quiet ivm-watch 2>/dev/null; then
        _status_row 'supervisor' 'not installed (ivm up installs it)'
        return 0
    fi

    if systemctl --user is-active --quiet ivm-watch 2>/dev/null; then
        _status_row 'supervisor' 'running'
    else
        _status_row 'supervisor' 'enabled but not running'
    fi
}
