# shellcheck shell=bash
#
# Layer 1: the USB link itself.
#
# The network interface name is never hardcoded. The iPad is an Apple USB device,
# and its interfaces are discovered by walking sysfs from the vendor id down to
# the net devices underneath it. On the reference machine that yields usb0 and
# usb1, but any other numbering works the same way.
#
# The private interface (usb1 there) carries the Apple multiplexor and must stay
# out of NetworkManager's hands: managing it only produces a connection that
# never activates.

IVM_APPLE_VENDOR_ID='05ac'
IVM_USBMUXD_DEFAULT_DEVICE_MODE='3'

# Absolute paths of the Apple USB devices currently present.
usb_apple_devices() {
    local dir vendor
    for dir in /sys/bus/usb/devices/*/; do
        [[ -r $dir/idVendor ]] || continue
        read -r vendor <"$dir/idVendor" || continue
        [[ $vendor == "$IVM_APPLE_VENDOR_ID" ]] || continue
        printf '%s\n' "${dir%/}"
    done
}

# True when at least one Apple device is on the bus.
usb_ipad_present() {
    local first
    first=$(usb_apple_devices | awk 'NR == 1 { print }')
    [[ -n $first ]]
}

# Product id of the first Apple device, for the report.
usb_ipad_product_id() {
    local dir
    dir=$(usb_apple_devices | awk 'NR == 1 { print }') || return 1
    [[ -n $dir && -r $dir/idProduct ]] || return 1
    cat "$dir/idProduct"
}

# Network interfaces exposed by Apple devices, in sysfs order.
#
# The device directories under /sys/bus/usb/devices are symlinks, so this walks
# them with shell globs instead of find: a symlink is not descended into by
# default.
usb_net_interfaces() {
    local dir net
    while IFS= read -r dir; do
        for net in "$dir"/*/net/*/; do
            [[ -d $net ]] || continue
            printf '%s\n' "${net%/}" | sed 's#.*/##'
        done
    done < <(usb_apple_devices) | sort -u
}

# The interface that carries the data network: the one with an IPv4 address.
# Falls back to the first interface so the caller can still report something.
usb_data_interface() {
    local iface
    for iface in $(usb_net_interfaces); do
        if ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
            printf '%s' "$iface"
            return 0
        fi
    done
    usb_net_interfaces | awk 'NR == 1 { print }'
}

# Every Apple interface except the data one.
usb_private_interfaces() {
    local data iface
    data=$(usb_data_interface)
    for iface in $(usb_net_interfaces); do
        [[ $iface == "$data" ]] && continue
        printf '%s\n' "$iface"
    done
}

# Which usbmuxd binary is actually in use. The one shipped by the distribution
# cannot switch the device mode, so a locally built copy in /usr/local wins.
usbmuxd_binary() {
    local candidate
    for candidate in /usr/local/sbin/usbmuxd /usr/local/bin/usbmuxd \
        /usr/sbin/usbmuxd /usr/bin/usbmuxd; do
        if [[ -x $candidate ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    local found
    if found=$(command -v usbmuxd 2>/dev/null); then
        printf '%s' "$found"
        return 0
    fi
    return 1
}

# True when the binary contains the mode-switch support. The feature was added
# upstream after the last release, so presence of this symbol is the only
# reliable way to tell a capable build from a stale package.
usbmuxd_supports_mode3() {
    local binary
    binary=$(usbmuxd_binary) || return 1
    [[ -r $binary ]] || return 1
    # grep -c instead of grep -q: -q closes the pipe early, strings dies from
    # SIGPIPE and pipefail turns a successful match into a failure.
    local matches
    matches=$(strings "$binary" 2>/dev/null | grep -c 'USBMUXD_DEFAULT_DEVICE_MODE' || true)
    ((matches > 0))
}

# True when the daemon is running.
usbmuxd_active() {
    systemctl is-active --quiet usbmuxd 2>/dev/null || pgrep -x usbmuxd >/dev/null 2>&1
}

# The environment the daemon is started with, for the report.
usbmuxd_environment() {
    systemctl show usbmuxd -p Environment --value 2>/dev/null
}
