# shellcheck shell=bash
#
# The virtual output, as seen from the tool's point of view.
#
# Read-only for now: doctor needs to know whether the output exists and whether
# the desktop layout makes sense. Creating and removing it belongs to
# `ivm display` and `ivm watch`.

# The configured output name, which is what everything else refers to.
display_name() {
    printf '%s' "$IVM_OUTPUT_NAME"
}

display_exists() {
    hypr_monitor_exists "$(display_name)"
}

display_enabled() {
    hypr_monitor_enabled "$(display_name)"
}

# Geometry of the output as `widthxheight@rate at position`, or empty.
display_geometry() {
    local geom pos
    geom=$(hypr_monitor_field "$(display_name)" 3)
    pos=$(hypr_monitor_field "$(display_name)" 4)
    [[ -n $geom ]] || return 1
    printf '%s at %s' "$geom" "$pos"
}

# Detects the layout mistake that breaks input: a monitor that does not touch any
# other. The cursor cannot cross empty space, so the user sees a working stream
# and a mouse that stops at the edge of the laptop panel.
#
# Prints `ok`, `gap` or `absent`.
display_adjacency() {
    local name
    name=$(display_name)
    hypr_monitor_records | awk -F'|' -v target="$name" '
        function touches(ax, ay, aw, ah, bx, by, bw, bh) {
            if (ax + aw == bx || bx + bw == ax)
                return (ay < by + bh && by < ay + ah)
            if (ay + ah == by || by + bh == ay)
                return (ax < bx + bw && bx < ax + aw)
            return 0
        }
        $5 == "false" {
            split($3, g, "@"); split(g[1], wh, "x"); split($4, xy, "x")
            count++
            n[count] = $1
            x[count] = xy[1] + 0
            y[count] = xy[2] + 0
            w[count] = wh[1] + 0
            h[count] = wh[2] + 0
        }
        END {
            idx = 0
            for (i = 1; i <= count; i++)
                if (n[i] == target) idx = i
            if (!idx) { print "absent"; exit }
            for (i = 1; i <= count; i++) {
                if (i == idx) continue
                if (touches(x[idx], y[idx], w[idx], h[idx], x[i], y[i], w[i], h[i])) {
                    print "ok"
                    exit
                }
            }
            print "gap"
        }
    '
}
