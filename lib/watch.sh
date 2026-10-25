# shellcheck shell=bash
#
# `ivm watch` — keep the virtual output in sync with the streaming session.
#
# Hyprland never removes the output by itself, and Sunshine does not run a
# disconnect hook: `global_undo_cmd` only runs when the whole process exits, and
# `CLIENT DISCONNECTED` is not logged when a client loses the network or is
# killed. Something has to look at the running process instead, which is what
# this loop does.
#
# A grace period is essential: reconnecting after a short interruption is
# common, and destroying the output on the first idle second would make the
# reconnect land on the laptop panel.

IVM_WATCH_INTERVAL=${IVM_WATCH_INTERVAL:-2}

# When the current idle streak started, as an epoch. A global instead of a return
# value because the function also prints to the terminal, and the two channels
# cannot share stdout.
IVM_WATCH_IDLE_SINCE=0

_IVM_WATCH_WARNED_MISSING=0
_IVM_WATCH_WAITING=0

ivm_watch() {
    local grace=$IVM_GRACE interval=$IVM_WATCH_INTERVAL once=0 arg

    while (($#)); do
        case $1 in
            --grace)
                if (($# < 2)) || ! [[ $2 =~ ^[0-9]+$ ]]; then
                    ivm_error 'watch: --grace needs a number of seconds'
                    return "$IVM_EXIT_USAGE"
                fi
                grace=$2
                shift 2
                ;;
            --interval)
                if (($# < 2)) || ! [[ $2 =~ ^[0-9]+$ ]] || (($2 < 1)); then
                    ivm_error 'watch: --interval needs a number of seconds, at least 1'
                    return "$IVM_EXIT_USAGE"
                fi
                interval=$2
                shift 2
                ;;
            --once)
                once=1
                shift
                ;;
            -h|--help)
                cat <<'EOF'
Usage: ivm watch [--grace SECONDS] [--interval SECONDS] [--once]

Follows Sunshine and removes the virtual output once no client has been
streaming for the grace period (default 20 s). A running supervisor is what
keeps the desktop clean after a disconnect.

  --grace N     Seconds to wait before removing it (0 removes immediately)
  --interval N  Seconds between checks (default 2)
  --once        Check a single time and exit, without waiting for the grace
EOF
                return "$IVM_EXIT_OK"
                ;;
            *)
                ivm_error "watch: unknown argument: $1"
                return "$IVM_EXIT_USAGE"
                ;;
        esac
    done

    ivm_config_load || return "$IVM_EXIT_PROBLEMS"

    if ((once)); then
        _watch_reconcile 0 1
        return "$IVM_EXIT_OK"
    fi

    printf '%sivm watch%s checking every %ss, grace %ss\n' \
        "$IVM_C_BOLD" "$IVM_C_RESET" "$interval" "$grace"

    trap '_watch_bye' INT TERM

    while :; do
        _watch_reconcile "$grace"
        # A background sleep that is waited on: a foreground one prints
        # "Terminado"/"Terminated" when the signal arrives during it, which would
        # land in the middle of the service log.
        sleep "$interval" &
        wait $! 2>/dev/null || true
    done
}

# One evaluation of the state.
#
# The grace period is ignored when it is zero, which is what `--once` uses:
# asking for a single check means asking for the answer now.
_watch_reconcile() {
    local grace=$1 loud=${2:-0} now

    # The compositor may be unreachable (at boot, or during a restart). Say it
    # once and keep going: the supervisor has to outlive the session, and one
    # line every two seconds would bury everything else in the journal.
    if ! hypr_env_discover; then
        if ((!_IVM_WATCH_WAITING)); then
            _watch_say 'cannot reach the compositor, waiting for it'
            _IVM_WATCH_WAITING=1
        fi
        return 0
    fi
    if ((_IVM_WATCH_WAITING)); then
        _watch_say 'the compositor is reachable again'
        _IVM_WATCH_WAITING=0
    fi

    local name
    name=$(display_name)

    if sunshine_session_active; then
        if ((IVM_WATCH_IDLE_SINCE)); then
            _watch_say 'a client is streaming again, keeping the output'
        fi
        IVM_WATCH_IDLE_SINCE=0

        # Worth saying out loud: the stream is running on some other output,
        # because Sunshine chose its capture target before this could help.
        if ! display_exists && ! ((_IVM_WATCH_WARNED_MISSING)); then
            _watch_say "a client is streaming but $name does not exist"
            _IVM_WATCH_WARNED_MISSING=1
        elif ((loud)); then
            _watch_say "a client is streaming, keeping $name"
        fi
        return 0
    fi

    _IVM_WATCH_WARNED_MISSING=0
_IVM_WATCH_WAITING=0

    if ! display_exists; then
        IVM_WATCH_IDLE_SINCE=0
        if ((loud)); then
            _watch_say "no stream and $name does not exist, nothing to do"
        fi
        return 0
    fi

    now=$(date +%s)

    if ((grace == 0)); then
        _watch_remove
        return 0
    fi

    if ((IVM_WATCH_IDLE_SINCE == 0)); then
        IVM_WATCH_IDLE_SINCE=$now
        _watch_say "no stream; removing $name in ${grace}s unless a client returns"
        return 0
    fi

    if ((now - IVM_WATCH_IDLE_SINCE < grace)); then
        return 0
    fi

    if _watch_remove; then
        IVM_WATCH_IDLE_SINCE=0
    fi
    return 0
}

_watch_remove() {
    if _display_remove >/dev/null 2>&1; then
        _watch_say "$(display_name) removed; the desktop is back to its own outputs"
        return 0
    fi
    _watch_say "could not remove $(display_name), will try again"
    return 1
}

_watch_say() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

_watch_bye() {
    _watch_say 'stopped'
    # The output is deliberately left alone: stopping the supervisor is not the
    # same as disconnecting, and the display may still be in use. `ivm display
    # remove` is the explicit way to take it down.
    trap - INT TERM
    exit 0
}
