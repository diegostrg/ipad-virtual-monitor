# shellcheck shell=bash
#
# Layer 3: Hyprland's outputs.
#
# `hyprctl monitors` prints human text; `monitors all` also includes disabled
# outputs. Both are parsed here with shell patterns so the tool does not depend
# on jq being installed.
#
# The first half of the file only reads. The second half changes the compositor
# and is called exclusively from `ivm display`; doctor never reaches it.

hypr_available() {
    have hyprctl && hyprctl monitors >/dev/null 2>&1
}

# The runtime directory where Hyprland keeps its sockets. The instance signature
# is a directory name, so it is discovered by looking for the one that actually
# holds a live control socket.
#
# Reading it from Hyprland's own environment does not work: Hyprland exports
# those variables to its children, not to itself.
hypr_signature_discover() {
    local runtime=${XDG_RUNTIME_DIR:-} dir
    [[ -n $runtime && -d $runtime/hypr ]] || return 1
    for dir in "$runtime"/hypr/*/; do
        [[ -S ${dir}.socket.sock ]] || continue
        dir=${dir%/}
        printf '%s' "${dir##*/}"
        return 0
    done
    return 1
}

# Make hyprctl work when the tool is started by something that does not inherit
# the session environment (a systemd unit, cron, Sunshine's prep hook). Without
# the signature, hyprctl talks to the wrong socket or to none at all.
#
# Returns non-zero when the compositor still cannot be reached, so callers can
# report it instead of emitting a hyprctl error into the stream.
hypr_env_discover() {
    hypr_available && return 0

    if [[ -z ${XDG_RUNTIME_DIR:-} && -d /run/user/$(id -u 2>/dev/null) ]]; then
        export XDG_RUNTIME_DIR=/run/user/$(id -u)
    fi

    if [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
        local signature='' pid env
        signature=$(hypr_signature_discover) || true

        if [[ -z $signature ]]; then
            # awk instead of head: head closes the pipe and pgrep dies from
            # SIGPIPE, which pipefail turns into a failure.
            pid=$(pgrep -x Hyprland 2>/dev/null | awk 'NR == 1 { print }')
            if [[ -n $pid && -r /proc/$pid/environ ]]; then
                env=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null)
                signature=$(awk -F= '$1 == "HYPRLAND_INSTANCE_SIGNATURE" { print $2 }' <<<"$env")
            fi
        fi

        if [[ -n $signature ]]; then
            export HYPRLAND_INSTANCE_SIGNATURE=$signature
        fi
    fi

    hypr_available
}

# Normalised list of every output, enabled or not.
#
# Format: name|id|widthxheight@rate|position|disabled|scale
hypr_monitor_records() {
    local line name='' id='' geom='' pos='' disabled='' scale=''
    while IFS= read -r line; do
        if [[ $line =~ ^Monitor\ ([^ ]+)\ \(ID\ ([0-9]+)\): ]]; then
            if [[ -n $name ]]; then
                printf '%s|%s|%s|%s|%s|%s\n' "$name" "$id" "$geom" "$pos" "$disabled" "$scale"
            fi
            name=${BASH_REMATCH[1]}
            id=${BASH_REMATCH[2]}
            geom=''
            pos=''
            disabled=''
            scale=''
        elif [[ $line =~ ^[[:space:]]+([0-9]+x[0-9]+@[0-9.]+)\ at\ (-?[0-9]+x-?[0-9]+) ]]; then
            geom=${BASH_REMATCH[1]}
            pos=${BASH_REMATCH[2]}
        elif [[ $line =~ ^[[:space:]]+disabled:\ (true|false) ]]; then
            disabled=${BASH_REMATCH[1]}
        elif [[ $line =~ ^[[:space:]]+scale:\ ([0-9.]+) ]]; then
            scale=${BASH_REMATCH[1]}
        fi
    done < <(hyprctl monitors all 2>/dev/null)
    if [[ -n $name ]]; then
        printf '%s|%s|%s|%s|%s|%s\n' "$name" "$id" "$geom" "$pos" "$disabled" "$scale"
    fi
}

# Field number per record: 1 name, 2 id, 3 geometry, 4 position, 5 disabled,
# 6 scale.
hypr_monitor_field() {
    local name=$1 field=$2
    hypr_monitor_records | awk -F'|' -v n="$name" -v f="$field" '!found && $1 == n { print $f; found = 1 }'
}

hypr_monitor_exists() {
    hypr_monitor_records | awk -F'|' -v n="$1" '$1 == n { found = 1 } END { exit !found }'
}

hypr_monitor_enabled() {
    [[ $(hypr_monitor_field "$1" 5) == false ]]
}

# Names of every enabled output, one per line.
hypr_enabled_outputs() {
    hypr_monitor_records | awk -F'|' '$5 == "false" { print $1 }'
}

# Names of outputs that exist but are turned off.
hypr_disabled_outputs() {
    hypr_monitor_records | awk -F'|' '$5 == "true" { print $1 }'
}

# Enabled outputs that look virtual: Hyprland reports no hardware description
# for them, unlike a real panel. Used to catch leftover phantom monitors from
# older setups, which overlap the stream and steal its input.
hypr_virtual_outputs() {
    local line name make
    while IFS= read -r line; do
        if [[ $line =~ ^Monitor\ ([^ ]+)\ \(ID\ ([0-9]+)\): ]]; then
            name=${BASH_REMATCH[1]}
        elif [[ $line =~ ^[[:space:]]+make:\ *(.*)$ ]]; then
            make=${BASH_REMATCH[1]}
            make=${make%"${make##*[![:space:]]}"}
            if [[ -z $make ]]; then
                printf '%s\n' "$name"
            fi
        fi
    done < <(hyprctl monitors 2>/dev/null)
}

# Configuration errors reported by the compositor. Empty when the config is
# clean, which matters because a broken rule can undo a runtime change.
hypr_config_errors() {
    hyprctl configerrors 2>/dev/null
}

# ---------------------------------------------------------------------------
# Changes to the compositor
# ---------------------------------------------------------------------------

# Lua configurations (Hyprland 0.56+) replaced the keyword interface: `hyprctl
# keyword` answers "keyword can't work with non-legacy parsers". Runtime changes
# go through `hyprctl eval` and the hl API instead. Older setups still accept
# keywords, so both paths are kept behind one function.
hypr_apply_monitor_rule() {
    local name=$1 mode=$2 position=$3 scale=${4:-1.0}
    local message='' status=0

    case $(platform_hyprland_dialect) in
        lua)
            # `hyprctl eval` answers `ok` on success and exits non-zero on a Lua
            # error, but the message still has to be read: a rule Hyprland
            # rejects is not a Lua error.
            message=$(hyprctl eval "hl.monitor({output=\"${name}\", mode=\"${mode}\", position=\"${position}\", scale=${scale}})" 2>&1) || status=$?
            ;;
        legacy)
            # `hyprctl keyword` exits 0 even when it refuses the rule, so the
            # message is the only signal here.
            message=$(hyprctl keyword monitor "${name},${mode},${position},${scale}" 2>&1) || status=$?
            ;;
        *)
            ivm_error "hyprland: cannot tell whether the configuration is Lua or legacy"
            return "$IVM_EXIT_PROBLEMS"
            ;;
    esac

    if ((status != 0)) || [[ -n $message && $message != ok* ]]; then
        ivm_error "hyprland: could not apply the monitor rule: ${message:-exit status $status}"
        return "$IVM_EXIT_PROBLEMS"
    fi
}

# Create a headless output with an explicit name.
#
# `Name already taken` is not an error: the output exists, which is exactly what
# was asked for. hyprctl exits 0 in both cases, so the message is the only
# signal, and the state has to be read back to know what happened.
hypr_output_create() {
    local name=$1 message
    message=$(hyprctl output create headless "$name" 2>&1) || true
    case $message in
        ok|'Name already taken'*) return 0 ;;
        *)
            ivm_error "hyprland: could not create output '$name': ${message:-no answer}"
            return "$IVM_EXIT_PROBLEMS"
            ;;
    esac
}

# Remove an output. hyprctl returns 0 even when the output does not exist, so the
# caller must check the real state afterwards.
hypr_output_remove() {
    local name=$1 message
    message=$(hyprctl output remove "$name" 2>&1) || true
    case $message in
        ok) return 0 ;;
        'output not found'*|'no such output'*) return 1 ;;
        *)
            ivm_error "hyprland: could not remove output '$name': ${message:-no answer}"
            return "$IVM_EXIT_PROBLEMS"
            ;;
    esac
}

# Creating an output can move the active window to it and steal the focus. Save
# both in a Lua global so the previous state can be put back once the rule is
# applied.
#
# Only the Lua API exposes the window list and the focus dispatchers; the legacy
# keyword interface has no equivalent, so this is a no-op there and the caller
# is told about it.
hypr_focus_snapshot() {
    [[ $(platform_hyprland_dialect) == lua ]] || return 1
    hyprctl eval 'local am=hl.get_active_monitor(); local aw=hl.get_active_window(); local mon=(am and am.name) or ""; local addr=(aw and aw.address) or ""; local ws=0; if aw and aw.workspace then ws=aw.workspace.id end; IVM_FOCUS_SNAPSHOT=mon.."|"..addr.."|"..tostring(ws)' >/dev/null
}

hypr_focus_restore() {
    [[ $(platform_hyprland_dialect) == lua ]] || return 1
    hyprctl eval 'local snap=IVM_FOCUS_SNAPSHOT; IVM_FOCUS_SNAPSHOT=nil; if not snap then return end; local mon,addr,ws=snap:match("([^|]*)|([^|]*)|([^|]*)"); local wsid=tonumber(ws) or 0; if addr~="" and wsid~=0 then local target=nil; for _,w in ipairs(hl.get_windows()) do if w.address==addr then target=w break end end; if target and target.workspace and target.workspace.id~=wsid then hl.dsp.focus({window=target}); hl.dsp.window.move({workspace=tostring(wsid), follow=false}) end end; local am=hl.get_active_monitor(); if mon~="" and (not am or am.name~=mon) then hl.dsp.focus({monitor=mon}) end' >/dev/null
}
