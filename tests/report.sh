#!/usr/bin/env bash
#
# Checks for the sanitizer behind `ivm doctor --report`.
#
# The report itself is a survey of the machine, so what is worth testing here is
# the part that decides what may be published: addresses, hardware identifiers,
# hostnames, user names and home paths. A regression in that function leaks
# personal data into a bug tracker, which is the one failure this command exists
# to prevent.
#
# Run: ./tests/report.sh

set -uo pipefail

IVM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
for _module in common config doctor; do
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
        printf '  FAIL %s (still contains: %s)\n' "$what" "$needle"
        failures=$((failures + 1))
    fi
}

# The host and user names are part of what gets replaced, so they are fixed here
# instead of being read from the machine running the tests.
sanitize() {
    ( HOSTNAME=testhost USER=testuser; _doctor_sanitize )
}

sanitize_as() {
    local host=$1 user=$2
    ( HOSTNAME=$host USER=$user; _doctor_sanitize )
}

# --- addresses -------------------------------------------------------------

check 'an address becomes a placeholder' \
    '  ok   peer <ip> answers in 1.68 ms' \
    "$(printf '  ok   peer 10.42.0.42 answers in 1.68 ms' | sanitize)"

check 'a subnet keeps its prefix length' \
    '  ok   usb0 has <ip>/24' \
    "$(printf '  ok   usb0 has 10.42.0.1/24' | sanitize)"

check 'every address on a line is replaced' \
    '  ok   usb0 has <ip>/24 (network <ip>/24)' \
    "$(printf '  ok   usb0 has 10.42.0.1/24 (network 10.42.0.0/24)' | sanitize)"

check 'a version is not an address' \
    '  ok   usbmuxd 1.1.1-72-g3ded00c' \
    "$(printf '  ok   usbmuxd 1.1.1-72-g3ded00c' | sanitize)"

check 'a kernel release is not an address' \
    'kernel Linux 7.3.0-4-cachyos x86_64' \
    "$(printf 'kernel Linux 7.3.0-4-cachyos x86_64' | sanitize)"

# --- hardware identifiers --------------------------------------------------

check 'a MAC address becomes a placeholder' \
    '  ok   peer <mac>' \
    "$(printf '  ok   peer 02:00:5e:00:53:01' | sanitize)"

check 'a MAC is not left half-replaced' \
    '<mac>' \
    "$(printf '02:00:5e:00:53:01' | sanitize)"

# --- names and paths -------------------------------------------------------

check 'a home path loses the user name' \
    '  ok   prep /home/<user>/ipad-virtual-monitor/bin/ivm' \
    "$(printf '  ok   prep /home/testuser/ipad-virtual-monitor/bin/ivm' | sanitize)"

check 'another home path is replaced too' \
    '/home/<user>/.local/state/ivm/display.log' \
    "$(printf '/home/someoneelse/.local/state/ivm/display.log' | sanitize)"

check 'a bare user name is replaced' \
    '  ok   user <user> logged in' \
    "$(printf '  ok   user testuser logged in' | sanitize)"

check 'a bare hostname is replaced' \
    '  ok   host <host>' \
    "$(printf '  ok   host testhost' | sanitize)"

check 'a dotted hostname is escaped, not treated as a pattern' \
    '  ok   host <host>' \
    "$(printf '  ok   host my.host.example' | sanitize_as 'my.host.example' 'testuser')"

check 'the host and the user are told apart' \
    '  ok   host <host>, user <user>' \
    "$(printf '  ok   host otherhost, user testuser' | sanitize_as 'otherhost' 'testuser')"

check 'a name nested inside another word is left alone' \
    '  ok   testhostname' \
    "$(printf '  ok   testhostname' | sanitize)"

# --- control sequences -----------------------------------------------------

# A report is pasted into a text box; an escape sequence there is garbage.
check 'escape codes are stripped' '  ok   colored' \
    "$(printf '\033[32m  ok   colored\033[0m' | sanitize)"

# --- the wrapper -----------------------------------------------------------

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmpdir"' EXIT

printf '  ok   usb0 has 10.42.0.1/24\n  ok   peer 10.42.0.42\n  ok   prep /home/testuser/ivm\n' \
    >"$tmpdir/body"
report=$( ( HOSTNAME=testhost USER=testuser; _doctor_report_print "$tmpdir/body" ) )
check_contains 'the report names the tool' 'ivm report' "$report"
check_contains 'the header explains the placeholders' 'Placeholders: <ip>, <mac>, <host>, <user>' "$report"
check_contains 'the body is included' 'usb0 has <ip>/24' "$report"
check_contains 'the report closes' 'End of report.' "$report"
check_lacks 'no real address survives' '10.42.0.42' "$report"
check_lacks 'no home path survives' '/home/testuser' "$report"

# --- end to end ------------------------------------------------------------

# Slow compared with the rest, but it is the command users actually run, and it
# must work even on a host where every layer is broken: the report is the point.
integration=$("$IVM_ROOT/bin/ivm" doctor --report 2>&1)
integration_status=$?
check_contains 'ivm doctor --report produces a report' 'ivm report' "$integration"
check_contains 'and it reaches the end' 'End of report.' "$integration"
if [[ $integration_status -eq 0 || $integration_status -eq 1 ]]; then
    check 'the exit code is the survey result' ok ok
else
    check 'the exit code is the survey result' '0 or 1' "$integration_status"
fi
check_lacks 'the real report has no escape codes' "$(printf '\033')" "$integration"

printf '\n%d checks, %d failures\n' "$checks" "$failures"
((failures == 0))
