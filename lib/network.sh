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
