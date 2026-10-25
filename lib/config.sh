# shellcheck shell=bash
#
# User configuration. The file is parsed key by key against a whitelist instead
# of being sourced: a config file is not code, and sourcing it would turn a typo
# into arbitrary execution.

IVM_CONFIG_FILE=${IVM_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ivm/config}

IVM_OUTPUT_NAME=${IVM_OUTPUT_NAME:-MOONLIGHT}
IVM_SIDE=${IVM_SIDE:-right}
IVM_WIDTH=${IVM_WIDTH:-1920}
IVM_HEIGHT=${IVM_HEIGHT:-1334}
IVM_FPS=${IVM_FPS:-60}
# The scale is what makes the iPad readable: a 2360 px frame at 1.6 gives the same
# apparent density as the laptop panel. It is not free to choose, though; see
# display_scale_is_exact.
IVM_SCALE=${IVM_SCALE:-1.0}
IVM_FOLLOW_CLIENT=${IVM_FOLLOW_CLIENT:-yes}
IVM_GRACE=${IVM_GRACE:-20}

# Only these keys are accepted from the file.
_ivm_config_keys='OUTPUT_NAME SIDE WIDTH HEIGHT FPS SCALE FOLLOW_CLIENT GRACE'

# Load the config file, if it exists. Unknown keys are ignored, malformed values
# are refused with a message naming the key.
ivm_config_load() {
    [[ -r $IVM_CONFIG_FILE ]] || return 0

    local line key value
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -z $line ]] && continue
        [[ $line == *=* ]] || continue
        key=${line%%=*}
        value=${line#*=}
        key=${key%"${key##*[![:space:]]}"}
        value=${value#"${value%%[![:space:]]*}"}

        case " $_ivm_config_keys " in
            *" $key "*) ;;
            *) continue ;;
        esac

        case $key in
            OUTPUT_NAME) IVM_OUTPUT_NAME=$value ;;
            SIDE) IVM_SIDE=$value ;;
            WIDTH) IVM_WIDTH=$value ;;
            HEIGHT) IVM_HEIGHT=$value ;;
            FPS) IVM_FPS=$value ;;
            SCALE) IVM_SCALE=$value ;;
            FOLLOW_CLIENT) IVM_FOLLOW_CLIENT=$value ;;
            GRACE) IVM_GRACE=$value ;;
        esac
    done <"$IVM_CONFIG_FILE"

    ivm_config_validate
}

# Reject values that would produce a broken command later. Failing here is much
# cheaper than failing on the compositor.
ivm_config_validate() {
    local status=$IVM_EXIT_OK

    if [[ ! $IVM_OUTPUT_NAME =~ ^[A-Za-z0-9._-]+$ ]]; then
        ivm_error "config: OUTPUT_NAME must be a simple name, got '$IVM_OUTPUT_NAME'"
        status=$IVM_EXIT_PROBLEMS
    fi
    case $IVM_SIDE in
        right|left|above|below) ;;
        *)
            ivm_error "config: SIDE must be right, left, above or below, got '$IVM_SIDE'"
            status=$IVM_EXIT_PROBLEMS
            ;;
    esac
    if [[ ! $IVM_WIDTH =~ ^[0-9]+$ ]] || ((IVM_WIDTH < 320)); then
        ivm_error "config: WIDTH must be a pixel count above 320, got '$IVM_WIDTH'"
        status=$IVM_EXIT_PROBLEMS
    fi
    if [[ ! $IVM_HEIGHT =~ ^[0-9]+$ ]] || ((IVM_HEIGHT < 240)); then
        ivm_error "config: HEIGHT must be a pixel count above 240, got '$IVM_HEIGHT'"
        status=$IVM_EXIT_PROBLEMS
    fi
    if [[ ! $IVM_FPS =~ ^[0-9]+$ ]] || ((IVM_FPS < 24 || IVM_FPS > 240)); then
        ivm_error "config: FPS must be between 24 and 240, got '$IVM_FPS'"
        status=$IVM_EXIT_PROBLEMS
    fi
    # Only the shape is checked here. Whether this scale divides the size into
    # whole logical pixels depends on the mode, which may still come from the
    # client, so that test belongs where the mode is known.
    if ! awk -v s="$IVM_SCALE" 'BEGIN { exit !(s ~ /^[0-9]+(\.[0-9]+)?$/ && s + 0 >= 0.5 && s + 0 <= 4) }'; then
        ivm_error "config: SCALE must be a number between 0.5 and 4, got '$IVM_SCALE'"
        status=$IVM_EXIT_PROBLEMS
    fi
    case $IVM_FOLLOW_CLIENT in
        yes|no) ;;
        *)
            ivm_error "config: FOLLOW_CLIENT must be yes or no, got '$IVM_FOLLOW_CLIENT'"
            status=$IVM_EXIT_PROBLEMS
            ;;
    esac
    if [[ ! $IVM_GRACE =~ ^[0-9]+$ ]] || ((IVM_GRACE > 600)); then
        ivm_error "config: GRACE must be a number of seconds up to 600, got '$IVM_GRACE'"
        status=$IVM_EXIT_PROBLEMS
    fi

    return "$status"
}
