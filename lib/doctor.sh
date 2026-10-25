# shellcheck shell=bash
#
# `ivm doctor` — read-only inspection of the four layers.
#
# The report is ordered by dependency: a failure in layer 1 makes everything
# below it meaningless, so the first broken layer is the one to fix. Nothing
# here changes the system, and nothing here needs root.

ivm_doctor() {
    local arg
    for arg in "$@"; do
        case $arg in
            --verbose|-v) IVM_VERBOSE=1 ;;
            -h|--help)
                printf 'Usage: ivm doctor [--verbose]\n\nRead-only inspection of every layer.\n'
                return "$IVM_EXIT_OK"
                ;;
            *)
                ivm_error "doctor: unknown argument: $arg"
                return "$IVM_EXIT_USAGE"
                ;;
        esac
    done

    ivm_config_load || return "$IVM_EXIT_PROBLEMS"

    printf '%sivm doctor%s %s\n' "$IVM_C_BOLD" "$IVM_C_RESET" "$IVM_VERSION"
    _doctor_host
    _doctor_usb
    _doctor_network
    _doctor_display
    _doctor_stream

    _doctor_summary
}

_doctor_host() {
    ivm_section 'Host'

    printf '  %-14s %s\n' 'distro' "$(platform_distro)"
    if ! platform_is_wayland; then
        ivm_fail 'not a Wayland session; this tool only supports Wayland compositors'
        return 0
    fi

    local compositor
    compositor=$(platform_compositor)
    if [[ $compositor != hyprland ]]; then
        ivm_fail "compositor is '$compositor'; only Hyprland is supported today"
        return 0
    fi

    local version dialect
    version=$(platform_hyprland_version) || version='unknown'
    dialect=$(platform_hyprland_dialect)
    printf '  %-14s Hyprland %s, %s configuration\n' 'compositor' "$version" "$dialect"
    printf '  %-14s %s\n' 'session' "${WAYLAND_DISPLAY:-unknown}"
    printf '  %-14s %s (side: %s)\n' 'output' "$IVM_OUTPUT_NAME" "$IVM_SIDE"
}

_doctor_usb() {
    ivm_section 'Layer 1 — USB device'

    if ! usb_ipad_present; then
        ivm_fail 'no Apple USB device found'
        ivm_detail 'check the cable is a data cable, the iPad is unlocked and trusted'
        return 0
    fi

    local product interfaces
    product=$(usb_ipad_product_id) || product='unknown'
    interfaces=$(usb_net_interfaces | paste -sd, -)
    ivm_ok "iPad on the USB bus (product $product)"
    if [[ -z $interfaces ]]; then
        ivm_fail 'the device exposes no network interface'
        ivm_detail 'the USB device mode was not switched; usbmuxd must request mode 3'
        return 0
    fi
    ivm_ok "network interfaces exposed: $interfaces"

    if usbmuxd_active; then
        ivm_ok 'usbmuxd is running'
    else
        ivm_fail 'usbmuxd is not running'
        ivm_detail 'start it with: sudo systemctl start usbmuxd'
    fi

    local binary
    if ! binary=$(usbmuxd_binary); then
        ivm_fail 'usbmuxd is not installed'
        ivm_detail 'see docs/dependencies.md: the distribution package cannot switch modes'
        return 0
    fi

    if usbmuxd_supports_mode3; then
        ivm_ok "usbmuxd supports USB device mode $IVM_USBMUXD_DEFAULT_DEVICE_MODE"
        ivm_detail "binary: $binary"
    else
        ivm_fail "usbmuxd cannot request USB device mode $IVM_USBMUXD_DEFAULT_DEVICE_MODE"
        ivm_detail "binary: $binary (a release build, or the distribution package)"
        ivm_detail 'there is no network interface until a capable build replaces it'
        ivm_detail 'see docs/dependencies.md for the build order'
    fi

    local env
    env=$(usbmuxd_environment)
    if [[ -n $env ]]; then
        ivm_detail "service environment: $env"
        if [[ $env != *USBMUXD_DEFAULT_DEVICE_MODE* ]]; then
            ivm_warn "the service does not set USBMUXD_DEFAULT_DEVICE_MODE=$IVM_USBMUXD_DEFAULT_DEVICE_MODE"
            ivm_detail 'the build default may be enough, but the drop-in is what makes it explicit'
        fi
    fi
}

_doctor_network() {
    ivm_section 'Layer 2 — USB network'

    local iface
    iface=$(usb_data_interface)
    if [[ -z $iface ]]; then
        ivm_fail 'no usable USB interface to carry the network'
        return 0
    fi

    local cidr
    cidr=$(net_ipv4_cidr "$iface")
    if [[ -z $cidr ]]; then
        ivm_fail "$iface has no IPv4 address"
        ivm_detail "create it with: nmcli connection add type ethernet ifname $iface ipv4.method shared"
        return 0
    fi
    ivm_ok "$iface has $cidr"

    local connection
    connection=$(net_active_connection "$iface")
    if [[ -n $connection ]]; then
        ivm_ok "NetworkManager connection: $connection"
    else
        ivm_warn "$iface is not managed by an active NetworkManager connection"
    fi

    if net_dhcp_listening; then
        ivm_ok 'a DHCP server is listening on UDP/67'
    else
        ivm_warn 'nothing is listening on UDP/67, so the iPad cannot get an address'
        ivm_detail 'a shared IPv4 connection runs its own DHCP server; check its configuration'
    fi

    local peer rtt
    if peer=$(net_peer_address "$iface") && [[ -n $peer ]]; then
        if rtt=$(net_ping_ms "$peer") && [[ -n $rtt ]]; then
            ivm_ok "peer $peer answers in $rtt ms"
        else
            ivm_warn "peer $peer is known but does not answer"
            ivm_detail 'the iPad may be locked or asleep'
        fi
    else
        ivm_info "no peer has been seen on $iface yet"
        ivm_detail 'connect the iPad once; a lease appears when it is unlocked'
    fi

    local private_iface
    for private_iface in $(usb_private_interfaces); do
        if net_iface_unmanaged "$private_iface"; then
            ivm_ok "$private_iface is unmanaged (Apple private interface, correctly ignored)"
        else
            ivm_warn "$private_iface is managed by NetworkManager"
            ivm_detail 'it will stay in "activating" forever and never carry traffic'
            ivm_detail "add unmanaged-devices=interface-name:$private_iface under [keyfile]"
        fi
    done

    # The saved UFW ruleset is world-readable, so this does not need root. A rule
    # that is saved but was never reloaded is caught by `ivm net status` instead.
    case $(net_firewall_name) in
        none)
            ivm_ok 'no firewall service is active'
            ;;
        ufw)
            case $(net_ufw_dhcp_rule "$iface") in
                broad) ivm_ok "ufw allows DHCP in on $iface" ;;
                narrow)
                    ivm_warn "ufw only allows DHCP to a fixed address on $iface"
                    ivm_detail 'a new lease request is broadcast, so it is dropped'
                    ivm_detail 'add the interface-wide rule with: ivm net up'
                    ;;
                *)
                    ivm_warn "ufw has no DHCP rule for $iface"
                    ivm_detail 'the iPad will not get an address while that request is dropped'
                    ivm_detail 'add it with: ivm net up'
                    ;;
            esac
            ;;
        *)
            ivm_warn "$(net_firewall_name) is active; its rules cannot be read without root"
            ivm_detail "allow UDP/67 in on $iface if the iPad never gets an address"
            ;;
    esac
}

_doctor_display() {
    ivm_section 'Layer 3 — Virtual output'

    if ! hypr_available; then
        ivm_fail 'hyprctl cannot reach the compositor'
        ivm_detail 'HYPRLAND_INSTANCE_SIGNATURE and WAYLAND_DISPLAY must be in the environment'
        return 0
    fi

    local errors
    errors=$(hypr_config_errors)
    if [[ -n $errors ]]; then
        ivm_fail 'the Hyprland configuration reports errors'
        while IFS= read -r line; do
            [[ -n $line ]] && ivm_detail "$line"
        done <<<"$errors"
    else
        ivm_ok 'no Hyprland configuration errors'
    fi

    # Leftover virtual outputs from older setups overlap the stream and steal
    # focus and input. They are not ours, so they are always a problem.
    local name stray=0
    for name in $(hypr_virtual_outputs); do
        [[ $name == "$IVM_OUTPUT_NAME" ]] && continue
        ivm_fail "virtual output '$name' is enabled but the configured name is '$IVM_OUTPUT_NAME'"
        ivm_detail 'if it is a leftover, remove whatever creates it: module, rule or service'
        ivm_detail 'if it is the iPad output, set OUTPUT_NAME to match instead'
        stray=1
    done
    ((stray)) || ivm_ok "no leftover virtual outputs"

    if display_exists; then
        if display_enabled; then
            ivm_ok "$IVM_OUTPUT_NAME exists: $(display_geometry)"
            case $(display_adjacency) in
                ok) ivm_ok "$IVM_OUTPUT_NAME touches another output (pointer can reach it)" ;;
                gap)
                    ivm_fail "$IVM_OUTPUT_NAME does not touch another output"
                    ivm_detail 'the cursor cannot cross empty space; the mouse never reaches it'
                    ;;
            esac
            if ! sunshine_session_active; then
                ivm_warn "$IVM_OUTPUT_NAME is still present although no stream is running"
                ivm_detail 'the prep command creates it, but nothing removes it on disconnect'
                ivm_detail 'that is the job of the supervisor; check: systemctl --user status ivm-watch'
            fi
        else
            ivm_info "$IVM_OUTPUT_NAME exists but is disabled"
        fi
    elif sunshine_session_active; then
        ivm_fail "$IVM_OUTPUT_NAME does not exist while a stream is running"
        ivm_detail 'the prep command did not run, or failed; check the session log'
    else
        ivm_info "$IVM_OUTPUT_NAME does not exist (it is created when a client connects)"
    fi

    local wanted
    if ! have hyprctl; then
        return 0
    fi
    if ! wanted=$(sunshine_output_name); then
        ivm_warn 'Sunshine has no output_name configured'
        ivm_detail "set output_name = $IVM_OUTPUT_NAME in the Sunshine config"
    elif [[ $wanted != "$IVM_OUTPUT_NAME" ]]; then
        ivm_warn "Sunshine captures '$wanted' but the tool creates '$IVM_OUTPUT_NAME'"
        ivm_detail "change output_name, or set OUTPUT_NAME=$wanted in the ivm config"
    else
        ivm_ok "Sunshine captures $wanted"
    fi

    if [[ -n $(sunshine_prep_command) ]]; then
        ivm_ok 'Sunshine has a prep command configured'
    else
        ivm_warn 'Sunshine has no global_prep_cmd, so nothing creates the output'
        ivm_detail 'until ivm ships its hook, the output must exist before connecting'
    fi
}

_doctor_stream() {
    ivm_section 'Layer 4 — Stream'

    local unit
    if ! unit=$(sunshine_unit); then
        ivm_fail 'no Sunshine user service is installed'
        return 0
    fi
    ivm_detail "unit: $unit"

    local pid
    if sunshine_active && pid=$(sunshine_pid); then
        ivm_ok "Sunshine is running (pid $pid)"
    else
        ivm_fail 'Sunshine is not running'
        ivm_detail 'it can die at boot when it starts before the compositor'
        ivm_detail "start it with: systemctl --user start $unit"
        ivm_detail 'and make it retry with Restart=always in a drop-in'
    fi

    if ! sunshine_capture_is_wlr; then
        local capture
        capture=$(sunshine_conf_get capture)
        ivm_fail "capture backend is '${capture:-unset}', not 'wlr'"
        ivm_detail 'the kms backend cannot see virtual outputs and streams a clone'
        ivm_detail 'set capture = wlr in the Sunshine config'
    else
        ivm_ok 'capture backend is wlr'
    fi

    local encoders
    if encoders=$(sunshine_encoders) && [[ -n $encoders ]]; then
        ivm_ok "encoders available: $(awk 'NR <= 2' <<<"$encoders" | paste -sd, -)"
    else
        ivm_warn 'no encoder was found in the Sunshine log'
        ivm_detail 'it may be missing, rotated or empty; check it manually'
    fi

    # The TCP ports are opened at startup. The UDP media ports only exist while a
    # client is streaming, so treating them as a failure when idle would report
    # a healthy host as broken.
    local port address bad=0
    for port in $IVM_SUNSHINE_PORTS_TCP; do
        address=$(sunshine_port_address "$port")
        if [[ -z $address ]]; then
            ivm_fail "port $port is not listening"
            bad=1
        elif [[ $address == 127.0.0.1 || $address == '::1' ]]; then
            ivm_fail "port $port only listens on loopback ($address)"
            ivm_detail 'the iPad cannot reach it; bind to all interfaces'
            bad=1
        fi
    done
    ((bad)) || ivm_ok 'every Sunshine control port listens on all interfaces'

    if sunshine_session_active; then
        bad=0
        for port in $IVM_SUNSHINE_PORTS_UDP; do
            address=$(sunshine_port_address "$port")
            if [[ -z $address ]]; then
                ivm_fail "media port $port is not listening during a session"
                bad=1
            elif [[ $address == 127.0.0.1 || $address == '::1' ]]; then
                ivm_fail "media port $port only listens on loopback ($address)"
                bad=1
            fi
        done
        ((bad)) || ivm_ok 'every Sunshine media port listens on all interfaces'
        ivm_ok "a session is running: $(sunshine_session_threads | paste -sd' ' -)"
    else
        ivm_info 'no active session'
        ivm_detail 'the UDP media ports open only while a client streams'
    fi
}

_doctor_summary() {
    printf '\n%sSummary%s  %d ok, %d warnings, %d failures\n' \
        "$IVM_C_BOLD" "$IVM_C_RESET" "$IVM_COUNT_OK" "$IVM_COUNT_WARN" "$IVM_COUNT_FAIL"

    if ((IVM_COUNT_FAIL > 0)); then
        printf 'Fix the first failure: everything above it is a precondition.\n'
        return "$IVM_EXIT_PROBLEMS"
    fi
    if ((IVM_COUNT_WARN > 0)); then
        printf 'Usable, but the warnings above are worth fixing.\n'
        return "$IVM_EXIT_OK"
    fi
    printf 'Every layer looks healthy.\n'
    return "$IVM_EXIT_OK"
}
