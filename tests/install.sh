#!/usr/bin/env bash
#
# Checks for install.sh, the one-command installer.
#
# The installer is sourced, not executed, so the test drives the real plan and
# the real apply path while replacing everything external: `git`, the `ivm`
# command it would run, the compositor, the iPad and Sunshine. Nothing here
# touches the machine, and nothing needs root.
#
# Run: ./tests/install.sh

set -uo pipefail

IVM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
. "$IVM_ROOT/install.sh"
set +e

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
        printf '       got: %s\n' "${haystack//$'\n'/$'\n'            }"
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

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/state" "$tmpdir/local/bin"
export STUB_LOG=$tmpdir/state/calls
export STUB_STATE=$tmpdir/state

# --- the fake repository that `git clone` produces --------------------------

fake_repo=$tmpdir/fake-repo
mkdir -p "$fake_repo/bin"
cat >"$fake_repo/bin/ivm" <<'STUB'
#!/usr/bin/env bash
printf '%s :: ivm %s\n' "$0" "$*" >>"$STUB_LOG"
case $1 in
    deps)
        case ${2:-} in
            status)
                [[ -f $STUB_STATE/stack ]]
                exit
                ;;
            build)
                touch "$STUB_STATE/stack"
                printf 'built the stack\n'
                ;;
        esac
        ;;
    net) printf 'network configured\n' ;;
    up) printf 'host prepared\n' ;;
    doctor) printf 'Summary  18 ok, 0 warnings, 0 failures\n' ;;
esac
exit 0
STUB
chmod +x "$fake_repo/bin/ivm"

# --- stubs on PATH ----------------------------------------------------------

cat >"$tmpdir/bin/git" <<'STUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$STUB_LOG"
if [[ ${1:-} == clone ]]; then
    cp -r "$STUB_REPO" "$5"
fi
exit 0
STUB

cat >"$tmpdir/bin/pacman" <<'STUB'
#!/usr/bin/env bash
printf 'pacman %s\n' "$*" >>"$STUB_LOG"
exit 0
STUB

cat >"$tmpdir/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$STUB_LOG"
exit 0
STUB

cat >"$tmpdir/bin/hyprctl" <<'STUB'
#!/usr/bin/env bash
printf 'hyprctl %s\n' "$*" >>"$STUB_LOG"
exit 0
STUB

chmod +x "$tmpdir/bin/"*
export STUB_REPO=$fake_repo
PATH=$tmpdir/bin:$PATH

# --- a clean slate per test -------------------------------------------------

output=$tmpdir/out
text=''
status=0

capture() {
    "$@" >"$output" 2>&1
    status=$?
    text=$(<"$output")
}

reset_world() {
    rm -rf "$tmpdir/target" "$tmpdir/checkout" "$tmpdir/local/bin/ivm" "$STUB_STATE/stack"
    : >"$STUB_LOG"
    IVM_INSTALL_DIR=$tmpdir/target
    IVM_INSTALL_BIN=$tmpdir/local/bin
    IVM_INSTALL_DRY_RUN=0
    IVM_INSTALL_YES=0

    # The real world, replaced. Each test changes what it needs.
    _script_dir() { return 1; }
    _os_is_arch() { return 0; }
    _compositor_reachable() { return 0; }
    _ipad_present() { return 0; }
    _sunshine_present() { return 0; }
    _sunshine_command() { printf 'sudo pacman -S --needed sunshine'; }
    _ask() { return 1; }
}

count_calls() {
    local n
    n=$(grep -c -- "$1" "$STUB_LOG" 2>/dev/null) || n=0
    printf '%s' "$n"
}

# A checkout with the stub command, as if the repository was already cloned.
make_checkout() {
    local dir=$1
    mkdir -p "$dir/bin"
    cp "$fake_repo/bin/ivm" "$dir/bin/ivm"
}

# --- argument handling ------------------------------------------------------

reset_world
capture main --help
check 'help exits zero' 0 "$status"
check_contains 'and documents the dry run' '--dry-run' "$text"

capture main --nonsense
check 'an unknown argument is a usage error' 2 "$status"

capture main --dir
check 'a missing --dir value is a usage error' 2 "$status"

# --- the plan ---------------------------------------------------------------

reset_world
capture main --dry-run
check 'a fresh dry run exits zero' 0 "$status"
check_contains 'it plans the download' "download the repository into $IVM_INSTALL_DIR" "$text"
check_contains 'it plans the link' "link the command at $IVM_INSTALL_BIN/ivm" "$text"
check_contains 'it plans the stack, checked after cloning' \
    'check the Apple USB stack and build it if it is missing' "$text"
check_contains 'it plans the network' 'set up the USB network' "$text"
check_contains 'it plans the host' 'prepare Sunshine, the prep hook and the supervisor' "$text"
check 'and creates nothing' 'no' "$([[ -e $IVM_INSTALL_DIR ]] && printf yes || printf no)"
check 'nor downloads anything' 0 "$(count_calls 'git clone')"

reset_world
make_checkout "$IVM_INSTALL_DIR"
capture main --dry-run
check_contains 'an incomplete stack is planned' 'build the Apple USB stack (5 to 10 minutes)' "$text"
check_contains 'and an existing checkout is updated' "update the repository in $IVM_INSTALL_DIR" "$text"

reset_world
make_checkout "$IVM_INSTALL_DIR"
touch "$STUB_STATE/stack"
capture main --dry-run
check_contains 'a complete stack is skipped' 'skip the Apple USB stack: already built' "$text"

reset_world
_script_dir() { printf '%s' "$tmpdir/checkout"; }
make_checkout "$tmpdir/checkout"
touch "$STUB_STATE/stack"
capture main --dry-run
check_contains 'a local checkout is used as it is' "use this checkout: $tmpdir/checkout" "$text"
check_lacks 'and is not downloaded again' 'download the repository' "$text"

reset_world
make_checkout "$IVM_INSTALL_DIR"
_sunshine_present() { return 1; }
capture main --dry-run
check_contains 'missing Sunshine is planned' \
    'install Sunshine running: sudo pacman -S --needed sunshine' "$text"

reset_world
make_checkout "$IVM_INSTALL_DIR"
_sunshine_present() { return 1; }
_sunshine_command() { return 1; }
capture main --dry-run
check_contains 'Sunshine without a package manager is left to the user' \
    'leave Sunshine to you' "$text"
check_lacks 'no invented command is printed' 'pacman -S' "$text"

reset_world
make_checkout "$IVM_INSTALL_DIR"
_ipad_present() { return 1; }
capture main --dry-run
check_contains 'an unplugged iPad skips the network' \
    'skip the USB network: no iPad plugged in yet' "$text"

reset_world
make_checkout "$IVM_INSTALL_DIR"
_compositor_reachable() { return 1; }
capture main --dry-run
check_contains 'a missing compositor skips the host step' 'skip the streaming host' "$text"

# --- applying ---------------------------------------------------------------

reset_world
capture main --yes
check 'an apply run exits zero' 0 "$status"
check 'it clones the repository' 1 "$(count_calls 'git clone')"
check 'and links the command' 'yes' "$([[ -L $IVM_INSTALL_BIN/ivm ]] && printf yes || printf no)"
check 'towards the checkout' "$IVM_INSTALL_DIR/bin/ivm" "$(readlink "$IVM_INSTALL_BIN/ivm")"
check 'it builds the stack' 1 "$(count_calls 'ivm deps build --yes')"
check 'it sets up the network' 1 "$(count_calls 'ivm net up --yes')"
check 'it prepares the host' 1 "$(count_calls 'ivm up')"
check 'and reports health' 1 "$(count_calls 'ivm doctor')"
check_contains 'the summary is shown' 'Summary' "$text"

# The order matters: the stack before the network, the network before the host.
clone_line=$(awk '/git clone/ { print NR; exit }' "$STUB_LOG")
stack_line=$(awk '/ivm deps build/ { print NR; exit }' "$STUB_LOG")
net_line=$(awk '/ivm net up/ { print NR; exit }' "$STUB_LOG")
up_line=$(awk '/:: ivm up$/ { print NR; exit }' "$STUB_LOG")
check 'the repository comes before the stack' 'yes' "$([[ ${clone_line:-0} -lt ${stack_line:-0} ]] && printf yes || printf no)"
check 'the stack comes before the network' 'yes' "$([[ ${stack_line:-0} -lt ${net_line:-0} ]] && printf yes || printf no)"
check 'the network comes before the host' 'yes' "$([[ ${net_line:-0} -lt ${up_line:-0} ]] && printf yes || printf no)"

# The hook records the path it was called with, so `up` must go through the
# link rather than through the checkout.
check 'the host is prepared through the stable link' \
    1 "$(count_calls "$IVM_INSTALL_BIN/ivm :: ivm up")"

# A second run must be boring: no second clone, no rebuild.
: >"$STUB_LOG"
capture main --yes
check 'a second run exits zero' 0 "$status"
check 'it does not clone again' 0 "$(count_calls 'git clone')"
check 'nor rebuild a complete stack' 0 "$(count_calls 'ivm deps build')"
check 'it leaves the link alone' "$IVM_INSTALL_DIR/bin/ivm" "$(readlink "$IVM_INSTALL_BIN/ivm")"

# --- refusals ---------------------------------------------------------------

reset_world
capture main
check 'without a terminal it changes nothing' 0 "$status"
check_contains 'and says so' 'Nothing was changed' "$text"
check 'no clone without confirmation' 0 "$(count_calls 'git clone')"

reset_world
printf 'not ours\n' >"$IVM_INSTALL_BIN/ivm"
capture main --yes
check 'a foreign file is never overwritten' 1 "$status"
check_contains 'and is named' "$IVM_INSTALL_BIN/ivm exists and is not a link" "$text"
check 'the file survives' 'not ours' "$(<"$IVM_INSTALL_BIN/ivm")"

reset_world
mkdir -p "$IVM_INSTALL_DIR"
printf 'someone else\n' >"$IVM_INSTALL_DIR/README"
capture main --yes
check 'a directory that is not a checkout is refused' 1 "$status"
check_contains 'and is explained' 'exists but is not a git checkout' "$text"

if command -v unshare >/dev/null 2>&1; then
    reset_world
    unshare -r "$IVM_ROOT/install.sh" --dry-run >"$output" 2>&1
    status=$?
    text=$(<"$output")
    check 'running as root is refused' 2 "$status"
    check_contains 'with the reason' 'do not run this as root' "$text"
else
    printf '  skip root refusal (unshare is not available)\n'
fi

printf '\n%d checks, %d failures\n' "$checks" "$failures"
((failures == 0))
