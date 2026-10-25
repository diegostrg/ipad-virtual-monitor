#!/usr/bin/env bash
#
# Checks for the USB network command.
#
# The two things worth testing without root are the plan and the parsing that
# feeds it: which commands `ivm net up` would run, in which order, and whether it
# recognises a configuration that is already right. Running the plan for real is
# covered by the `_net_step` checks, which use a plain file as the "command".
#
# Run: ./tests/net.sh

set -uo pipefail

IVM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
for _module in common config platform usb network net; do
    . "$IVM_ROOT/lib/$_module.sh"
done
unset _module

failures=0
checks=0

check() {
    local what=$1 expected=$2 actual=$3
    checks=$((checks + 1))
    if [[ $expected == "$actual" ]]; then
        printf '  ok   %s\n' "$what"
    else
        printf '  FAIL %s (expected %s, got %s)\n' "$what" "$expected" "$actual"
        failures=$((failures + 1))
    fi
}

check_contains() {
    local what=$1 needle=$2 haystack=$3
    checks=$((checks + 1))
    if [[ $haystack == *"$needle"* ]]; then
        printf '  ok   %s\n' "$what"
    else
        printf '  FAIL %s (missing: %s)\n' "$what" "$needle"
        printf '       got: %s\n' "$haystack"
        failures=$((failures + 1))
    fi
}

check_lacks() {
    local what=$1 needle=$2 haystack=$3
    checks=$((checks + 1))
    if [[ $haystack != *"$needle"* ]]; then
        printf '  ok   %s\n' "$what"
    else
        printf '  FAIL %s (unexpected: %s)\n' "$what" "$needle"
        failures=$((failures + 1))
    fi
}

status_of() {
    "$@" >/dev/null 2>&1
    printf '%s' "$?"
}

# Run a plan in this shell, keeping its output.
#
# Not `output=$(...)`: a command substitution is a subshell, so the counters a
# plan updates would be thrown away and the checks would read zero.
capture() {
    "$@" >"$tmpdir/out" 2>&1
    output=$(<"$tmpdir/out")
}

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmpdir"' EXIT

# --- quoting ---------------------------------------------------------------

check 'plain words need no quotes' \
    'sudo nmcli connection up ipad-usb' "$(_net_quote sudo nmcli connection up ipad-usb)"
check 'a word with spaces is quoted' \
    "sudo nmcli connection up 'my link'" "$(_net_quote sudo nmcli connection up 'my link')"
check 'a single quote is escaped' \
    "echo 'it'\\''s'" "$(_net_quote echo "it's")"
check 'an empty word is visible' \
    'echo ""' "$(_net_quote echo '')"

# --- the unmanaged list ----------------------------------------------------

check 'one interface' 'interface-name:usb1' "$(net_unmanaged_value usb1)"
check 'two interfaces are separated by a semicolon' \
    'interface-name:usb1;interface-name:usb2' "$(net_unmanaged_value usb1 usb2)"

# --- reading the configuration --------------------------------------------

mkdir -p "$tmpdir/nm/conf.d"
cat >"$tmpdir/nm/conf.d/99-ivm-usb.conf" <<'EOF'
[keyfile]
unmanaged-devices=interface-name:usb1
EOF
IVM_NM_CONF_DIR=$tmpdir/nm
check 'a configured private interface is recognised' \
    0 "$(status_of net_iface_unmanaged_configured usb1)"
check 'the data interface is not in the list' \
    1 "$(status_of net_iface_unmanaged_configured usb0)"

IVM_NM_CONF_DIR=$tmpdir/absent
check 'a missing configuration directory is not an error' \
    1 "$(status_of net_iface_unmanaged_configured usb1)"

# --- the ufw rule ----------------------------------------------------------

cat >"$tmpdir/user.rules" <<'EOF'
*filter
:ufw-user-input - [0:0]
### tuple ### allow udp 67 0.0.0.0/0 any 0.0.0.0/0 in_usb0
-A ufw-user-input -i usb0 -p udp --dport 67 -j ACCEPT
COMMIT
EOF
IVM_UFW_USER_RULES=$tmpdir/user.rules
check 'a DHCP rule for the interface is found' 0 "$(status_of net_ufw_allows_dhcp usb0)"
check 'another interface does not match it' 1 "$(status_of net_ufw_allows_dhcp usb9)"

cat >"$tmpdir/wrong-port.rules" <<'EOF'
-A ufw-user-input -i usb0 -p udp --dport 68 -j ACCEPT
-A ufw-user-input -i usb0 -p tcp --dport 67 -j ACCEPT
EOF
IVM_UFW_USER_RULES=$tmpdir/wrong-port.rules
check 'the wrong port is not accepted' 1 "$(status_of net_ufw_allows_dhcp usb0)"
check 'the wrong protocol is not accepted' 1 "$(status_of net_ufw_allows_dhcp usb0)"

IVM_UFW_USER_RULES=$tmpdir/missing.rules
check 'a missing rules file means "no rule"' 1 "$(status_of net_ufw_allows_dhcp usb0)"

# --- a step prints, or runs ------------------------------------------------

IVM_NET_STEPS=0 IVM_NET_APPLY=0
capture _net_step 'did nothing' touch "$tmpdir/never"
check 'the plan shows the command' \
    "  plan touch $tmpdir/never" "$output"
check 'the plan counts one step' 1 "$IVM_NET_STEPS"
check 'the plan runs nothing' 0 "$([[ -e $tmpdir/never ]] && echo 1 || echo 0)"

IVM_NET_STEPS=0 IVM_NET_APPLY=1 IVM_NET_DONE=0 IVM_NET_FAILED=0
capture _net_step 'created the marker' touch "$tmpdir/marker"
check 'applying runs the command' 1 "$([[ -e $tmpdir/marker ]] && echo 1 || echo 0)"
check 'applying reports success' 0 "$IVM_NET_FAILED"
check 'applying counts it' 1 "$IVM_NET_DONE"

IVM_NET_STEPS=0 IVM_NET_APPLY=1 IVM_NET_DONE=0 IVM_NET_FAILED=0
status=0
_net_step 'this one fails' false >/dev/null 2>&1 || status=$?
check 'a failing step is reported' 1 "$IVM_NET_FAILED"
check 'a failing step returns non-zero' 1 "$status"

# --- the plan for a healthy link ------------------------------------------

usb_private_interfaces() { printf 'usb1\n'; }
net_iface_unmanaged() { return 0; }
net_iface_unmanaged_configured() { return 0; }
net_firewall_name() { printf 'none'; }

net_profile_for_iface() { printf 'iPad-USB-Tethering'; }
net_profile_healthy() { return 0; }
net_profile_active() { return 0; }
IVM_NET_STEPS=0 IVM_NET_APPLY=0
capture _net_converge_profile usb0
check 'a healthy, active profile needs no command' '' "$output"

# --- an unhealthy profile --------------------------------------------------

net_profile_healthy() { return 1; }
IVM_NET_STEPS=0
capture _net_converge_profile usb0
check_contains 'it is set to shared' 'ipv4.method shared' "$output"
check_contains 'IPv6 is disabled' 'ipv6.method disabled' "$output"
check_contains 'it is reactivated afterwards' 'connection up iPad-USB-Tethering' "$output"
check 'two commands, in order' 2 "$IVM_NET_STEPS"

# --- no profile yet --------------------------------------------------------

net_profile_for_iface() { return 1; }
IVM_NET_STEPS=0
capture _net_converge_profile usb0
check_contains 'a profile is created on the interface' \
    'connection add type ethernet ifname usb0' "$output"
check_contains 'the new profile is shared' 'ipv4.method shared' "$output"
check_contains 'and it is activated' 'connection up ipad-usb' "$output"

# --- the Apple private interface ------------------------------------------

net_iface_unmanaged() { return 1; }
IVM_NET_STEPS=0
capture _net_converge_unmanaged
check_contains 'the configuration file is shown' "write $IVM_NET_CONF" "$output"
check_contains 'with the interface excluded' 'unmanaged-devices=interface-name:usb1' "$output"
check_contains 'NetworkManager is reloaded' 'nmcli general reload conf' "$output"

net_iface_unmanaged() { return 0; }
net_iface_unmanaged_configured() { return 1; }
IVM_NET_STEPS=0
capture _net_converge_unmanaged
check_contains 'a runtime-only exclusion is made permanent' 'unmanaged-devices' "$output"

net_iface_unmanaged_configured() { return 0; }
IVM_NET_STEPS=0
capture _net_converge_unmanaged
check 'a permanent exclusion needs nothing' '' "$output"

# --- the firewall ----------------------------------------------------------

net_firewall_name() { printf 'ufw'; }
IVM_UFW_USER_RULES=$tmpdir/user.rules
IVM_NET_STEPS=0
capture _net_converge_firewall usb0
check 'an existing rule needs nothing' '' "$output"

IVM_UFW_USER_RULES=$tmpdir/wrong-port.rules
IVM_NET_STEPS=0
capture _net_converge_firewall usb0
check_contains 'a missing rule is added' 'ufw allow in on usb0' "$output"
check_contains 'scoped to the interface' 'to any port 67 proto udp' "$output"

net_firewall_name() { printf 'none'; }
IVM_UFW_USER_RULES=$tmpdir/wrong-port.rules
IVM_NET_STEPS=0
capture _net_converge_firewall usb0
check 'no firewall means no rule' '' "$output"

# --- taking it down --------------------------------------------------------

net_profile_for_iface() { printf 'iPad-USB-Tethering'; }
net_profile_active() { return 0; }
IVM_NET_STEPS=0
capture _net_plan_down usb0
check_contains 'the shared connection is deactivated' \
    'nmcli connection down iPad-USB-Tethering' "$output"

net_profile_active() { return 1; }
IVM_NET_STEPS=0
capture _net_plan_down usb0
check 'an inactive connection needs nothing' '' "$output"

net_profile_for_iface() { return 1; }
IVM_NET_STEPS=0
capture _net_plan_down usb0
check 'nothing bound to the interface needs nothing' '' "$output"

printf '\n%d checks, %d failures\n' "$checks" "$failures"
((failures == 0))
