# shellcheck shell=bash
#
# Output helpers, capability checks and exit codes shared by every command.

# One version, one place. bin/ivm does not define it, so the libraries are
# usable on their own, which is what the tests do.
IVM_VERSION='0.1.0-dev'

IVM_EXIT_OK=0
IVM_EXIT_PROBLEMS=1
IVM_EXIT_USAGE=2

IVM_COUNT_OK=0
IVM_COUNT_WARN=0
IVM_COUNT_FAIL=0

IVM_VERBOSE=${IVM_VERBOSE:-0}

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    IVM_C_RESET=$'\033[0m'
    IVM_C_DIM=$'\033[2m'
    IVM_C_RED=$'\033[31m'
    IVM_C_GREEN=$'\033[32m'
    IVM_C_YELLOW=$'\033[33m'
    IVM_C_BOLD=$'\033[1m'
else
    IVM_C_RESET=''
    IVM_C_DIM=''
    IVM_C_RED=''
    IVM_C_GREEN=''
    IVM_C_YELLOW=''
    IVM_C_BOLD=''
fi

# A check that passed.
ivm_ok() {
    IVM_COUNT_OK=$((IVM_COUNT_OK + 1))
    printf '  %sok%s   %s\n' "$IVM_C_GREEN" "$IVM_C_RESET" "$*"
}

# Something that works but is not ideal, or that cannot be verified.
ivm_warn() {
    IVM_COUNT_WARN=$((IVM_COUNT_WARN + 1))
    printf '  %swarn%s %s\n' "$IVM_C_YELLOW" "$IVM_C_RESET" "$*"
}

# Something that is broken. This is what makes doctor exit non-zero.
ivm_fail() {
    IVM_COUNT_FAIL=$((IVM_COUNT_FAIL + 1))
    printf '  %sfail%s %s\n' "$IVM_C_RED" "$IVM_C_RESET" "$*"
}

# Neutral information: nothing checked, nothing wrong.
ivm_info() {
    printf '  %s -- %s %s\n' "$IVM_C_DIM" "$IVM_C_RESET" "$*"
}

# A section heading in the report.
ivm_section() {
    printf '\n%s%s%s\n' "$IVM_C_BOLD" "$*" "$IVM_C_RESET"
}

# A line shown only with --verbose.
ivm_detail() {
    ((IVM_VERBOSE)) || return 0
    printf '       %s%s%s\n' "$IVM_C_DIM" "$*" "$IVM_C_RESET"
}

# User-facing failure: names the layer and what to do about it.
ivm_error() {
    printf 'ivm: %s\n' "$*" >&2
}

# True when the command exists.
have() {
    command -v "$1" >/dev/null 2>&1
}

# A desktop notification, for what the supervisor does while nobody is looking
# at a terminal: it restarts Sunshine behind the user's back and the next
# connection would otherwise land during the restart.
#
# A notification is a courtesy, never a dependency: without the tool, the daemon
# or the permission, this does nothing at all. The timeout matters because a
# wedged session bus would otherwise hang the supervisor's loop.
ivm_notify() {
    local title=$1 body=$2
    [[ ${IVM_NOTIFY:-yes} == yes ]] || return 0
    have notify-send || return 0
    if have timeout; then
        timeout 3 notify-send --app-name=ivm --urgency=normal --expire-time=5000 \
            "$title" "$body" >/dev/null 2>&1 || true
    else
        notify-send --app-name=ivm --urgency=normal --expire-time=5000 \
            "$title" "$body" >/dev/null 2>&1 || true
    fi
    return 0
}

# Directory for logs and other runtime files. Created on demand, because a
# read-only command must not create anything.
#
# The XDG location is used instead of a directory inside the repository: the
# tool is meant to be installed somewhere else, and a log written next to the
# code breaks as soon as that path is read-only.
ivm_state_dir() {
    local dir=${XDG_STATE_HOME:-$HOME/.local/state}/ivm
    [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null || return 1
    printf '%s' "$dir"
}

# Require a command, or fail with a message that says how to get it.
require() {
    local cmd=$1 hint=${2:-}
    if ! have "$cmd"; then
        ivm_error "required command not found: $cmd${hint:+ ($hint)}"
        return "$IVM_EXIT_PROBLEMS"
    fi
}
