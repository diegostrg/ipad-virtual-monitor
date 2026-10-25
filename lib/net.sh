# shellcheck shell=bash
#
# `ivm net` — layer 2 as a command: report it, converge it, take it down.
#
# Almost everything that repairs this layer needs root: the connection profile,
# the NetworkManager configuration that keeps the Apple private interface out of
# its hands, and the firewall rule for DHCP. Instead of hiding that behind sudo,
# the tool derives a plan, prints the exact commands, and asks once:
#
#   ivm net status   reads only
#   ivm net up       plan → confirm → apply
#   ivm net down     deactivates the shared connection, keeps the configuration
#
# Nothing is re-parsed by a shell: every step is executed as a list of words, and
# the text shown before running it is the same list, quoted.

IVM_NET_PROFILE=${IVM_NET_PROFILE:-ipad-usb}
IVM_NET_CONF=${IVM_NET_CONF:-/etc/NetworkManager/conf.d/99-ivm-usb.conf}

# Whether the plan is being applied. Set to 1 only after the user agrees.
IVM_NET_APPLY=0
IVM_NET_YES=0
IVM_NET_DRY_RUN=0
IVM_NET_DECLINED=0
IVM_NET_STEPS=0
IVM_NET_DONE=0
IVM_NET_FAILED=0

_net_usage() {
    cat <<'EOF'
Usage:
  ivm net status [--verbose]     Report the USB network, read-only
  ivm net up [--dry-run] [--yes] Make it work: profile, NetworkManager, firewall
  ivm net down [--dry-run] [--yes] Deactivate the shared connection

`up` and `down` print every command they need, then ask once before running it
as root. --dry-run stops after the plan, --yes applies it without asking (for
scripts). The configuration is never removed: `down` only takes the network
down, so the next `up` is instant.
EOF
}

ivm_net() {
    local sub=${1:-status}
    if (($#)); then shift; fi

    case $sub in
        status) _net_status "$@" ;;
        up) _net_up "$@" ;;
        down) _net_down "$@" ;;
        help|-h|--help) _net_usage ;;
        *)
            ivm_error "net: unknown subcommand: $sub"
            _net_usage >&2
            return "$IVM_EXIT_USAGE"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------

# Quote a list of words for display. The words are executed as they are; this is
# only so the printed plan matches what runs.
_net_quote() {
    local word out=''
    for word in "$@"; do
        if [[ -z $word ]]; then
            out+=' ""'
        elif [[ $word =~ ^[A-Za-z0-9_./:=@+-]+$ ]]; then
            out+=" $word"
        else
            out+=" '${word//\'/\'\\\'\'}'"
        fi
    done
    printf '%s' "${out# }"
}

# One privileged step: printed as a plan, or announced and run.
#
# Returns non-zero only when the command fails, so a caller can stop instead of
# carrying on against a system that is not in the expected state.
_net_step() {
    local description=$1
    shift
    IVM_NET_STEPS=$((IVM_NET_STEPS + 1))

    if ((IVM_NET_APPLY)); then
        printf '  %srun %s %s\n' "$IVM_C_DIM" "$IVM_C_RESET" "$(_net_quote "$@")"
        if "$@"; then
            IVM_NET_DONE=$((IVM_NET_DONE + 1))
            ivm_ok "$description"
        else
            IVM_NET_FAILED=$((IVM_NET_FAILED + 1))
            ivm_fail "$description"
            return 1
        fi
    else
        printf '  %splan%s %s\n' "$IVM_C_YELLOW" "$IVM_C_RESET" "$(_net_quote "$@")"
    fi
    return 0
}

# Write a root-owned configuration file, showing its content first.
#
# A file is not a command, so it is shown as what it is: the lines that will end
# up on disk, followed by the command that puts them there.
_net_file_step() {
    local destination=$1 content=$2 description=$3 line
    IVM_NET_STEPS=$((IVM_NET_STEPS + 1))

    if ((IVM_NET_APPLY)); then
        printf '  %srun %s %s\n' "$IVM_C_DIM" "$IVM_C_RESET" "$(_net_quote sudo tee "$destination")"
        if printf '%s\n' "$content" | sudo tee "$destination" >/dev/null; then
            IVM_NET_DONE=$((IVM_NET_DONE + 1))
            ivm_ok "$description"
        else
            IVM_NET_FAILED=$((IVM_NET_FAILED + 1))
            ivm_fail "$description"
            return 1
        fi
    else
        printf '  %splan%s write %s\n' "$IVM_C_YELLOW" "$IVM_C_RESET" "$destination"
        while IFS= read -r line; do
            printf '       %s%s\n' "$IVM_C_DIM" "$line"
        done <<<"$content"
        printf '       %s\n' "$IVM_C_RESET"
    fi
    return 0
}

# Derive every step from the current state. Called twice: once to show the plan
# and once to run it. Each step re-reads the system, so a step that another one
# already fixed is not repeated.
_net_converge() {
    local iface=$1

    _net_converge_profile "$iface" || return 1
    _net_converge_unmanaged || return 1
    _net_converge_firewall "$iface" || return 1
    return 0
}

_net_converge_profile() {
    local iface=$1 profile changed=0
    profile=$(net_profile_for_iface "$iface") || profile=''

    if [[ -z $profile ]]; then
        _net_step "created the shared connection '$IVM_NET_PROFILE' on $iface" \
            sudo nmcli connection add type ethernet ifname "$iface" \
                con-name "$IVM_NET_PROFILE" \
                ipv4.method shared ipv6.method disabled \
                autoconnect yes || return 1
        profile=$IVM_NET_PROFILE
        changed=1
    elif ! net_profile_healthy "$profile" "$iface"; then
        # A shared method is what runs the DHCP server for the iPad. IPv6 is
        # disabled because there is nothing to route over a single cable, and a
        # second address family only adds waiting.
        _net_step "made '$profile' a shared IPv4 network without IPv6" \
            sudo nmcli connection modify "$profile" \
                ipv4.method shared ipv6.method disabled \
                connection.autoconnect yes || return 1
        changed=1
    fi

    # A changed profile has to be reactivated for the new method to take effect
    # and for dnsmasq to start serving DHCP.
    if ((changed)) || ! net_profile_active "$profile" "$iface"; then
        _net_step "activated '$profile' on $iface" \
            sudo nmcli connection up "$profile" || return 1
    fi
    return 0
}

_net_converge_unmanaged() {
    local iface missing=() content

    for iface in $(usb_private_interfaces); do
        # Two different faults: managed right now, or not excluded in the
        # configuration and therefore managed again after the next reload.
        if ! net_iface_unmanaged "$iface" || ! net_iface_unmanaged_configured "$iface"; then
            missing+=("$iface")
        fi
    done
    ((${#missing[@]})) || return 0

    content="# Written by ipad-virtual-monitor (ivm net up).
# The Apple USB multiplexor interface is not a network carrier. When
# NetworkManager manages it, it produces a connection that never activates.
[keyfile]
unmanaged-devices=$(net_unmanaged_value "${missing[@]}")"

    _net_file_step "$IVM_NET_CONF" "$content" \
        "marked $(printf '%s ' "${missing[@]}")as unmanaged" || return 1

    _net_step 'reloaded the NetworkManager configuration' \
        sudo nmcli general reload conf || return 1
    return 0
}

_net_converge_firewall() {
    local iface=$1
    case $(net_firewall_name) in
        ufw)
            if net_ufw_allows_dhcp "$iface"; then
                return 0
            fi
            # Said once, with the plan: the second pass would repeat it after the
            # user has already read it.
            if ! ((IVM_NET_APPLY)) && [[ $(net_ufw_dhcp_rule "$iface") == narrow ]]; then
                ivm_warn "the existing DHCP rule for $iface is limited to a fixed address"
                ivm_detail 'a new lease request is broadcast, so that rule does not match it'
            fi
            # Scoped to the interface on purpose: the same rule globally would
            # answer DHCP on Wi-Fi too.
            _net_step "allowed DHCP in on $iface through ufw" \
                sudo ufw allow in on "$iface" to any port 67 proto udp || return 1
            ;;
        firewalld|nftables)
            ivm_warn "$(net_firewall_name) is active; add the DHCP rule yourself"
            ivm_detail "allow UDP/67 in on $iface, scoped to that interface"
            ;;
        none) ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# ivm net status
# ---------------------------------------------------------------------------

_net_status() {
    local arg
    for arg in "$@"; do
        case $arg in
            --verbose|-v) IVM_VERBOSE=1 ;;
            -h|--help) _net_usage; return "$IVM_EXIT_OK" ;;
            *) ivm_error "net status: unknown argument: $arg"; return "$IVM_EXIT_USAGE" ;;
        esac
    done

    printf '%sivm net status%s %s\n' "$IVM_C_BOLD" "$IVM_C_RESET" "$IVM_VERSION"

    if ! usb_ipad_present; then
        ivm_warn 'the iPad is not on the USB bus'
        ivm_detail 'connect the cable and unlock it; the network needs no command'
        return "$IVM_EXIT_OK"
    fi

    ivm_section 'Link'
    local product
    if product=$(usb_ipad_product_id); then
        ivm_ok "Apple device on the USB bus (product id $product)"
    else
        ivm_ok 'Apple device on the USB bus'
    fi

    local iface
    iface=$(usb_data_interface)
    if [[ -z $iface ]]; then
        ivm_fail 'the iPad exposes no network interface'
        ivm_detail 'usbmuxd must request USB device mode 3; see docs/dependencies.md'
        return "$IVM_EXIT_PROBLEMS"
    fi
    ivm_ok "data interface: $iface"

    local private
    for private in $(usb_private_interfaces); do
        ivm_detail "private interface: $private (Apple multiplexor)"
    done

    ivm_section 'Address'
    local cidr
    cidr=$(net_ipv4_cidr "$iface")
    if [[ -n $cidr ]]; then
        ivm_ok "$iface has $cidr (network $(net_ipv4_network "$iface"))"
    else
        ivm_fail "$iface has no IPv4 address"
        ivm_detail 'a shared connection gives it 10.42.0.1/24 automatically'
    fi

    local peer rtt
    if peer=$(net_peer_address "$iface") && [[ -n $peer ]]; then
        if rtt=$(net_ping_ms "$peer") && [[ -n $rtt ]]; then
            ivm_ok "the iPad is at $peer, answering in $rtt ms"
        else
            ivm_warn "the iPad is at $peer but does not answer"
            ivm_detail 'it may be locked or asleep; the lease stays either way'
        fi
    else
        ivm_info "no lease seen from the iPad yet"
        ivm_detail 'it appears when the tablet is unlocked and has taken an address'
    fi

    ivm_section 'NetworkManager'
    local profile
    if profile=$(net_profile_for_iface "$iface"); then
        if net_profile_healthy "$profile" "$iface"; then
            ivm_ok "'$profile': shared IPv4, no IPv6, autoconnect"
            if net_profile_active "$profile" "$iface"; then
                ivm_ok "'$profile' is active on $iface"
            else
                ivm_warn "'$profile' is not active on $iface"
                ivm_detail "bring it up with: ivm net up"
            fi
        else
            ivm_fail "'$profile' is not the profile this link needs"
            ivm_detail "wanted: ipv4.method shared, ipv6.method disabled, autoconnect yes"
            ivm_detail "found: ipv4.method $(net_profile_field "$profile" ipv4.method), ipv6.method $(net_profile_field "$profile" ipv6.method)"
            ivm_detail 'repair it with: ivm net up'
        fi
    else
        ivm_fail "no connection profile is bound to $iface"
        ivm_detail 'create one with: ivm net up'
    fi

    for private in $(usb_private_interfaces); do
        if net_iface_unmanaged "$private"; then
            if net_iface_unmanaged_configured "$private"; then
                ivm_ok "$private is unmanaged, and stays so after a reload"
            else
                ivm_warn "$private is unmanaged now, but not in the configuration"
                ivm_detail 'it becomes managed again after a reload or a reboot'
                ivm_detail 'make it permanent with: ivm net up'
            fi
        else
            ivm_fail "$private is managed by NetworkManager"
            ivm_detail 'it stays in "activating" and never carries traffic'
            ivm_detail 'exclude it with: ivm net up'
        fi
    done

    ivm_section 'DHCP'
    if net_dhcp_listening; then
        ivm_ok 'a DHCP server is listening on UDP/67'
    else
        ivm_fail 'nothing is listening on UDP/67'
        ivm_detail 'a shared connection runs its own server; check it with: ivm net up'
    fi

    case $(net_firewall_name) in
        none)
            ivm_ok 'no firewall service is active, so nothing blocks DHCP'
            ;;
        ufw)
            case $(net_ufw_dhcp_rule "$iface") in
                broad)
                    ivm_ok "ufw allows DHCP in on $iface (saved ruleset)"
                    ivm_detail "verified in $IVM_UFW_USER_RULES; the live ruleset needs root"
                    ;;
                narrow)
                    ivm_fail "ufw allows DHCP to one address only, not to the broadcast"
                    ivm_detail 'a new lease request goes to 255.255.255.255, which that rule does not match'
                    ivm_detail 'the iPad keeps its lease until it reconnects, then gets nothing'
                    ivm_detail 'add the interface-wide rule with: ivm net up'
                    ;;
                *)
                    ivm_fail "ufw has no DHCP rule for $iface"
                    ivm_detail "a dropped DHCP request leaves the iPad without an address"
                    ivm_detail 'add it with: ivm net up'
                    ;;
            esac
            ;;
        *)
            ivm_warn "$(net_firewall_name) is active; its rules cannot be read without root"
            ivm_detail "allow UDP/67 in on $iface if the iPad never gets an address"
            ;;
    esac

    printf '\n'
    if ((IVM_COUNT_FAIL)); then
        printf 'The network cannot work in this state; run: ivm net up\n'
        return "$IVM_EXIT_PROBLEMS"
    fi
    printf 'The network is ready. Connect from Moonlight to %s.\n' "$(net_ipv4_addr "$iface")"
    return "$IVM_EXIT_OK"
}

# ---------------------------------------------------------------------------
# ivm net up / down
# ---------------------------------------------------------------------------

# Ask once, before anything runs as root. A plan is never applied silently, and
# in a non-interactive shell nothing is applied at all.
_net_confirm() {
    local count=$1 answer=''
    if ((IVM_NET_YES)); then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        ivm_info 'not a terminal, so nothing was changed'
        ivm_detail 'repeat with --yes to apply the plan'
        return 1
    fi
    printf '\nApply %d command(s) with sudo? [y/N] ' "$count"
    read -r answer || answer=''
    case $answer in
        y|Y|yes|YES|si|sí|s|S) return 0 ;;
        *) return 1 ;;
    esac
}

# Shared by `up` and `down`: plan, confirm, apply, then read the result back.
_net_run() {
    local action=$1 iface=$2
    shift 2

    IVM_NET_APPLY=0 IVM_NET_STEPS=0
    "_net_plan_${action}" "$iface" "$@" || return "$IVM_EXIT_PROBLEMS"

    if ((IVM_NET_STEPS == 0)); then
        ivm_ok 'nothing to change: the configuration is already in place'
        return 0
    fi

    if ((IVM_NET_DRY_RUN)); then
        printf '\n%d command(s) shown; nothing was run\n' "$IVM_NET_STEPS"
        return 0
    fi

    if ! have sudo; then
        ivm_fail 'sudo is not installed, so the plan cannot be applied'
        ivm_detail 'run the commands above as root'
        return "$IVM_EXIT_PROBLEMS"
    fi

    _net_confirm "$IVM_NET_STEPS" || {
        IVM_NET_DECLINED=1
        printf '\nNothing was changed. Repeat with --yes to apply the plan.\n'
        return 0
    }

    printf '\n'
    IVM_NET_APPLY=1 IVM_NET_STEPS=0 IVM_NET_DONE=0 IVM_NET_FAILED=0
    "_net_apply_${action}" "$iface" "$@" || true

    if ((IVM_NET_FAILED)); then
        ivm_detail 'the first failure above is the one to fix'
        return "$IVM_EXIT_PROBLEMS"
    fi
    return 0
}

_net_plan_up() { _net_converge "$1"; }
_net_apply_up() { _net_converge "$1"; }

_net_plan_down() {
    local iface=$1 profile
    profile=$(net_profile_for_iface "$iface") || profile=''
    [[ -n $profile ]] || return 0
    net_profile_active "$profile" "$iface" || return 0
    _net_step "deactivated '$profile' on $iface" \
        sudo nmcli connection down "$profile" || return 1
    return 0
}

_net_apply_down() { _net_plan_down "$@"; }

_net_up() {
    local arg
    IVM_NET_DRY_RUN=0
IVM_NET_DECLINED=0
    for arg in "$@"; do
        case $arg in
            --yes|-y) IVM_NET_YES=1 ;;
            --dry-run) IVM_NET_DRY_RUN=1 ;;
            --verbose|-v) IVM_VERBOSE=1 ;;
            -h|--help) _net_usage; return "$IVM_EXIT_OK" ;;
            *) ivm_error "net up: unknown argument: $arg"; return "$IVM_EXIT_USAGE" ;;
        esac
    done

    printf '%sivm net up%s\n' "$IVM_C_BOLD" "$IVM_C_RESET"

    if ! usb_ipad_present; then
        ivm_fail 'the iPad is not on the USB bus'
        ivm_detail 'connect the cable and unlock it; there is nothing to configure yet'
        return "$IVM_EXIT_PROBLEMS"
    fi

    local iface
    iface=$(usb_data_interface)
    if [[ -z $iface ]]; then
        ivm_fail 'the iPad exposes no network interface'
        ivm_detail 'usbmuxd must request USB device mode 3; see docs/dependencies.md'
        return "$IVM_EXIT_PROBLEMS"
    fi
    ivm_detail "data interface: $iface"

    _net_run up "$iface" || return "$IVM_EXIT_PROBLEMS"
    if ((IVM_NET_DRY_RUN || IVM_NET_DECLINED)); then
        return "$IVM_EXIT_OK"
    fi

    printf '\n'
    printf '%sResult%s\n' "$IVM_C_BOLD" "$IVM_C_RESET"
    _net_verify "$iface"
    return "$IVM_EXIT_OK"
}

_net_down() {
    local arg
    IVM_NET_DRY_RUN=0
IVM_NET_DECLINED=0
    for arg in "$@"; do
        case $arg in
            --yes|-y) IVM_NET_YES=1 ;;
            --dry-run) IVM_NET_DRY_RUN=1 ;;
            --verbose|-v) IVM_VERBOSE=1 ;;
            -h|--help) _net_usage; return "$IVM_EXIT_OK" ;;
            *) ivm_error "net down: unknown argument: $arg"; return "$IVM_EXIT_USAGE" ;;
        esac
    done

    printf '%sivm net down%s\n' "$IVM_C_BOLD" "$IVM_C_RESET"

    local iface
    iface=$(usb_data_interface)
    if [[ -z $iface ]]; then
        ivm_info 'the iPad is not connected, so there is no network to take down'
        return "$IVM_EXIT_OK"
    fi

    _net_run down "$iface" || return "$IVM_EXIT_PROBLEMS"
    if ((IVM_NET_DRY_RUN || IVM_NET_DECLINED)); then
        return "$IVM_EXIT_OK"
    fi

    if [[ -z $(net_profile_for_iface "$iface") ]] ||
        ! net_profile_active "$(net_profile_for_iface "$iface")" "$iface"; then
        ivm_ok "the shared connection is not active on $iface"
        ivm_detail 'the configuration is untouched: ivm net up brings it back'
    else
        ivm_fail "the connection is still active on $iface"
        return "$IVM_EXIT_PROBLEMS"
    fi
    return "$IVM_EXIT_OK"
}

# Read the result back instead of trusting the commands.
_net_verify() {
    local iface=$1 cidr peer rtt
    cidr=$(net_ipv4_cidr "$iface")
    if [[ -n $cidr ]]; then
        ivm_ok "$iface has $cidr"
    else
        ivm_warn "$iface has no address yet"
        ivm_detail 'NetworkManager takes a moment after activating a connection'
    fi

    if net_dhcp_listening; then
        ivm_ok 'a DHCP server is listening on UDP/67'
    else
        ivm_warn 'nothing is listening on UDP/67'
        ivm_detail 'the iPad will not get an address until the shared connection is active'
    fi

    if peer=$(net_peer_address "$iface") && [[ -n $peer ]]; then
        if rtt=$(net_ping_ms "$peer") && [[ -n $rtt ]]; then
            ivm_ok "the iPad answers at $peer in $rtt ms"
        else
            ivm_warn "the iPad is at $peer but does not answer"
            ivm_detail 'it may be locked or asleep'
        fi
    else
        ivm_info 'no lease from the iPad yet; unlock it and it will appear'
    fi
}
