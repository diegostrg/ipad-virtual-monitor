#!/usr/bin/env bash
#
# The one-command installer.
#
#   curl -fsSL https://raw.githubusercontent.com/diegostrg/ipad-virtual-monitor/main/install.sh | bash
#
# It runs as your user, never as root: the steps that need root call `sudo` one
# command at a time. It prints what it is going to do and asks once, and running
# it again is harmless.
#
# When the script arrives through a pipe, stdin *is* the script, so every prompt
# is read from /dev/tty instead. That is why the questions work either way.
#
# This file is deliberately self-contained: it must work before the repository
# exists, so it cannot source the libraries. Once they are on disk, everything
# else is delegated to `ivm`, which is the single implementation.

set -euo pipefail

IVM_REPO_URL=${IVM_REPO_URL:-https://github.com/diegostrg/ipad-virtual-monitor.git}
IVM_INSTALL_DIR=${IVM_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ipad-virtual-monitor}
IVM_INSTALL_BIN=${IVM_INSTALL_BIN:-$HOME/.local/bin}

IVM_INSTALL_APPLY=0
IVM_INSTALL_YES=0
IVM_INSTALL_DRY_RUN=0

if [[ -t 1 ]]; then
    C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m' C_RED=$'\033[31m' C_RESET=$'\033[0m'
else
    C_BOLD='' C_DIM='' C_GREEN='' C_YELLOW='' C_RED='' C_RESET=''
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

_title() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }
_ok() { printf '  %sok%s   %s\n' "$C_GREEN" "$C_RESET" "$1"; }
_warn() { printf '  %swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
_fail() { printf '  %sfail%s %s\n' "$C_RED" "$C_RESET" "$1"; }
_detail() { printf '       %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }
_plan() { printf '  %splan%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
_note() { printf '  %snote%s %s\n' "$C_DIM" "$C_RESET" "$1"; }

_usage() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  --dry-run     Show what would happen and change nothing
  --yes         Do not ask for confirmation (for scripts)
  --dir PATH    Where the repository goes (default ~/.local/share/ipad-virtual-monitor)
  -h, --help    This text

Run it as your user, not with sudo. The steps that need root use sudo on their
own, one command at a time. Running it twice is harmless: it skips what is
already done.

Environment:
  IVM_INSTALL_DIR   Same as --dir
  IVM_INSTALL_BIN   Where the `ivm` command is linked (default ~/.local/bin)
  IVM_REPO_URL      Repository to clone (defaults to the project's GitHub)
  IVM_DEPS_DIR      Passed to `ivm deps build` when the stack needs compiling
EOF
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

_have() { command -v "$1" >/dev/null 2>&1; }

# The directory this script lives in, when it was not piped. Empty otherwise.
_script_dir() {
    local source=${BASH_SOURCE[0]:-}
    [[ -n $source && -f $source ]] || return 1
    ( cd -- "$(dirname -- "$source")" && pwd )
}

# A terminal we can actually talk to. `[[ -r /dev/tty ]]` only looks at the
# permission bits: with no controlling terminal the device exists and the write
# still fails, so the check has to open it.
_has_tty() {
    { : >/dev/tty; } 2>/dev/null
}

# Yes or no, read from the terminal. Under `curl | bash` stdin is the script
# itself, so reading from there would consume the code instead of an answer.
_ask() {
    local prompt=$1 answer=''
    if ! _has_tty; then
        return 1
    fi
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r answer </dev/tty || answer=''
    case $answer in
        y|Y|yes|YES|s|S|si|sí) return 0 ;;
        *) return 1 ;;
    esac
}

# An Arch-based system is the verified target, but it is not a hard requirement:
# everything the stack needs is checked afterwards, and the docs cover the rest.
_os_is_arch() {
    local file=${IVM_OS_RELEASE:-/etc/os-release} id='' like=''
    [[ -r $file ]] || return 1
    id=$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' "$file")
    like=$(awk -F= '$1 == "ID_LIKE" { gsub(/"/, "", $2); print $2 }' "$file")
    case "$id $like" in
        *arch*|*cachyos*) return 0 ;;
        *) return 1 ;;
    esac
}

_compositor_reachable() {
    if ! _have hyprctl; then
        return 1
    fi
    hyprctl version >/dev/null 2>&1
}

# Is an Apple device on the bus? The vendor id is what usbmuxd keys on, and a
# device that is not there cannot be given an address.
_ipad_present() {
    local file
    for file in /sys/bus/usb/devices/*/idVendor; do
        [[ -r $file ]] || continue
        if [[ $(<"$file") == 05ac ]]; then
            return 0
        fi
    done
    return 1
}

# Sunshine is installed in several ways (distribution package, AUR, Flatpak), so
# the test is the unit it ships, not the binary path.
_sunshine_present() {
    local units
    if _have sunshine; then
        return 0
    fi
    units=$(systemctl --user list-unit-files --no-legend '*unshine*.service' 2>/dev/null |
        grep -c . || true)
    ((units > 0))
}

# How Sunshine could be installed here, in the order that avoids building from
# source. Prints the command, or nothing when there is no good answer.
_sunshine_command() {
    if _have pacman && pacman -Si sunshine >/dev/null 2>&1; then
        printf 'sudo pacman -S --needed sunshine'
        return 0
    fi
    if _have paru; then
        printf 'paru -S --needed sunshine'
        return 0
    fi
    if _have yay; then
        printf 'yay -S --needed sunshine'
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Where everything lives
# ---------------------------------------------------------------------------

# A checkout next to this script wins, so `bash install.sh` from a clone uses
# that clone instead of downloading a second copy.
_repo_dir() {
    local here
    if here=$(_script_dir) && [[ -x $here/bin/ivm ]]; then
        printf '%s' "$here"
        return 0
    fi
    printf '%s' "$IVM_INSTALL_DIR"
}

_repo_is_local() {
    local here
    here=$(_script_dir) 2>/dev/null || return 1
    [[ -x $here/bin/ivm && $here != "$IVM_INSTALL_DIR" ]]
}

# `ivm up` records the path it was called with, and the supervisor unit points
# at ~/.local/bin/ivm, so the link is the stable name to call it by.
_ivm() {
    local repo=$1
    if [[ -L $IVM_INSTALL_BIN/ivm ]] &&
        [[ $(readlink -f "$IVM_INSTALL_BIN/ivm") == "$(readlink -f "$repo/bin/ivm")" ]]; then
        printf '%s' "$IVM_INSTALL_BIN/ivm"
    else
        printf '%s' "$repo/bin/ivm"
    fi
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

_install_repo() {
    local repo=$1
    if [[ -x $repo/bin/ivm ]]; then
        _ok "repository in place: $repo"
        return 0
    fi

    if [[ -d $repo/.git ]]; then
        printf '  %srun %s git -C %s pull --ff-only\n' "$C_DIM" "$C_RESET" "$repo"
        if git -C "$repo" pull --ff-only; then
            _ok "updated $repo"
            return 0
        fi
        _fail "could not update $repo"
        _detail 'move it away and run this again to start from a clean copy'
        return 1
    fi

    if [[ -e $repo ]]; then
        _fail "$repo exists but is not a git checkout"
        _detail 'move it away, or pass --dir with another location'
        return 1
    fi

    printf '  %srun %s git clone --depth 1 %s %s\n' "$C_DIM" "$C_RESET" "$IVM_REPO_URL" "$repo"
    mkdir -p "$(dirname -- "$repo")"
    if git clone --depth 1 "$IVM_REPO_URL" "$repo"; then
        _ok "downloaded into $repo"
        return 0
    fi
    _fail "could not download $IVM_REPO_URL"
    _detail 'check the network and the URL; IVM_REPO_URL overrides it'
    return 1
}

_install_link() {
    local repo=$1 target=$IVM_INSTALL_BIN/ivm

    if [[ -L $target ]]; then
        if [[ $(readlink -f "$target") == "$(readlink -f "$repo/bin/ivm")" ]]; then
            _ok "$target already points here"
            return 0
        fi
        printf '  %srun %s ln -sfn %s %s\n' "$C_DIM" "$C_RESET" "$repo/bin/ivm" "$target"
        mkdir -p "$IVM_INSTALL_BIN"
        if ln -sfn "$repo/bin/ivm" "$target"; then
            _ok "repointed $target"
            return 0
        fi
        _fail "could not write $target"
        return 1
    fi

    if [[ -e $target ]]; then
        _fail "$target exists and is not a link"
        _detail 'move it away; this installer will not overwrite a file it did not create'
        return 1
    fi

    printf '  %srun %s ln -s %s %s\n' "$C_DIM" "$C_RESET" "$repo/bin/ivm" "$target"
    mkdir -p "$IVM_INSTALL_BIN"
    if ln -s "$repo/bin/ivm" "$target"; then
        _ok "linked $target"
    else
        _fail "could not write $target"
        return 1
    fi

    case ":$PATH:" in
        *":$IVM_INSTALL_BIN:"*) ;;
        *)
            _warn "$IVM_INSTALL_BIN is not in your PATH"
            _detail "add it to your shell configuration: export PATH=\"$IVM_INSTALL_BIN:\$PATH\""
            _detail "until then, call it by its full path: $target"
            ;;
    esac
    return 0
}

_stack_ready() {
    local ivm=$1
    "$ivm" deps status >/dev/null 2>&1
}

_install_stack() {
    local ivm=$1
    if _stack_ready "$ivm"; then
        _ok 'the Apple USB stack is already built'
        return 0
    fi

    _note 'compiling takes 5 to 10 minutes and needs the network'
    _note 'usbmuxd restarts at the end, so disconnect Moonlight first'
    if ! "$ivm" deps build --yes; then
        _fail 'the Apple USB stack could not be built'
        _detail 'run `ivm deps status` to see which piece is missing'
        return 1
    fi
    return 0
}

_install_sunshine() {
    local command=$1
    _note "installing with: $command"
    # shellcheck disable=SC2086 # the command is a deliberate word list
    if $command; then
        _ok 'Sunshine installed'
        return 0
    fi
    _fail 'Sunshine could not be installed'
    _detail 'install it by hand and run this installer again'
    return 1
}

_install_network() {
    local ivm=$1
    if ! _ipad_present; then
        _warn 'no Apple device is plugged in, so the network stays as it is'
        return 0
    fi
    if ! "$ivm" net up --yes; then
        _fail 'the USB network could not be configured'
        _detail 'run `ivm net up` to see the plan and the error on its own'
        return 1
    fi
    return 0
}

_install_host() {
    local ivm=$1
    if ! _compositor_reachable; then
        _warn 'no Hyprland session is reachable from here'
        _detail 'log in to your desktop and run: ivm up'
        return 0
    fi
    if ! "$ivm" up; then
        _fail 'the streaming host could not be prepared'
        _detail 'run `ivm up` to see which step failed'
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------

_show_plan() {
    local repo=$1 sunshine=$2
    _title 'Plan'

    if _repo_is_local; then
        _plan "use this checkout: $repo"
    elif [[ -x $repo/bin/ivm ]]; then
        _plan "update the repository in $repo"
    else
        _plan "download the repository into $repo"
    fi

    if [[ -L $IVM_INSTALL_BIN/ivm ]] &&
        [[ $(readlink -f "$IVM_INSTALL_BIN/ivm") == "$(readlink -f "$repo/bin/ivm")" ]]; then
        _plan "keep the command at $IVM_INSTALL_BIN/ivm"
    else
        _plan "link the command at $IVM_INSTALL_BIN/ivm"
    fi

    if [[ -x $repo/bin/ivm ]]; then
        if _stack_ready "$repo/bin/ivm"; then
            _plan 'skip the Apple USB stack: already built'
        else
            _plan 'build the Apple USB stack (5 to 10 minutes)'
        fi
    else
        _plan 'check the Apple USB stack and build it if it is missing'
    fi

    if _sunshine_present; then
        _plan 'skip Sunshine: already installed'
    elif [[ -n $sunshine ]]; then
        _plan "install Sunshine running: $sunshine"
    else
        _plan 'leave Sunshine to you: no package or AUR helper found'
    fi

    if _ipad_present; then
        _plan 'set up the USB network, the firewall rule and the shared connection'
    else
        _plan 'skip the USB network: no iPad plugged in yet'
    fi

    if _compositor_reachable; then
        _plan 'prepare Sunshine, the prep hook and the supervisor'
    else
        _plan 'skip the streaming host: no Hyprland session reachable'
    fi

    _plan 'finish with a health report'
}

_confirm() {
    if ((IVM_INSTALL_YES)); then
        return 0
    fi
    if ! _ask '

Continue? [y/N] '; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    while (($#)); do
        case $1 in
            --dry-run) IVM_INSTALL_DRY_RUN=1; shift ;;
            --yes|-y) IVM_INSTALL_YES=1; shift ;;
            --dir)
                if (($# < 2)); then
                    _fail '--dir needs a path'
                    return 2
                fi
                IVM_INSTALL_DIR=$2
                shift 2
                ;;
            --dir=*) IVM_INSTALL_DIR=${1#--dir=}; shift ;;
            -h|--help) _usage; return 0 ;;
            *) _fail "unknown argument: $1"; _usage >&2; return 2 ;;
        esac
    done

    if ((EUID == 0)); then
        _fail 'do not run this as root'
        _detail 'run it as yourself; it calls sudo for the steps that need it'
        _detail 'that way the files it creates belong to you, not to root'
        return 2
    fi

    case $IVM_INSTALL_DIR in
        /*) ;;
        *) IVM_INSTALL_DIR=$PWD/$IVM_INSTALL_DIR ;;
    esac

    printf '%sipad-virtual-monitor%s installer\n' "$C_BOLD" "$C_RESET"

    # --- preflight, before anything is written -----------------------------
    local missing='' tool
    for tool in git; do
        _have "$tool" || missing+=" $tool"
    done
    if [[ -n $missing ]]; then
        _fail "missing:$missing"
        _detail 'install git first; on Arch: sudo pacman -S git'
        return 1
    fi
    if ! _os_is_arch; then
        _warn 'this is not an Arch-based system'
        _detail 'the installer is verified there; the manual steps are in docs/'
    fi
    if ! _compositor_reachable; then
        _warn 'no Hyprland session is reachable'
        _detail 'the repository and the stack can still be prepared now'
        _detail 'the rest waits until you log in and run `ivm up`'
    fi

    local repo sunshine=''
    repo=$(_repo_dir)

    if ! _sunshine_present; then
        sunshine=$(_sunshine_command || true)
        if [[ -z $sunshine ]]; then
            _warn 'Sunshine is not installed and no package manager or AUR helper was found'
            _detail 'install it from https://github.com/LizardByte/Sunshine or your AUR helper'
            _detail 'then run this installer again; everything else can proceed now'
        fi
    fi

    _show_plan "$repo" "$sunshine"

    if ((IVM_INSTALL_DRY_RUN)); then
        printf '\nDry run: nothing was changed, and nothing was downloaded.\n'
        if [[ ! -x $repo/bin/ivm ]]; then
            _detail 'a fresh run also inspects the stack; the details appear then'
        fi
        return 0
    fi

    if ! _confirm; then
        printf '\nNothing was changed.\n'
        return 0
    fi

    # --- apply -------------------------------------------------------------
    IVM_INSTALL_APPLY=1
    local failed=0 ivm

    _title 'Repository'
    _install_repo "$repo" || return 1
    _install_link "$repo" || failed=1
    ivm=$(_ivm "$repo")

    _title 'Apple USB stack'
    _install_stack "$ivm" || failed=1

    _title 'Sunshine'
    if _sunshine_present; then
        _ok 'Sunshine is installed'
    elif [[ -n $sunshine ]]; then
        _install_sunshine "$sunshine" || failed=1
    else
        _warn 'skipped: install it by hand, then run `ivm up`'
    fi

    _title 'USB network'
    _install_network "$ivm" || failed=1

    _title 'Streaming host'
    _install_host "$ivm" || failed=1

    # --- report ------------------------------------------------------------
    _title 'Health report'
    "$ivm" doctor || true

    printf '\n'
    if ((failed)); then
        printf 'Some steps failed. Fix the first one above and run this again;\n'
        printf 'it skips whatever is already done.\n'
        return 1
    fi

    if ! _ipad_present; then
        printf 'Almost there. Plug the iPad in with the USB-C cable and run this\n'
        printf 'installer once more: only the USB network is left.\n'
    fi
    cat <<'EOF'

Next on the iPad
  1. Install Moonlight from the App Store.
  2. Plug the USB-C cable in. The host is 10.42.0.1 if Moonlight does not
     find it on its own.
  3. Connect, and the second screen appears.

Everyday use
  ivm status    what is happening
  ivm doctor    what is broken, and how to fix it
  ivm down      remove the virtual output
EOF
    return 0
}

# Run only when executed, not when sourced. Both cases must work: through a
# pipe BASH_SOURCE is empty, and from a checkout it names this file.
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
