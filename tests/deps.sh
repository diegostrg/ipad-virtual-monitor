#!/usr/bin/env bash
#
# Checks for `ivm deps`, the Apple USB stack inspector and builder.
#
# Nothing here builds anything: the plan is derived in dry-run mode, so every
# check walks the same code the user sees before confirming. The external world
# (pkg-config, systemd, the daemon, the toolchain) is replaced by stubs and by a
# temporary prefix, so the tests are fast, safe and independent of the machine.
#
# Run: ./tests/deps.sh

set -uo pipefail

IVM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
for _module in common config usb deps; do
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

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmpdir"' EXIT
mkdir -p "$tmpdir/prefix/lib/pkgconfig" "$tmpdir/os"

# The output is captured through a file, not $( ), so the counters a command
# updates survive and the test can read them.
output=$tmpdir/out
capture() {
    "$@" >"$output" 2>&1
    capture_status=$?
    text=$(<"$output")
}

text=''
capture_status=0
IVM_DEPS_PREFIX=$tmpdir/prefix
IVM_DEPS_DIR=$tmpdir/src
IVM_DEPS_DROPIN=$tmpdir/ncm.conf
IVM_OS_RELEASE=$tmpdir/os/release

# --- stubs -----------------------------------------------------------------

toolchain_missing=''
headers_missing=''
supports_mode=1
service_matches=1

_deps_toolchain_missing() { printf '%s' "$toolchain_missing"; }
_deps_headers_missing() { printf '%s' "$headers_missing"; }
_deps_supports_mode() { ((supports_mode)); }
usbmuxd_active() { return 0; }
usbmuxd_environment() { printf 'USBMUXD_DEFAULT_DEVICE_MODE=3'; }

systemctl() {
    case "$*" in
        *'show -p ExecStart'*)
            if ((service_matches)); then
                printf '{ path=%s/sbin/usbmuxd ; argv[]=%s/sbin/usbmuxd --user usbmux --systemd ; }\n' \
                    "$IVM_DEPS_PREFIX" "$IVM_DEPS_PREFIX"
            else
                printf '{ path=/usr/bin/usbmuxd ; argv[]=/usr/bin/usbmuxd --user usbmux ; }\n'
            fi
            ;;
        *) return 0 ;;
    esac
}

install_pc() {
    local module=$1 version=$2
    printf 'Name: %s\nVersion: %s\n' "$module" "$version" \
        >"$IVM_DEPS_PREFIX/lib/pkgconfig/$module.pc"
}

install_all_pc() {
    install_pc libplist-2.0 2.8.0
    install_pc libimobiledevice-glue-1.0 1.3.3
    install_pc libusbmuxd-2.0 2.1.1
    install_pc libtatsu-1.0 1.0.5
    install_pc libimobiledevice-1.0 1.4.0
}

write_good_dropin() {
    _deps_dropin_content >"$IVM_DEPS_DROPIN"
}

reset_state() {
    IVM_COUNT_OK=0
    IVM_COUNT_WARN=0
    IVM_COUNT_FAIL=0
    toolchain_missing=''
    headers_missing=''
    supports_mode=1
    service_matches=1
    rm -rf "$IVM_DEPS_PREFIX" "$IVM_DEPS_DIR" "$IVM_DEPS_DROPIN"
    mkdir -p "$IVM_DEPS_PREFIX/lib/pkgconfig"
}

# --- reading the install ---------------------------------------------------

reset_state
install_pc libplist-2.0 2.8.0
check 'a library version is read from our own prefix' '2.8.0' "$(_deps_module_version libplist-2.0)"
check 'a library that is not there reports nothing' '' "$(_deps_module_version libusbmuxd-2.0)"
check 'and fails' 1 "$(status_of _deps_module_version libusbmuxd-2.0)"

mkdir -p "$IVM_DEPS_PREFIX/lib64/pkgconfig"
printf 'Version: 9.9.9\n' >"$IVM_DEPS_PREFIX/lib64/pkgconfig/libfoo.pc"
check 'lib64 is used when lib is not there' '9.9.9' "$(_deps_module_version libfoo)"

# --- status ----------------------------------------------------------------

reset_state
install_all_pc
write_good_dropin
reset_state_counts() {
    IVM_COUNT_OK=0
    IVM_COUNT_WARN=0
    IVM_COUNT_FAIL=0
}
reset_state_counts
capture _deps_status
status=$capture_status
check 'a complete stack exits zero' 0 "$status"
check_contains 'and says so' 'The stack is ready. Nothing to build.' "$text"
check_contains 'it reports the prefix' "$IVM_DEPS_PREFIX" "$text"
check_contains 'it prints every library version' 'libusbmuxd 2.1.1' "$text"

reset_state
install_all_pc
rm -f "$IVM_DEPS_PREFIX/lib/pkgconfig/libtatsu-1.0.pc"
write_good_dropin
reset_state_counts
capture _deps_status
status=$capture_status
check 'a missing library is a failure' 1 "$status"
check_contains 'and is named' 'libtatsu is not installed there' "$text"
check_contains 'with the command that fixes it' 'ivm deps build' "$text"

reset_state
install_all_pc
write_good_dropin
supports_mode=0
reset_state_counts
capture _deps_status
status=$capture_status
check 'a daemon that cannot switch modes is a failure' 1 "$status"
check_contains 'and is explained' 'cannot request USB device mode 3' "$text"

reset_state
install_all_pc
write_good_dropin
service_matches=0
reset_state_counts
capture _deps_status
status=$capture_status
check 'a service pointing at another binary is a failure' 1 "$status"
check_contains 'and is named' 'does not run' "$text"

reset_state
install_all_pc
write_good_dropin
reset_state_counts
capture _deps_status_toolchain
check_contains 'the toolchain is reported' 'git, make' "$text"

reset_state
install_all_pc
write_good_dropin
toolchain_missing='make autoconf'
reset_state_counts
capture _deps_status_toolchain
check_contains 'missing tools are named' 'missing build tools: make autoconf' "$text"

# --- the plan --------------------------------------------------------------

reset_state
install_all_pc
write_good_dropin
capture _deps_build --dry-run
status=$capture_status
check 'a complete stack plans nothing' 0 "$status"
check_contains 'and says so' 'nothing to build' "$text"
check 'no commands are planned' 0 "$IVM_DEPS_STEPS"
check "the sources directory is not created" 'no' "$([[ -d $IVM_DEPS_DIR ]] && printf yes || printf no)"

reset_state
install_all_pc
rm -f "$IVM_DEPS_PREFIX/lib/pkgconfig/libusbmuxd-2.0.pc"
write_good_dropin
capture _deps_build --dry-run
status=$capture_status
check 'one missing library rebuilds the chain' 0 "$status"
check_contains 'starting with the first project' 'git clone --depth 1 https://github.com/libimobiledevice/libplist.git' "$text"
check_contains 'and ending with the daemon' 'usbmuxd.git' "$text"
check_contains 'in the documented order' \
    'libusbmuxd.git' "$text"
check_contains 'with the prefix passed to configure' "--prefix=$IVM_DEPS_PREFIX" "$text"
check_contains 'and pkg-config pointed at it' "PKG_CONFIG_PATH=$IVM_DEPS_PREFIX/lib/pkgconfig" "$text"
check_contains 'the daemon gets its state directories' '--runstatedir=/run' "$text"
check_contains 'the linker cache is updated' 'sudo ldconfig' "$text"
check_contains 'and the daemon is restarted' 'sudo systemctl restart usbmuxd' "$text"
check_lacks 'the drop-in is not rewritten when it matches' "write $IVM_DEPS_DROPIN" "$text"

reset_state
install_all_pc
write_good_dropin
supports_mode=0
capture _deps_build --dry-run
check 'a stale daemon alone is rebuilt alone' 0 "$capture_status"
check_contains 'only the daemon is cloned' 'usbmuxd.git' "$text"
check_lacks 'the libraries are left alone' 'libplist.git' "$text"

reset_state
install_all_pc
write_good_dropin
supports_mode=0
capture _deps_build --dry-run --force
check 'force rebuilds the libraries too' 0 "$capture_status"
check_contains 'the first library is cloned' 'libplist.git' "$text"

reset_state
install_all_pc
rm -f "$IVM_DEPS_DROPIN"
capture _deps_build --dry-run
status=$capture_status
check 'a missing drop-in does not trigger a build' 0 "$status"
check_lacks 'nothing is cloned' 'git clone' "$text"
check_contains 'the drop-in is planned' "write $IVM_DEPS_DROPIN" "$text"
check_contains 'with the mode in it' 'Environment=USBMUXD_DEFAULT_DEVICE_MODE=3' "$text"
check_contains 'pointing at our binary' "ExecStart=$IVM_DEPS_PREFIX/sbin/usbmuxd" "$text"
check_contains 'and systemd is reloaded' 'sudo systemctl daemon-reload' "$text"

reset_state
install_all_pc
printf '[Service]\nEnvironment=USBMUXD_DEFAULT_DEVICE_MODE=1\n' >"$IVM_DEPS_DROPIN"
capture _deps_build --dry-run
check_contains 'a wrong drop-in is rewritten' "write $IVM_DEPS_DROPIN" "$text"

reset_state
install_all_pc
write_good_dropin
toolchain_missing='make'
capture _deps_build --dry-run
status=$capture_status
check 'a missing toolchain stops before planning' 1 "$status"
check_contains 'and is named' 'missing build tools: make' "$text"
check 'with no steps planned' 0 "$IVM_DEPS_STEPS"

reset_state
install_all_pc
write_good_dropin
headers_missing='libusb-1.0'
capture _deps_build --dry-run
status=$capture_status
check 'missing headers stop before planning' 1 "$status"
check_contains 'and are named' 'missing development headers: libusb-1.0' "$text"

reset_state
install_all_pc
write_good_dropin
capture _deps_build --nonsense
check 'an unknown option is a usage error' 2 "$capture_status"

# --- the distribution hint -------------------------------------------------

cat >"$IVM_OS_RELEASE" <<'EOF'
ID=cachyos
ID_LIKE=arch
EOF
check_contains 'an Arch-based system gets the exact command' 'sudo pacman -S' "$(_deps_install_hint)"

cat >"$IVM_OS_RELEASE" <<'EOF'
ID=debian
EOF
check 'another distribution gets no invented command' '' "$(_deps_install_hint)"

# --- the drop-in content ---------------------------------------------------

reset_state
content=$(_deps_dropin_content)
check_contains 'the drop-in asks for mode 3' 'USBMUXD_DEFAULT_DEVICE_MODE=3' "$content"
check_contains 'it clears the inherited ExecStart first' 'ExecStart=' "$content"
check_contains 'and points at the built daemon' "$IVM_DEPS_PREFIX/sbin/usbmuxd" "$content"

printf '\n%d checks, %d failures\n' "$checks" "$failures"
((failures == 0))
