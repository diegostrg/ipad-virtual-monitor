# shellcheck shell=bash
#
# Layer 2: the private IP network carried by the USB cable.
#
# NetworkManager puts a shared IPv4 network on the data interface and runs DHCP
# for it. Nothing here changes that: these helpers only read.

# First IPv4 address of an interface, with prefix length (10.42.0.1/24).
net_ipv4_cidr() {
    local iface=$1
    ip -4 -o addr show dev "$iface" 2>/dev/null |
        awk '!found && $4 ~ /\// { print $4; found = 1 }'
}

# IPv4 address without the prefix.
net_ipv4_addr() {
    local cidr
    cidr=$(net_ipv4_cidr "$1")
    printf '%s' "${cidr%%/*}"
}

# IPv4 network in CIDR notation (10.42.0.0/24).
net_ipv4_network() {
    local iface=$1 cidr
    cidr=$(net_ipv4_cidr "$iface")
    [[ -n $cidr ]] || return 1
    local addr=${cidr%%/*} prefix=${cidr##*/}
    local a b c d
    IFS=. read -r a b c d <<<"$addr"
    local mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    printf '%d.%d.%d.%d/%d\n' \
        $(( a & (mask >> 24 & 255) )) \
        $(( b & (mask >> 16 & 255) )) \
        $(( c & (mask >> 8 & 255) )) \
        $(( d & (mask & 255) )) \
        "$prefix"
}

# The peer address seen on the interface: the iPad's lease.
net_peer_address() {
    local iface=$1
    ip neigh show dev "$iface" 2>/dev/null |
        awk '!found && $1 ~ /^[0-9.]+$/ && $NF ~ /REACHABLE|STALE|DELAY|PROBE/ { print $1; found = 1 }'
}

# Round-trip time in milliseconds to an address, or empty when unreachable.
net_ping_ms() {
    local host=$1 output
    # LC_ALL=C: the output is parsed, and a translated "tiempo=1.77 ms" is not
    # the same string as "time=1.77 ms".
    output=$(LC_ALL=C ping -c 1 -W 1 -n "$host" 2>/dev/null) || return 1
    awk 'match($0, /time=[0-9.]+/) { print substr($0, RSTART + 5, RLENGTH - 5); exit }' <<<"$output"
}

# True when something is listening for DHCP requests.
net_dhcp_listening() {
    ss -lntu 2>/dev/null | awk '$5 ~ /:67$/ { found = 1 } END { exit !found }'
}

# True when NetworkManager considers the interface unmanaged.
net_iface_unmanaged() {
    local iface=$1 state
    state=$(LC_ALL=C nmcli -g GENERAL.STATE device show "$iface" 2>/dev/null)
    [[ $state == *unmanaged* || $state == *"sin gestión"* ]]
}

# Name of the active NetworkManager connection on an interface, or empty.
net_active_connection() {
    local iface=$1
    nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null |
        awk -F: -v d="$iface" '!found && $2 == d { print $1; found = 1 }'
}

# True when a firewall service is running. UFW is the reference, but iptables
# and nftables setups are reported instead of ignored.
net_firewall_active() {
    systemctl is-active --quiet ufw 2>/dev/null && return 0
    systemctl is-active --quiet firewalld 2>/dev/null && return 0
    systemctl is-active --quiet nftables 2>/dev/null && return 0
    return 1
}

# Which firewall is running, for the report.
net_firewall_name() {
    if systemctl is-active --quiet ufw 2>/dev/null; then
        printf 'ufw'
    elif systemctl is-active --quiet firewalld 2>/dev/null; then
        printf 'firewalld'
    elif systemctl is-active --quiet nftables 2>/dev/null; then
        printf 'nftables'
    else
        printf 'none'
    fi
}

# ---------------------------------------------------------------------------
# Inspecting the NetworkManager configuration
# ---------------------------------------------------------------------------
#
# Everything below reads. The commands that change the system live in `ivm net`,
# which announces each one and asks before running it as root.

# The connection profile bound to an interface: the active one, or any profile
# that names the interface. Returns non-zero when there is none yet.
net_profile_for_iface() {
    local iface=$1 name bound
    name=$(net_active_connection "$iface")
    if [[ -n $name ]]; then
        printf '%s' "$name"
        return 0
    fi
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        bound=$(net_profile_field "$name" connection.interface-name)
        if [[ $bound == "$iface" ]]; then
            printf '%s' "$name"
            return 0
        fi
    done < <(LC_ALL=C nmcli -t -f NAME connection show 2>/dev/null)
    return 1
}

# One property of a saved connection profile, read-only.
net_profile_field() {
    local name=$1 field=$2
    LC_ALL=C nmcli -g "$field" connection show "$name" 2>/dev/null
}

# True when the profile is what the USB link needs: a shared IPv4 network with
# its own DHCP server, no IPv6, and automatic activation when the cable appears.
#
# A shared connection is the whole trick: NetworkManager runs dnsmasq for it, so
# the iPad gets an address without anything else being configured.
net_profile_healthy() {
    local name=$1 iface=$2 method ipv6 auto bound
    method=$(net_profile_field "$name" ipv4.method)
    [[ $method == shared ]] || return 1
    ipv6=$(net_profile_field "$name" ipv6.method)
    case $ipv6 in
        disabled|ignore) ;;
        *) return 1 ;;
    esac
    auto=$(net_profile_field "$name" connection.autoconnect)
    [[ $auto == yes ]] || return 1
    bound=$(net_profile_field "$name" connection.interface-name)
    [[ -z $bound || $bound == "$iface" ]]
}

# True when the profile is active on the interface right now.
net_profile_active() {
    local name=$1 iface=$2
    [[ $(net_active_connection "$iface") == "$name" ]]
}

# Configuration files NetworkManager reads, in the order it reads them.
IVM_NM_CONF_DIR=${IVM_NM_CONF_DIR:-/etc/NetworkManager}

net_nm_conf_files() {
    local dir=$IVM_NM_CONF_DIR file
    if [[ -r $dir/NetworkManager.conf ]]; then
        printf '%s\n' "$dir/NetworkManager.conf"
    fi
    for file in "$dir"/conf.d/*.conf; do
        [[ -r $file ]] && printf '%s\n' "$file"
    done
}

# True when a NetworkManager configuration file already marks the interface
# unmanaged, so the setting survives a reload and a reboot.
net_iface_unmanaged_configured() {
    local iface=$1 file line
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        while IFS= read -r line; do
            [[ $line == *unmanaged-devices* ]] || continue
            [[ $line == *"interface-name:${iface}"* ]] && return 0
        done <"$file"
    done < <(net_nm_conf_files)
    return 1
}

# The value for `unmanaged-devices`, one entry per interface.
#
# Semicolons separate the entries; commas are what NetworkManager uses between
# properties, not between list items.
net_unmanaged_value() {
    local iface out=''
    for iface in "$@"; do
        out+="${out:+;}interface-name:${iface}"
    done
    printf '%s' "$out"
}

IVM_UFW_USER_RULES=${IVM_UFW_USER_RULES:-/etc/ufw/user.rules}

# The DHCP rule UFW has for an interface: `broad`, `narrow` or nothing.
#
# The live ruleset needs root to read; the saved one does not, and a rule that
# exists in the file but was never reloaded is a different problem that `ivm net
# up` answers by reloading.
#
# The distinction between the two kinds matters more than it looks. A DHCP client
# with no lease sends its request to 255.255.255.255 from 0.0.0.0, so a rule that
# names a destination address — `allow in on usb0 to 10.42.0.1 port 67` — matches
# renewals and not the request that would grant a new lease. The iPad then works
# until it reconnects, and never again. Only a rule with no address restriction
# covers the whole exchange.
net_ufw_dhcp_rule() {
    local iface=$1 rules=$IVM_UFW_USER_RULES
    [[ -r $rules ]] || return 1
    awk -v i="$iface" '
        $1 == "-A" && index($0, "-i " i " ") && $0 ~ /-p udp/ && $0 ~ /--dport 67( |$)/ {
            restricted = 0
            for (n = 1; n <= NF; n++) {
                if ($n != "-d" && $n != "-s") continue
                address = $(n + 1)
                if (address != "0.0.0.0/0" && address != "any" && address != "0.0.0.0") {
                    restricted = 1
                }
            }
            if (restricted) narrow = 1
            else broad = 1
        }
        END {
            if (broad) print "broad"
            else if (narrow) print "narrow"
        }' "$rules"
}

# True when the ruleset lets a fresh DHCP request through, which is what the
# tablet needs after reconnecting.
net_ufw_allows_dhcp() {
    [[ $(net_ufw_dhcp_rule "$1") == broad ]]
}
