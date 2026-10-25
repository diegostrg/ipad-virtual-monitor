# shellcheck shell=bash
#
# `ivm deps` — the Apple USB stack: inspect it, or build it from source.
#
# The distribution package cannot switch the iPad's USB mode: the feature was
# added upstream after the last release, in 2022, and no release has been cut
# since. So a capable usbmuxd has to be built from git, together with the
# libraries it links against.
#
# `status` reads. `build` derives a plan, prints every command, asks once, and
# only then runs it — the same contract as `ivm net up`.

IVM_DEPS_PREFIX=${IVM_DEPS_PREFIX:-/usr/local}
IVM_DEPS_DIR=${IVM_DEPS_DIR:-$HOME/src/ivm-deps}
IVM_DEPS_DROPIN=${IVM_DEPS_DROPIN:-/etc/systemd/system/usbmuxd.service.d/ncm.conf}
IVM_OS_RELEASE=${IVM_OS_RELEASE:-/etc/os-release}

IVM_DEPS_APPLY=0
IVM_DEPS_YES=0
IVM_DEPS_DRY_RUN=0
IVM_DEPS_FORCE=0
IVM_DEPS_STEPS=0
IVM_DEPS_DONE=0
IVM_DEPS_FAILED=0

_deps_usage() {
    cat <<'EOF'
Usage:
  ivm deps status [--verbose]   Inspect the Apple USB stack, read-only
  ivm deps build [options]      Build and install it from source

Options for build:
  --dry-run     Print every command without running anything
  --yes         Apply without asking (for scripts)
  --force       Rebuild even when the stack already looks complete

The distribution package cannot switch the iPad's USB mode, so a capable
usbmuxd has to be built from upstream. `build` clones the six projects into
IVM_DEPS_DIR (default ~/src/ivm-deps), builds them in the documented order into
IVM_DEPS_PREFIX (default /usr/local), writes the systemd drop-in for mode 3 and
restarts the daemon. Every command is printed, and they are run only after one
confirmation. The network is needed for the clones.

`status` never changes anything and needs no root.
EOF
}

ivm_deps() {
    local sub=${1:-status}
    if (($#)); then shift; fi

    case $sub in
        status) _deps_status "$@" ;;
        build) _deps_build "$@" ;;
        help|-h|--help) _deps_usage ;;
        *)
            ivm_error "deps: unknown subcommand: $sub"
            _deps_usage >&2
            return "$IVM_EXIT_USAGE"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# The stack
# ---------------------------------------------------------------------------

# One line per library: the project name and its pkg-config module. usbmuxd is
# not here because it has no module; it is checked through its binary.
_deps_libraries() {
    cat <<'EOF'
libplist libplist-2.0
libimobiledevice-glue libimobiledevice-glue-1.0
libusbmuxd libusbmuxd-2.0
libtatsu libtatsu-1.0
libimobiledevice libimobiledevice-1.0
EOF
}

# The six projects, in build order.
_deps_names() {
    printf '%s\n' libplist libimobiledevice-glue libusbmuxd libtatsu libimobiledevice usbmuxd
}

_deps_url() {
    case $1 in
        libplist) printf 'https://github.com/libimobiledevice/libplist.git' ;;
        libimobiledevice-glue) printf 'https://github.com/libimobiledevice/libimobiledevice-glue.git' ;;
        libusbmuxd) printf 'https://github.com/libimobiledevice/libusbmuxd.git' ;;
        libtatsu) printf 'https://github.com/libimobiledevice/libtatsu.git' ;;
        libimobiledevice) printf 'https://github.com/libimobiledevice/libimobiledevice.git' ;;
        usbmuxd) printf 'https://github.com/libimobiledevice/usbmuxd.git' ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Inspection
# ---------------------------------------------------------------------------

# The .pc file our install owns. Asking pkg-config alone is not enough: it falls
# back to the system search path, so it would happily report a distribution
# library as if it were ours.
_deps_pc_file() {
    local module=$1 dir
    for dir in "$IVM_DEPS_PREFIX/lib/pkgconfig" "$IVM_DEPS_PREFIX/lib64/pkgconfig"; do
        if [[ -r $dir/$module.pc ]]; then
            printf '%s' "$dir/$module.pc"
            return 0
        fi
    done
    return 1
}

_deps_module_version() {
    local file
    file=$(_deps_pc_file "$1") || return 1
    awk -F': *' '$1 == "Version" { print $2; exit }' "$file"
}

# The daemon under the configured prefix wins, because that is the one the
# drop-in runs. Falling back to the discovered one keeps the report useful on a
# machine where nothing is built yet.
_deps_binary() {
    local candidate=$IVM_DEPS_PREFIX/sbin/usbmuxd
    if [[ -x $candidate ]]; then
        printf '%s' "$candidate"
        return 0
    fi
    usbmuxd_binary
}

_deps_supports_mode() {
    local binary matches
    binary=$(_deps_binary) || return 1
    [[ -r $binary ]] || return 1
    matches=$(strings "$binary" 2>/dev/null | grep -c 'USBMUXD_DEFAULT_DEVICE_MODE' || true)
    ((matches > 0))
}

_deps_toolchain_missing() {
    local tool missing=''
    for tool in git make cc pkg-config autoconf automake libtoolize sudo systemctl; do
        have "$tool" || missing+=" $tool"
    done
    printf '%s' "${missing# }"
}

_deps_headers_missing() {
    local module missing=''
    for module in libusb-1.0 openssl libcurl libudev; do
        pkg-config --exists "$module" 2>/dev/null || missing+=" $module"
    done
    printf '%s' "${missing# }"
}

_deps_dropin_content() {
    printf '[Service]\n'
    printf 'Environment=USBMUXD_DEFAULT_DEVICE_MODE=3\n'
    printf 'ExecStart=\n'
    printf 'ExecStart=%s/sbin/usbmuxd --user usbmux --systemd\n' "$IVM_DEPS_PREFIX"
}

_deps_dropin_matches() {
    [[ -r $IVM_DEPS_DROPIN ]] || return 1
    [[ $(<"$IVM_DEPS_DROPIN") == "$(_deps_dropin_content)" ]]
}

# The effective unit, not the file: an override elsewhere is still visible.
_deps_service_matches() {
    local exec env
    exec=$(systemctl show -p ExecStart --value usbmuxd 2>/dev/null || true)
    [[ $exec == *"$IVM_DEPS_PREFIX/sbin/usbmuxd"* ]] || return 1
    env=$(usbmuxd_environment || true)
    [[ $env == *USBMUXD_DEFAULT_DEVICE_MODE=3* ]] || return 1
    return 0
}

# True when the stack is complete enough that a build would change nothing.
_deps_ready() {
    local name module
    while read -r name module; do
        [[ -n $(_deps_module_version "$module") ]] || return 1
    done < <(_deps_libraries)
    _deps_supports_mode || return 1
    _deps_service_matches || return 1
    return 0
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

_deps_status() {
    local arg
    for arg in "$@"; do
        case $arg in
            --verbose|-v) IVM_VERBOSE=1 ;;
            -h|--help) _deps_usage; return "$IVM_EXIT_OK" ;;
            *) ivm_error "deps status: unknown argument: $arg"; return "$IVM_EXIT_USAGE" ;;
        esac
    done

    printf '%sivm deps status%s %s\n' "$IVM_C_BOLD" "$IVM_C_RESET" "$IVM_VERSION"
    printf '  %-9s %s\n' 'prefix' "$IVM_DEPS_PREFIX"
    printf '  %-9s %s\n' 'sources' "$IVM_DEPS_DIR"

    _deps_status_toolchain
    _deps_status_libraries
    _deps_status_daemon
    _deps_status_service

    local rc=0
    _deps_status_result || rc=$?
    return "$rc"
}

_deps_status_toolchain() {
    ivm_section 'Toolchain'

    local missing
    missing=$(_deps_toolchain_missing)
    if [[ -z $missing ]]; then
        ivm_ok 'git, make, a C compiler, autoconf, automake, libtoolize, pkg-config'
        ivm_ok 'sudo and systemctl, for the installation and the service'
    else
        ivm_fail "missing build tools: $missing"
        ivm_detail 'they are only needed to build, not to run'
    fi

    if have pkg-config; then
        local headers
        headers=$(_deps_headers_missing)
        if [[ -z $headers ]]; then
            ivm_ok 'development headers: libusb, openssl, libcurl, libudev'
        else
            ivm_fail "missing development headers: $headers"
            ivm_detail 'install the -dev or -devel package for each one'
        fi
    else
        ivm_warn 'pkg-config is missing, so the headers cannot be checked'
    fi

    local hint
    hint=$(_deps_install_hint)
    if [[ -n $hint ]]; then
        ivm_detail "on this distribution: $hint"
    fi
}

# Only an Arch-based command is generated: it is the one this project is
# verified on. Everywhere else the package names are in docs/dependencies.md,
# which is more reliable than a guess in code.
_deps_install_hint() {
    local id='' like=''
    [[ -r $IVM_OS_RELEASE ]] || return 1
    id=$(grep -m1 '^ID=' "$IVM_OS_RELEASE" | cut -d= -f2- | tr -d '"')
    like=$(grep -m1 '^ID_LIKE=' "$IVM_OS_RELEASE" | cut -d= -f2- | tr -d '"')
    case "$id $like" in
        *arch*|*cachyos*)
            printf 'sudo pacman -S --needed base-devel git libusb openssl curl systemd-libs'
            ;;
        *) return 1 ;;
    esac
}

_deps_status_libraries() {
    ivm_section "Libraries in $IVM_DEPS_PREFIX"

    local name module version
    while read -r name module; do
        if version=$(_deps_module_version "$module"); then
            ivm_ok "$name $version"
        else
            ivm_fail "$name is not installed there"
            ivm_detail "expected: $IVM_DEPS_PREFIX/lib/pkgconfig/$module.pc"
        fi
    done < <(_deps_libraries)
}

_deps_status_daemon() {
    ivm_section 'Daemon'

    local binary
    if ! binary=$(_deps_binary); then
        ivm_fail 'usbmuxd is not installed'
        ivm_detail 'build it with: ivm deps build'
        return 0
    fi
    ivm_detail "binary: $binary"

    if _deps_supports_mode; then
        ivm_ok "$binary supports USB device mode 3"
    else
        ivm_fail "$binary cannot request USB device mode 3"
        ivm_detail 'it predates the mode switch; the distribution package always does'
        ivm_detail 'build a capable one with: ivm deps build'
    fi

    if usbmuxd_active; then
        ivm_ok 'the daemon is running'
    else
        ivm_warn 'the daemon is not running'
        ivm_detail 'start it with: sudo systemctl start usbmuxd'
    fi
}

_deps_status_service() {
    ivm_section 'Service'

    local exec
    exec=$(systemctl show -p ExecStart --value usbmuxd 2>/dev/null || true)
    if [[ -z $exec ]]; then
        ivm_warn 'systemd does not know the usbmuxd unit'
        ivm_detail 'this project expects the distribution unit to exist'
        return 0
    fi
    ivm_detail "ExecStart: $exec"

    if [[ $exec == *"$IVM_DEPS_PREFIX/sbin/usbmuxd"* ]]; then
        ivm_ok "it runs the binary in $IVM_DEPS_PREFIX"
    else
        ivm_fail "it does not run $IVM_DEPS_PREFIX/sbin/usbmuxd"
        ivm_detail 'a systemd drop-in is what points it there; see docs/dependencies.md'
        ivm_detail 'fix it with: ivm deps build'
    fi

    local env
    env=$(usbmuxd_environment || true)
    if [[ $env == *USBMUXD_DEFAULT_DEVICE_MODE=3* ]]; then
        ivm_ok 'the service environment asks for mode 3'
    else
        ivm_fail 'the service does not set USBMUXD_DEFAULT_DEVICE_MODE=3'
        ivm_detail 'without it the iPad never exposes its network interface'
        ivm_detail 'fix it with: ivm deps build'
    fi
}

_deps_status_result() {
    printf '\n'
    if _deps_ready; then
        printf 'The stack is ready. Nothing to build.\n'
        return "$IVM_EXIT_OK"
    fi
    if ((IVM_COUNT_FAIL)); then
        printf 'The stack is incomplete. Build it with: ivm deps build\n'
        return "$IVM_EXIT_PROBLEMS"
    fi
    printf 'Usable, but the warnings above are worth fixing.\n'
    return "$IVM_EXIT_OK"
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

_deps_quote() {
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

_deps_jobs() {
    local jobs
    jobs=$(nproc 2>/dev/null) || jobs=1
    [[ $jobs =~ ^[0-9]+$ ]] && ((jobs > 0)) || jobs=1
    printf '%s' "$jobs"
}

# One command, printed as a plan or announced and run.
_deps_step() {
    local description=$1
    shift
    IVM_DEPS_STEPS=$((IVM_DEPS_STEPS + 1))

    if ((IVM_DEPS_APPLY)); then
        printf '  %srun %s %s\n' "$IVM_C_DIM" "$IVM_C_RESET" "$(_deps_quote "$@")"
        if "$@"; then
            IVM_DEPS_DONE=$((IVM_DEPS_DONE + 1))
            ivm_ok "$description"
        else
            IVM_DEPS_FAILED=$((IVM_DEPS_FAILED + 1))
            ivm_fail "$description"
            return 1
        fi
    else
        printf '  %splan%s %s\n' "$IVM_C_YELLOW" "$IVM_C_RESET" "$(_deps_quote "$@")"
    fi
    return 0
}

# Same, inside a project directory. The `cd` is part of what is shown, because
# it is part of what runs.
_deps_step_in_dir() {
    local dir=$1 description=$2
    shift 2
    IVM_DEPS_STEPS=$((IVM_DEPS_STEPS + 1))
    local shown="cd $(_deps_quote "$dir") && $(_deps_quote "$@")"

    if ((IVM_DEPS_APPLY)); then
        printf '  %srun %s %s\n' "$IVM_C_DIM" "$IVM_C_RESET" "$shown"
        if ( cd "$dir" && "$@" ); then
            IVM_DEPS_DONE=$((IVM_DEPS_DONE + 1))
            ivm_ok "$description"
        else
            IVM_DEPS_FAILED=$((IVM_DEPS_FAILED + 1))
            ivm_fail "$description"
            return 1
        fi
    else
        printf '  %splan%s %s\n' "$IVM_C_YELLOW" "$IVM_C_RESET" "$shown"
    fi
    return 0
}

# A root-owned configuration file, shown as its lines plus the command that
# writes them.
_deps_file_step() {
    local destination=$1 content=$2 description=$3 line
    IVM_DEPS_STEPS=$((IVM_DEPS_STEPS + 1))

    if ((IVM_DEPS_APPLY)); then
        printf '  %srun %s %s\n' "$IVM_C_DIM" "$IVM_C_RESET" "$(_deps_quote sudo tee "$destination")"
        if printf '%s\n' "$content" | sudo tee "$destination" >/dev/null; then
            IVM_DEPS_DONE=$((IVM_DEPS_DONE + 1))
            ivm_ok "$description"
        else
            IVM_DEPS_FAILED=$((IVM_DEPS_FAILED + 1))
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

_deps_confirm() {
    local count=$1 answer=''
    if ((IVM_DEPS_YES)); then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        ivm_info 'not a terminal, so nothing was changed'
        ivm_detail 'repeat with --yes to apply the plan'
        return 1
    fi
    printf '\nApply %d command(s)? The installations and systemd steps use sudo. [y/N] ' "$count"
    read -r answer || answer=''
    case $answer in
        y|Y|yes|YES|si|sí|s|S) return 0 ;;
        *) return 1 ;;
    esac
}

# The six names to build, in order. One missing library means the stack would
# end up mixed, so the whole chain is rebuilt; otherwise only the daemon is
# rebuilt when it cannot switch modes.
_deps_build_list() {
    if ((IVM_DEPS_FORCE)); then
        _deps_names
        return 0
    fi

    local name module missing=0
    while read -r name module; do
        [[ -n $(_deps_module_version "$module") ]] || missing=1
    done < <(_deps_libraries)

    if ((missing)); then
        _deps_names
        return 0
    fi
    if ! _deps_supports_mode; then
        printf 'usbmuxd\n'
    fi
    return 0
}

_deps_build() {
    local arg
    IVM_DEPS_APPLY=0
    IVM_DEPS_YES=0
    IVM_DEPS_DRY_RUN=0
    IVM_DEPS_FORCE=0
    IVM_DEPS_STEPS=0
    IVM_DEPS_DONE=0
    IVM_DEPS_FAILED=0

    for arg in "$@"; do
        case $arg in
            --yes|-y) IVM_DEPS_YES=1 ;;
            --dry-run) IVM_DEPS_DRY_RUN=1 ;;
            --force) IVM_DEPS_FORCE=1 ;;
            --verbose|-v) IVM_VERBOSE=1 ;;
            -h|--help) _deps_usage; return "$IVM_EXIT_OK" ;;
            *) ivm_error "deps build: unknown argument: $arg"; return "$IVM_EXIT_USAGE" ;;
        esac
    done

    printf '%sivm deps build%s\n' "$IVM_C_BOLD" "$IVM_C_RESET"
    printf '  %-9s %s\n' 'prefix' "$IVM_DEPS_PREFIX"
    printf '  %-9s %s\n' 'sources' "$IVM_DEPS_DIR"

    local missing headers
    missing=$(_deps_toolchain_missing)
    if [[ -n $missing ]]; then
        ivm_fail "missing build tools: $missing"
        headers=$(_deps_install_hint)
        [[ -n $headers ]] && ivm_detail "install them with: $headers"
        ivm_detail 'see docs/dependencies.md for the package names on other distributions'
        return "$IVM_EXIT_PROBLEMS"
    fi
    if have pkg-config; then
        missing=$(_deps_headers_missing)
        if [[ -n $missing ]]; then
            ivm_fail "missing development headers: $missing"
            headers=$(_deps_install_hint)
            [[ -n $headers ]] && ivm_detail "install them with: $headers"
            ivm_detail 'see docs/dependencies.md for the package names on other distributions'
            return "$IVM_EXIT_PROBLEMS"
        fi
    fi

    local list dropin=0 service=0
    list=$(_deps_build_list)
    _deps_dropin_matches || dropin=1
    _deps_service_matches || service=1

    if [[ -z $list ]] && ((dropin == 0)) && ((service == 0)); then
        ivm_ok 'nothing to build: the stack is already in place'
        ivm_detail 'use --force to rebuild it anyway'
        return "$IVM_EXIT_OK"
    fi

    _deps_plan "$list" "$dropin" "$service" || return "$IVM_EXIT_PROBLEMS"

    if ((IVM_DEPS_DRY_RUN)); then
        printf '\n%d command(s) shown; nothing was run\n' "$IVM_DEPS_STEPS"
        return "$IVM_EXIT_OK"
    fi

    if ! _deps_confirm "$IVM_DEPS_STEPS"; then
        printf 'Nothing was changed.\n'
        return "$IVM_EXIT_OK"
    fi

    # The plan was derived from the current state; it is the same list that
    # runs, so what was shown is what happens.
    IVM_DEPS_APPLY=1
    IVM_DEPS_STEPS=0
    printf '\n'
    if ! _deps_plan "$list" "$dropin" "$service"; then
        printf '\nStopped at the first failure; the stack may be half built.\n'
        printf 'Fix the cause and run `ivm deps build` again: it continues from here.\n'
        return "$IVM_EXIT_PROBLEMS"
    fi

    printf '\nResult\n'
    if _deps_ready; then
        ivm_ok 'the stack is ready'
        ivm_detail 'if the iPad was connected, unplug and replug it once'
    else
        ivm_fail 'the stack is not in the expected state yet'
        ivm_detail 'run: ivm deps status'
        return "$IVM_EXIT_PROBLEMS"
    fi
    return "$IVM_EXIT_OK"
}

_deps_plan() {
    local list=$1 dropin=$2 service=$3 name

    if [[ -n $list ]]; then
        _deps_step "created $IVM_DEPS_DIR" mkdir -p "$IVM_DEPS_DIR" || return 1
        for name in $list; do
            _deps_build_component "$name" || return 1
        done
        _deps_step 'updated the linker cache' sudo ldconfig || return 1
    fi

    if ((dropin)); then
        _deps_step "created $(dirname "$IVM_DEPS_DROPIN")" \
            sudo mkdir -p "$(dirname "$IVM_DEPS_DROPIN")" || return 1
        _deps_file_step "$IVM_DEPS_DROPIN" "$(_deps_dropin_content)" \
            "wrote the drop-in that requests USB device mode 3" || return 1
    fi

    if ((dropin)) || ((service)) || [[ -n $list ]]; then
        if ! ((IVM_DEPS_APPLY)); then
            printf '  %snote%s restarting usbmuxd re-enumerates the iPad; an active stream drops\n' \
                "$IVM_C_DIM" "$IVM_C_RESET"
        fi
        _deps_step 'reloaded systemd' sudo systemctl daemon-reload || return 1
        _deps_step 'restarted usbmuxd' sudo systemctl restart usbmuxd || return 1
    fi
    return 0
}

_deps_build_component() {
    local name=$1 url dir
    url=$(_deps_url "$name")
    dir=$IVM_DEPS_DIR/$name

    if [[ -d $dir/.git ]]; then
        _deps_step_in_dir "$dir" "updated $name" git pull --ff-only || return 1
    elif [[ -e $dir ]]; then
        ivm_fail "$dir exists but is not a git checkout"
        ivm_detail 'move it away, or set IVM_DEPS_DIR to another directory'
        return 1
    else
        _deps_step "cloned $name" git clone --depth 1 "$url" "$dir" || return 1
    fi

    local -a flags=(--prefix="$IVM_DEPS_PREFIX")
    # usbmuxd needs its state directories spelled out; the libraries do not.
    if [[ $name == usbmuxd ]]; then
        flags+=(--sysconfdir=/etc --localstatedir=/var --runstatedir=/run)
    fi
    _deps_step_in_dir "$dir" "configured $name" \
        env PKG_CONFIG_PATH="$IVM_DEPS_PREFIX/lib/pkgconfig" ./autogen.sh "${flags[@]}" || return 1
    _deps_step_in_dir "$dir" "built $name" make -j "$(_deps_jobs)" || return 1
    _deps_step_in_dir "$dir" "installed $name" sudo make install || return 1
    return 0
}
