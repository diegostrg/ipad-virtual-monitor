# shellcheck shell=bash
#
# Layer 3: Hyprland's outputs.
#
# `hyprctl monitors` prints human text; `monitors all` also includes disabled
# outputs. Both are parsed here with shell patterns so the tool does not depend
# on jq being installed. Every function in this file is read-only.

hypr_available() {
    have hyprctl && hyprctl monitors >/dev/null 2>&1
}

# Normalised list of every output, enabled or not.
#
# Format: name|id|widthxheight@rate|position|disabled
hypr_monitor_records() {
    local line name='' id='' geom='' pos='' disabled=''
    while IFS= read -r line; do
        if [[ $line =~ ^Monitor\ ([^ ]+)\ \(ID\ ([0-9]+)\): ]]; then
            if [[ -n $name ]]; then
                printf '%s|%s|%s|%s|%s\n' "$name" "$id" "$geom" "$pos" "$disabled"
            fi
            name=${BASH_REMATCH[1]}
            id=${BASH_REMATCH[2]}
            geom=''
            pos=''
            disabled=''
        elif [[ $line =~ ^[[:space:]]+([0-9]+x[0-9]+@[0-9.]+)\ at\ (-?[0-9]+x-?[0-9]+) ]]; then
            geom=${BASH_REMATCH[1]}
            pos=${BASH_REMATCH[2]}
        elif [[ $line =~ ^[[:space:]]+disabled:\ (true|false) ]]; then
            disabled=${BASH_REMATCH[1]}
        fi
    done < <(hyprctl monitors all 2>/dev/null)
    if [[ -n $name ]]; then
        printf '%s|%s|%s|%s|%s\n' "$name" "$id" "$geom" "$pos" "$disabled"
    fi
}

# Field number per record: 1 name, 2 id, 3 geometry, 4 position, 5 disabled.
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
