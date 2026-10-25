#!/usr/bin/env bash
#
# Checks for the layout arithmetic: where the output lands and which scales the
# compositor can honour.
#
# These are the two places where a mistake is invisible. A wrong scale is applied
# silently (Hyprland rounds instead of refusing) and a wrong position still
# streams, it only stops the pointer at the edge of the panel. So both are tested
# against fixed compositor output instead of against the real one.
#
# Run: ./tests/geometry.sh

set -uo pipefail

IVM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
for _module in common config platform hyprland sunshine display; do
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

status_of() {
    "$@" >/dev/null 2>&1
    printf '%s' "$?"
}

# --- a laptop panel only ----------------------------------------------------

# 1920x1080 at scale 2 occupies 960x540 of layout, which is the case that a
# physical-pixel calculation gets wrong.
hypr_monitor_records() {
    printf 'eDP-1|0|1920x1080@165.00000|0x0|false|2\n'
}

check 'the laptop panel is measured in layout pixels' \
    '0 0 960 540' "$(display_other_box)"
check 'right is glued to its logical right edge' \
    '960 0' "$(display_position 1920 1080 right 2)"
check 'left subtracts the logical width' \
    '-960 0' "$(display_position 1920 1080 left 2)"
check 'above subtracts the logical height' \
    '0 -540' "$(display_position 1920 1080 above 2)"
check 'below starts at its logical bottom' \
    '0 540' "$(display_position 1920 1080 below 2)"
check 'the default side is right' \
    '960 0' "$(display_position 1920 1080)"
# The physical size is only divided by the scale of the output being created, so
# with the scale left out the 1920 px frame keeps its full width.
check 'the default scale is 1' \
    '-1920 0' "$(display_position 1920 1080 left)"

# --- the iPad, in the configuration the maintainer uses --------------------

# 2360x1640 at 1.6 is 1475x1025, so the output must occupy 1475 px of layout and
# not the 2360 physical ones: otherwise `left` leaves a 885 px gap.
check 'a scaled output is 1475 layout px wide' \
    '1475x1025' "$(display_layout_size 2360 1640 1.6)"
check 'right stays at the panel edge for a scaled output' \
    '960 0' "$(display_position 2360 1640 right 1.6)"
check 'left uses the logical width, not the physical one' \
    '-1475 0' "$(display_position 2360 1640 left 1.6)"
check 'above uses the logical height' \
    '0 -1025' "$(display_position 2360 1640 above 1.6)"
check 'below starts at the panel logical bottom' \
    '0 540' "$(display_position 2360 1640 below 1.6)"

# --- which scales the compositor can actually apply -------------------------

check '2360x1640 at 1.6 divides exactly' 0 "$(status_of display_scale_is_exact 2360 1640 1.6)"
check '1920x1334 at 1.6 does not' 1 "$(status_of display_scale_is_exact 1920 1334 1.6)"
check '1920x1334 at 1.5 does not' 1 "$(status_of display_scale_is_exact 1920 1334 1.5)"
check '1920x1080 at 1.5 does' 0 "$(status_of display_scale_is_exact 1920 1080 1.5)"
check '1920x1080 at 2 divides exactly' 0 "$(status_of display_scale_is_exact 1920 1080 2)"
check '1.0 always divides exactly' 0 "$(status_of display_scale_is_exact 1919 1333 1.0)"
check 'a scale of zero is refused' 1 "$(status_of display_scale_is_exact 1920 1080 0)"
check 'an empty scale is refused' 1 "$(status_of display_scale_is_exact 1920 1080 '')"

check 'an exact scale is kept' '1.6' "$(display_scale_effective 2360 1640 1.6)"
check 'an exact scale reports success' 0 "$(status_of display_scale_effective 2360 1640 1.6)"
check 'an impossible scale falls back to 1.0' '1.0' "$(display_scale_effective 1920 1334 1.6)"
check 'the fallback is reported as a failure' 1 "$(status_of display_scale_effective 1920 1334 1.6)"
check 'the reason shows both dimensions' \
    '1920x1334 at scale 1.6 is 1200.00x833.75 layout pixels' \
    "$(display_scale_reason 1920 1334 1.6)"

check 'a scale below the range is refused' 1 "$(status_of display_is_scale 0.4)"
check 'a scale above the range is refused' 1 "$(status_of display_is_scale 4.5)"
check 'a word is not a scale' 1 "$(status_of display_is_scale wide)"
check 'a decimal scale is accepted' 0 "$(status_of display_is_scale 1.25)"

# --- the output already exists ---------------------------------------------

# It must never be part of the box it is placed against, or it lands beyond its
# own right edge and opens a gap the pointer cannot cross.
hypr_monitor_records() {
    printf 'eDP-1|0|1920x1080@165.00000|0x0|false|1\n'
    printf 'MOONLIGHT|1|2360x1640@60.00000|1920x0|false|1.6\n'
}
check 'the virtual output is excluded from the box' \
    '0 0 1920 1080' "$(display_other_box)"
check 'a second create keeps the same position' \
    '1920 0' "$(display_position 2360 1640 right 1.6)"
check 'a scaled output next to the panel touches it' ok "$(display_adjacency)"

# A scaled output measured in physical pixels would look far away.
hypr_monitor_records() {
    printf 'eDP-1|0|1920x1080@165.00000|0x0|false|1\n'
    printf 'MOONLIGHT|1|2360x1640@60.00000|-2360x0|false|1.6\n'
}
check 'a real gap is still detected' gap "$(display_adjacency)"

# --- no other output ------------------------------------------------------

hypr_monitor_records() { :; }
check 'with nothing else enabled the origin is used' '0 0' "$(display_position 1920 1080 right 1.6)"
check 'an absent output is reported' absent "$(display_adjacency)"

printf '\n%d checks, %d failures\n' "$checks" "$failures"
((failures == 0))
