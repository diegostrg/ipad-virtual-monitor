# shellcheck shell=bash
#
# What machine am I on, and which compositor is running? Everything else depends
# on the answer, so this is detection only: no assumptions about the reference
# machine are allowed to leak out of here.

# Distribution name from os-release, for the report only.
platform_distro() {
    local name='' id=''
    if [[ -r /etc/os-release ]]; then
        name=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-}}")
        id=$(. /etc/os-release && printf '%s' "${ID:-}")
    fi
    printf '%s' "${name:-unknown${id:+ ($id)}}"
}

# True when the session is Wayland at all.
platform_is_wayland() {
    [[ ${XDG_SESSION_TYPE:-} == wayland || -n ${WAYLAND_DISPLAY:-} ]]
}

# Name of the running compositor, lowercased: hyprland, sway, unknown.
platform_compositor() {
    local desktop=${XDG_CURRENT_DESKTOP:-}
    desktop=${desktop,,}
    case $desktop in
        *hyprland*) printf 'hyprland'; return 0 ;;
        *sway*) printf 'sway'; return 0 ;;
    esac
    if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || pgrep -x Hyprland >/dev/null 2>&1; then
        printf 'hyprland'
        return 0
    fi
    printf 'unknown'
}

# Version string of the running Hyprland, or empty when unreachable.
platform_hyprland_version() {
    have hyprctl || return 1
    hyprctl version 2>/dev/null | sed -n '1s/^Hyprland \([^ ]*\).*/\1/p'
}

# Which configuration dialect the running Hyprland uses.
#
# This machine (Hyprland 0.56+) is configured in Lua, where `hyprctl keyword`
# refuses to work and runtime changes go through `hyprctl eval`. Older setups
# use hyprland.conf and the keyword interface. Detection is by file, because the
# running compositor does not expose the dialect anywhere.
platform_hyprland_dialect() {
    if [[ -n ${IVM_HYPRLAND_DIALECT:-} ]]; then
        printf '%s' "$IVM_HYPRLAND_DIALECT"
        return 0
    fi
    local dir=${XDG_CONFIG_HOME:-$HOME/.config}/hypr
    if [[ -f $dir/hyprland.lua ]]; then
        printf 'lua'
    elif [[ -f $dir/hyprland.conf ]]; then
        printf 'legacy'
    else
        printf 'unknown'
    fi
}
