# shellcheck shell=bash
#
# Layer 4: the streaming host.
#
# Two things are read here: the configuration (what Sunshine intends to capture)
# and the process (whether a session is actually running). The session state is
# taken from Sunshine's own threads, because the log does not reliably report a
# disconnect: a client that crashes or loses the network leaves no line at all.

IVM_SUNSHINE_PORTS_TCP='47984 47989 48010'
IVM_SUNSHINE_PORTS_UDP='47998 47999 48000'

# The systemd user unit that runs Sunshine, whatever it is called on this
# distribution; the package name varies between builds.
sunshine_unit() {
    local name
    name=$(systemctl --user list-unit-files --no-legend '*unshine*.service' 2>/dev/null |
        awk '$2 != "alias" { print $1; exit }')
    [[ -n $name ]] || return 1
    printf '%s' "$name"
}

sunshine_active() {
    systemctl --user is-active --quiet "$(sunshine_unit)" 2>/dev/null
}

sunshine_pid() {
    local pid
    pid=$(pgrep -x sunshine 2>/dev/null | awk 'NR == 1 { print }')
    [[ -n $pid ]] || return 1
    printf '%s' "$pid"
}

sunshine_conf_path() {
    printf '%s' "${IVM_SUNSHINE_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunshine.conf}"
}

sunshine_log_path() {
    printf '%s' "${IVM_SUNSHINE_LOG:-${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunshine.log}"
}

# Value of a key in sunshine.conf, or empty. The file is INI-like with
# `key = value` lines and no sections.
sunshine_conf_get() {
    local key=$1 file
    file=$(sunshine_conf_path)
    [[ -r $file ]] || return 1
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" | tail -1
}

# Threads that only exist while a stream is running.
sunshine_session_threads() {
    local pid file comm
    pid=$(sunshine_pid) || return 1
    for file in /proc/"$pid"/task/*/comm; do
        [[ -r $file ]] || continue
        read -r comm <"$file" || continue
        case $comm in
            session::*|video::capture|audio::*) printf '%s\n' "$comm" ;;
        esac
    done
}

# True while a client is streaming. The video threads are the signal; audio
# alone is not enough, because the audio thread can outlive a video session.
sunshine_session_active() {
    local threads
    threads=$(sunshine_session_threads) || return 1
    grep -qE 'session::video|video::capture' <<<"$threads"
}

# Encoders Sunshine found during its last probe, as `name [type]` lines.
sunshine_encoders() {
    local log
    log=$(sunshine_log_path)
    [[ -r $log ]] || return 1
    grep -a -o 'Found [A-Za-z0-9.]* encoder: [a-z0-9_]* \[[a-z]*\]' "$log" 2>/dev/null | tail -6
}

# Address a port is listening on, or empty when closed.
sunshine_port_address() {
    local port=$1
    ss -lntu 2>/dev/null |
        awk -v p=":$port" '$5 ~ p"$" { split($5, a, ":"); print a[1]; exit }'
}

# True when the capture backend is the one that can see virtual outputs.
sunshine_capture_is_wlr() {
    [[ $(sunshine_conf_get capture) == wlr ]]
}

# The name of the monitor Sunshine was told to capture, or empty.
sunshine_output_name() {
    sunshine_conf_get output_name
}

# The configured prep hook, or empty.
sunshine_prep_command() {
    sunshine_conf_get global_prep_cmd
}

# True when Sunshine logged that it enumerated a monitor with this name. This is
# the line that actually proves the capture target was found.
sunshine_logged_monitor() {
    local name=$1 log
    log=$(sunshine_log_path)
    [[ -r $log ]] || return 1
    grep -a -q "Monitor [0-9]* is ${name}" "$log" 2>/dev/null
}
