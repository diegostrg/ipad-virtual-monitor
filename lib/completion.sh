# shellcheck shell=bash
#
# `ivm completion` — print a completion script for the shell in use.
#
# The scripts live here instead of under share/ so that a checkout with bin/ivm
# on the PATH is enough: no install step and no path to remember. They are
# static text on purpose; the command list is small and stable, and generating
# it would add more code than it saves.

_completion_usage() {
    cat <<'EOF'
Usage: ivm completion <shell>

Print a completion script for bash, zsh or fish.

Bash:
  ivm completion bash > ~/.local/share/bash-completion/completions/ivm

Zsh:
  mkdir -p ~/.zfunc
  ivm completion zsh > ~/.zfunc/_ivm
  # and, in ~/.zshrc, before compinit runs: fpath=(~/.zfunc $fpath)

Fish:
  ivm completion fish > ~/.config/fish/completions/ivm.fish

For the current session only, after compinit has run:
  eval "$(ivm completion zsh)"    # zsh
  eval "$(ivm completion bash)"   # bash
EOF
}

ivm_completion() {
    local shell=${1:-}
    case $shell in
        bash) _completion_bash ;;
        zsh) _completion_zsh ;;
        fish) _completion_fish ;;
        help|-h|--help|'') _completion_usage ;;
        *)
            ivm_error "completion: unknown shell: $shell"
            _completion_usage >&2
            return "$IVM_EXIT_USAGE"
            ;;
    esac
}

_completion_bash() {
    cat <<'BASH'
# Bash completion for ivm, printed by `ivm completion bash`.

_ivm_completion() {
    local cur prev cmd
    COMPREPLY=()
    cur=${COMP_WORDS[COMP_CWORD]}
    if ((COMP_CWORD > 0)); then
        prev=${COMP_WORDS[COMP_CWORD - 1]}
    else
        prev=''
    fi
    cmd=${COMP_WORDS[1]:-}

    # Values first, so `--side l<TAB>` does not fall through to the flags.
    case $prev in
        --side)
            COMPREPLY=($(compgen -W 'right left above below' -- "$cur"))
            return
            ;;
        --width|--height|--fps|--scale|--grace|--interval)
            return
            ;;
    esac
    if [[ $cur == --side=* ]]; then
        COMPREPLY=($(compgen -W 'right left above below' -- "${cur#--side=}"))
        COMPREPLY=("${COMPREPLY[@]/#/--side=}")
        return
    fi

    if ((COMP_CWORD == 1)); then
        COMPREPLY=($(compgen -W 'up down status net doctor display watch completion version help' -- "$cur"))
        return
    fi

    case $cmd in
        net)
            if ((COMP_CWORD == 2)); then
                COMPREPLY=($(compgen -W 'status up down help' -- "$cur"))
                return
            fi
            COMPREPLY=($(compgen -W '--verbose --dry-run --yes --help' -- "$cur"))
            ;;
        display)
            if ((COMP_CWORD == 2)); then
                COMPREPLY=($(compgen -W 'status create remove prep help' -- "$cur"))
                return
            fi
            COMPREPLY=($(compgen -W '--width --height --fps --side --scale --dry-run --verbose --help' -- "$cur"))
            ;;
        doctor)
            COMPREPLY=($(compgen -W '--verbose --report --help' -- "$cur"))
            ;;
        watch)
            COMPREPLY=($(compgen -W '--grace --interval --once --help' -- "$cur"))
            ;;
        up|status)
            COMPREPLY=($(compgen -W '--verbose --help' -- "$cur"))
            ;;
        down)
            COMPREPLY=($(compgen -W '--all --help' -- "$cur"))
            ;;
        completion)
            COMPREPLY=($(compgen -W 'bash zsh fish' -- "$cur"))
            ;;
        help)
            # `ivm help <command>`: the same list, so the topics are discoverable.
            COMPREPLY=($(compgen -W 'up down status net doctor display watch completion version help' -- "$cur"))
            ;;
        *)
            COMPREPLY=($(compgen -W '--help' -- "$cur"))
            ;;
    esac
}

complete -F _ivm_completion ivm
BASH
}

_completion_zsh() {
    cat <<'ZSH'
#compdef ivm
#
# Zsh completion for ivm, printed by `ivm completion zsh`.

_ivm() {
    local curcontext="$curcontext" state line
    typeset -A opt_args

    local -a commands
    commands=(
        'up:prepare the host: Sunshine, its hook and the supervisor'
        'down:remove the output and stop the supervisor'
        'status:one-screen summary of the current state'
        'net:report, set up or take down the USB network'
        'doctor:inspect every layer and report what is broken'
        'display:create, remove or inspect the virtual output'
        'watch:remove the output when the stream ends'
        'completion:print a completion script for a shell'
        'version:print the version'
        'help:print help'
    )

    _arguments -s -C \
        '(- *)'{-h,--help}'[print help]' \
        '(- *)'{-v,--version}'[print the version]' \
        '1:command:->command' \
        '*::argument:->argument'

    case $state in
        command)
            _describe -t commands 'ivm command' commands
            ;;
        argument)
            case $words[1] in
                up) _ivm_up ;;
                down) _ivm_down ;;
                status) _ivm_status ;;
                net) _ivm_net ;;
                doctor) _ivm_doctor ;;
                display) _ivm_display ;;
                watch) _ivm_watch ;;
                completion) _ivm_shells ;;
                help) _describe -t commands 'ivm command' commands ;;
            esac
            ;;
    esac
}

_ivm_up() {
    _arguments -s \
        '--verbose[show the detail behind each check]' \
        '(- *)'{-h,--help}'[print help]'
}

_ivm_down() {
    _arguments -s \
        '--all[also stop Sunshine]' \
        '(- *)'{-h,--help}'[print help]'
}

_ivm_status() {
    _arguments -s \
        '--verbose[show the detail behind each check]' \
        '(- *)'{-h,--help}'[print help]'
}

_ivm_doctor() {
    _arguments -s \
        '--verbose[show the paths and commands behind each check]' \
        '--report[print a sanitized report for a bug tracker]' \
        '(- *)'{-h,--help}'[print help]'
}

_ivm_net() {
    local curcontext="$curcontext" state line
    typeset -A opt_args

    _arguments -s -C \
        '--verbose[show the detail behind each check]' \
        '--dry-run[print the plan without applying it]' \
        '--yes[apply without asking]' \
        '(- *)'{-h,--help}'[print help]' \
        '1:subcommand:->subcommand' \
        '*::argument:->argument'

    case $state in
        subcommand)
            _values 'net subcommand' \
                'status[report the USB network, read-only]' \
                'up[make it work: profile, NetworkManager, firewall]' \
                'down[deactivate the shared connection]'
            ;;
    esac
}

_ivm_display() {
    local curcontext="$curcontext" state line
    typeset -A opt_args

    _arguments -s -C \
        '--width=[width in pixels]:width' \
        '--height=[height in pixels]:height' \
        '--fps=[refresh rate]:fps' \
        '--side=[side of the layout]:side:(right left above below)' \
        '--scale=[layout scale]:scale' \
        '--dry-run[print the plan without touching the compositor]' \
        '--verbose[show the detail behind each check]' \
        '(- *)'{-h,--help}'[print help]' \
        '1:subcommand:->subcommand' \
        '*::argument:->argument'

    case $state in
        subcommand)
            _values 'display subcommand' \
                'status[show the output and what would be created]' \
                'create[create it, or move it to the right place]' \
                'remove[remove it]' \
                'prep[Sunshine hook; always succeeds]'
            ;;
    esac
}

_ivm_watch() {
    _arguments -s \
        '--grace=[seconds before removing the output]:seconds' \
        '--interval=[seconds between checks]:seconds' \
        '--once[check once and exit]' \
        '(- *)'{-h,--help}'[print help]'
}

_ivm_shells() {
    _values 'shell' bash zsh fish
}

# compinit autoloads this file as the function _ivm and calls it with the words
# on the line. When it is evaluated instead, there is nothing to complete yet,
# so it registers itself and waits.
if [[ ${zsh_eval_context[-1]:-} == loadautofunc ]]; then
    _ivm "$@"
else
    compdef _ivm ivm
fi
ZSH
}

_completion_fish() {
    cat <<'FISH'
# Fish completion for ivm, printed by `ivm completion fish`.

complete -c ivm -f

# Commands.
complete -c ivm -n __fish_use_subcommand -a up -d 'Prepare the host: Sunshine, its hook, the supervisor'
complete -c ivm -n __fish_use_subcommand -a down -d 'Remove the output and stop the supervisor'
complete -c ivm -n __fish_use_subcommand -a status -d 'One-screen summary of the current state'
complete -c ivm -n __fish_use_subcommand -a net -d 'Report, set up or take down the USB network'
complete -c ivm -n __fish_use_subcommand -a doctor -d 'Inspect every layer and report what is broken'
complete -c ivm -n __fish_use_subcommand -a display -d 'Create, remove or inspect the virtual output'
complete -c ivm -n __fish_use_subcommand -a watch -d 'Remove the output when the stream ends'
complete -c ivm -n __fish_use_subcommand -a completion -d 'Print a completion script for a shell'
complete -c ivm -n __fish_use_subcommand -a version -d 'Print the version'
complete -c ivm -n __fish_use_subcommand -a help -d 'Print help'

# Help works everywhere; the version only before a subcommand, where `-v` is not
# verbose.
complete -c ivm -s h -l help -d 'Print help'
complete -c ivm -n __fish_use_subcommand -s v -l version -d 'Print the version'

# `ivm help <command>`.
complete -c ivm -n '__fish_seen_subcommand_from help' -a 'up down status net doctor display watch completion version help'

# net.
complete -c ivm -n '__fish_seen_subcommand_from net; and not __fish_seen_subcommand_from status up down help' -a status -d 'Report the USB network, read-only'
complete -c ivm -n '__fish_seen_subcommand_from net; and not __fish_seen_subcommand_from status up down help' -a up -d 'Make it work: profile, NetworkManager, firewall'
complete -c ivm -n '__fish_seen_subcommand_from net; and not __fish_seen_subcommand_from status up down help' -a down -d 'Deactivate the shared connection'
complete -c ivm -n '__fish_seen_subcommand_from net' -l dry-run -d 'Print the plan without applying it'
complete -c ivm -n '__fish_seen_subcommand_from net; and __fish_seen_subcommand_from up down' -l yes -d 'Apply without asking'
complete -c ivm -n '__fish_seen_subcommand_from net; and __fish_seen_subcommand_from status' -l verbose -d 'Show the detail behind each check'

# display.
complete -c ivm -n '__fish_seen_subcommand_from display; and not __fish_seen_subcommand_from status create remove prep help' -a status -d 'Show the output and what would be created'
complete -c ivm -n '__fish_seen_subcommand_from display; and not __fish_seen_subcommand_from status create remove prep help' -a create -d 'Create it, or move it to the right place'
complete -c ivm -n '__fish_seen_subcommand_from display; and not __fish_seen_subcommand_from status create remove prep help' -a remove -d 'Remove it'
complete -c ivm -n '__fish_seen_subcommand_from display' -l dry-run -d 'Print the plan without touching the compositor'
complete -c ivm -n '__fish_seen_subcommand_from display' -l verbose -d 'Show the detail behind each check'
complete -c ivm -n '__fish_seen_subcommand_from display; and __fish_seen_subcommand_from create' -l width -x -d 'Width in pixels'
complete -c ivm -n '__fish_seen_subcommand_from display; and __fish_seen_subcommand_from create' -l height -x -d 'Height in pixels'
complete -c ivm -n '__fish_seen_subcommand_from display; and __fish_seen_subcommand_from create' -l fps -x -d 'Refresh rate'
complete -c ivm -n '__fish_seen_subcommand_from display; and __fish_seen_subcommand_from create' -l side -x -a 'right left above below' -d 'Side of the layout'
complete -c ivm -n '__fish_seen_subcommand_from display; and __fish_seen_subcommand_from create' -l scale -x -d 'Layout scale'

# doctor.
complete -c ivm -n '__fish_seen_subcommand_from doctor' -l verbose -d 'Show the paths and commands behind each check'
complete -c ivm -n '__fish_seen_subcommand_from doctor' -l report -d 'Print a sanitized report for a bug tracker'

# up, down, status, watch.
complete -c ivm -n '__fish_seen_subcommand_from up status' -l verbose -d 'Show the detail behind each check'
complete -c ivm -n '__fish_seen_subcommand_from down' -l all -d 'Also stop Sunshine'
complete -c ivm -n '__fish_seen_subcommand_from watch' -l grace -x -d 'Seconds before removing the output'
complete -c ivm -n '__fish_seen_subcommand_from watch' -l interval -x -d 'Seconds between checks'
complete -c ivm -n '__fish_seen_subcommand_from watch' -l once -d 'Check once and exit'

# completion.
complete -c ivm -n '__fish_seen_subcommand_from completion' -a 'bash zsh fish'
FISH
}
