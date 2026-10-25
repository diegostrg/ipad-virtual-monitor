# shellcheck shell=bash
#
# `ivm up` and `ivm down` — the two commands a user should need.
#
# `up` prepares everything that can be prepared without root and says what is
# still missing. `down` takes the virtual output away and stops the supervisor.
# Neither of them touches the USB layer: that needs root, it is configured once,
# and `ivm doctor` already explains how to repair it.
#
# Everything here is idempotent. Running `up` twice must be boring, and so must
# running `down` when nothing is up.

ivm_up() {
    local arg
    for arg in "$@"; do
        case $arg in
            --verbose|-v) IVM_VERBOSE=1 ;;
            -h|--help)
                cat <<'EOF'
Usage: ivm up [--verbose]

Prepares the streaming host: checks the compositor, starts Sunshine, points its
prep hook at this tool, and makes sure the supervisor is running. It never asks
for root; whatever needs root is reported with the command to run.
EOF
                return "$IVM_EXIT_OK"
                ;;
            *) ivm_error "up: unknown argument: $arg"; return "$IVM_EXIT_USAGE" ;;
        esac
    done

    ivm_config_load || return "$IVM_EXIT_PROBLEMS"

    printf '%sivm up%s\n' "$IVM_C_BOLD" "$IVM_C_RESET"
    local failed=0

    printf '\n%sHost%s\n' "$IVM_C_BOLD" "$IVM_C_RESET"
    if ! hypr_env_discover; then
        ivm_fail 'cannot reach the Hyprland compositor'
        ivm_detail 'start the session first; nothing here works without it'
        return "$IVM_EXIT_PROBLEMS"
    fi
    local compositor
    compositor=$(platform_compositor)
    if [[ $compositor != hyprland ]]; then
        ivm_fail "compositor is '$compositor'; only Hyprland is supported today"
        return "$IVM_EXIT_PROBLEMS"
    fi
    ivm_ok "Hyprland $(platform_hyprland_version), $(platform_hyprland_dialect) configuration"

    printf '\n%sStreaming host%s\n' "$IVM_C_BOLD" "$IVM_C_RESET"
    _up_sunshine || failed=1

    printf '\n%sSupervisor%s\n' "$IVM_C_BOLD" "$IVM_C_RESET"
    _up_supervisor || failed=1

    printf '\n%sUSB network%s\n' "$IVM_C_BOLD" "$IVM_C_RESET"
    _up_network

    printf '\n'
    if ((failed)); then
        printf 'Some steps failed; fix the first failure above.\n'
        return "$IVM_EXIT_PROBLEMS"
    fi
    printf 'Ready. Connect from Moonlight%s.\n' "$(_up_address_hint)"
    return "$IVM_EXIT_OK"
}

_up_sunshine() {
    local unit
    if ! unit=$(sunshine_unit); then
        ivm_fail 'no Sunshine user service is installed'
        ivm_detail 'install Sunshine from your distribution, then run this again'
        return 1
    fi

    if sunshine_active; then
        ivm_ok "Sunshine is running ($unit)"
    elif systemctl --user start "$unit" 2>/dev/null; then
        local attempt=0
        until sunshine_active; do
            attempt=$((attempt + 1))
            ((attempt < 20)) || break
            sleep 0.5
        done
        if sunshine_active; then
            ivm_ok "started Sunshine ($unit)"
        else
            ivm_fail 'Sunshine did not stay up'
            ivm_detail 'it cannot connect to the compositor if it starts too early'
            return 1
        fi
    else
        ivm_fail "could not start $unit"
        ivm_detail "try it by hand: systemctl --user start $unit"
        return 1
    fi

    # Collect every change and restart once: each restart drops the session, and
    # doing it twice in a row is both slow and rude.
    local changed=0 result

    # The capture backend is not a preference: the kms backend cannot see a
    # headless output and silently streams a clone of the laptop panel.
    if sunshine_capture_is_wlr; then
        ivm_ok 'capture backend is wlr'
    else
        # The status decides, never the output: `sunshine_set_key` prints nothing,
        # so reading its output would report a failure for every case.
        result=0
        sunshine_set_key capture wlr || result=$?
        case $result in
            0)
                ivm_ok "capture backend set to wlr (backup: ${IVM_SUNSHINE_BACKUP:-none})"
                changed=1
                ;;
            1) ivm_ok 'capture backend is wlr' ;;
            *)
                ivm_fail 'could not set capture = wlr in the Sunshine configuration'
                return 1
                ;;
        esac
    fi

    local wanted=$IVM_INVOKED' display prep'
    local current
    current=$(sunshine_prep_command)

    if [[ $current == "$wanted" ]]; then
        ivm_ok 'the prep hook already runs this tool'
    else
        result=0
        sunshine_set_key global_prep_cmd "[{\"do\":\"${wanted}\"}]" || result=$?
        case $result in
            0)
                ivm_ok "prep hook set to: $wanted"
                ivm_detail "previous configuration saved as ${IVM_SUNSHINE_BACKUP:-none}"
                changed=1
                ;;
            1) ivm_ok 'the prep hook already runs this tool' ;;
            *)
                ivm_fail 'could not write the prep hook into the Sunshine configuration'
                ivm_detail "edit $(sunshine_conf_path) by hand: global_prep_cmd = [{\"do\":\"$wanted\"}]"
                return 1
                ;;
        esac
    fi

    if ((changed)); then
        _up_restart_sunshine || return 1
    elif ! display_exists && ! sunshine_session_active; then
        # No output and no stream: the next client would find nothing to capture,
        # because Sunshine only runs the prep when it launches the app. A restart
        # now arms it, and with nobody streaming it costs nothing.
        if sunshine_rearm; then
            ivm_ok 'Sunshine restarted so the next connection builds the output'
        else
            ivm_warn 'could not restart Sunshine; the next connection may clone the panel'
        fi
    fi
    return 0
}

# A configuration change only takes effect on the next start. Restarting during a
# stream would kill it, so the user decides.
_up_restart_sunshine() {
    if sunshine_session_active; then
        ivm_warn 'a client is streaming; the change applies the next time Sunshine restarts'
        return 0
    fi
    if sunshine_restart; then
        ivm_ok 'Sunshine restarted to pick up the change'
        return 0
    fi
    ivm_fail 'Sunshine did not come back after the restart'
    ivm_detail "check it with: systemctl --user status $(sunshine_unit)"
    return 1
}

_up_supervisor() {
    local unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
    local unit_file=$unit_dir/ivm-watch.service
    local template=$IVM_ROOT/share/systemd/ivm-watch.service

    if [[ ! -f $unit_file ]]; then
        if [[ ! -r $template ]]; then
            ivm_warn 'the supervisor unit is missing from this checkout'
            ivm_detail 'run it by hand for now: ivm watch'
            return 0
        fi
        mkdir -p "$unit_dir" || return 1
        if ! cp -- "$template" "$unit_file"; then
            ivm_fail 'could not install the supervisor unit'
            return 1
        fi
        systemctl --user daemon-reload 2>/dev/null || true
        ivm_ok "installed $unit_file"
    fi

    if systemctl --user is-enabled --quiet ivm-watch 2>/dev/null; then
        ivm_ok 'the supervisor starts with the session'
    elif systemctl --user enable ivm-watch 2>/dev/null; then
        ivm_ok 'the supervisor will start with the session'
    else
        ivm_warn 'could not enable the supervisor'
        ivm_detail 'enable it by hand: systemctl --user enable ivm-watch'
    fi

    if systemctl --user is-active --quiet ivm-watch 2>/dev/null; then
        ivm_ok 'the supervisor is running'
    elif systemctl --user start ivm-watch 2>/dev/null; then
        ivm_ok 'started the supervisor'
    else
        ivm_fail 'could not start the supervisor'
        ivm_detail 'start it by hand: systemctl --user start ivm-watch'
        return 1
    fi
    return 0
}

# Read-only on purpose: repairing the interface needs root, and this tool never
# asks for root without being told to.
_up_network() {
    local iface
    if ! usb_ipad_present; then
        ivm_warn 'the iPad is not on the USB bus'
        ivm_detail 'connect the cable and unlock the tablet; the rest can wait'
        return 0
    fi

    iface=$(usb_data_interface)
    if [[ -z $iface ]]; then
        # Just plugged in: give the device a moment to be switched and enumerated
        # instead of reporting a fault that resolves itself.
        iface=$(usb_wait_for_data_interface 5) || iface=''
    fi
    if [[ -z $iface ]]; then
        ivm_fail 'the iPad exposes no network interface'
        ivm_detail 'usbmuxd must request USB device mode 3; check: ivm deps status'
        return 0
    fi

    local cidr
    cidr=$(net_ipv4_cidr "$iface")
    if [[ -z $cidr ]]; then
        ivm_warn "$iface has no IPv4 address, so the iPad cannot reach this host"
        ivm_detail "create it with: nmcli connection add type ethernet ifname $iface ipv4.method shared"
        return 0
    fi

    local peer rtt
    peer=$(net_peer_address "$iface")
    if [[ -n $peer ]] && rtt=$(net_ping_ms "$peer") && [[ -n $rtt ]]; then
        ivm_ok "$iface $cidr, iPad $peer in $rtt ms"
    else
        ivm_ok "$iface $cidr"
        ivm_info 'no address seen from the iPad yet; it appears when it connects'
    fi
}

# What to type into Moonlight, so the user does not have to run doctor.
_up_address_hint() {
    local iface address
    iface=$(usb_data_interface 2>/dev/null)
    [[ -n $iface ]] || return 0
    address=$(net_ipv4_addr "$iface")
    [[ -n $address ]] && printf ' to %s' "$address"
}

ivm_down() {
    local all=0 arg
    for arg in "$@"; do
        case $arg in
            --all) all=1 ;;
            -h|--help)
                cat <<'EOF'
Usage: ivm down [--all]

Removes the virtual output and stops the supervisor, so nothing brings it back.
The Sunshine configuration is left alone: it is ready for the next `ivm up`.

  --all   Also stop Sunshine
EOF
                return "$IVM_EXIT_OK"
                ;;
            *) ivm_error "down: unknown argument: $arg"; return "$IVM_EXIT_USAGE" ;;
        esac
    done

    ivm_config_load || return "$IVM_EXIT_PROBLEMS"
    printf '%sivm down%s\n' "$IVM_C_BOLD" "$IVM_C_RESET"

    # The supervisor first: otherwise it would remove the output on its own
    # schedule and the messages would interleave.
    if systemctl --user is-active --quiet ivm-watch 2>/dev/null; then
        if systemctl --user stop ivm-watch 2>/dev/null; then
            ivm_ok 'supervisor stopped'
        else
            ivm_warn 'could not stop the supervisor'
        fi
    else
        ivm_info 'the supervisor is not running'
    fi

    if hypr_env_discover; then
        _display_remove || ivm_warn 'the virtual output could not be removed'
    else
        ivm_warn 'cannot reach the compositor, so the virtual output was not touched'
    fi

    # The output is gone, so Sunshine has to forget the session it is holding:
    # otherwise the next connection skips the prep hook and clones the panel.
    if ((all)); then
        :
    elif sunshine_session_active; then
        ivm_warn 'a client is streaming; Sunshine keeps its session until it ends'
    elif sunshine_rearm; then
        ivm_ok 'Sunshine restarted, so the next connection builds the output again'
    else
        ivm_warn 'could not restart Sunshine; the next connection may clone the panel'
    fi

    if ((all)); then
        local unit
        if unit=$(sunshine_unit) && sunshine_active; then
            if systemctl --user stop "$unit" 2>/dev/null; then
                ivm_ok 'Sunshine stopped'
            else
                ivm_warn 'could not stop Sunshine'
            fi
        else
            ivm_info 'Sunshine is not running'
        fi
    fi

    printf '\nBack with: ivm up\n'
    return "$IVM_EXIT_OK"
}
