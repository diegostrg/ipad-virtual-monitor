#!/usr/bin/env bash
#
# Checks for the completion scripts printed by `ivm completion`.
#
# The scripts are static text, so the failure that matters is a command or an
# option that exists in the tool but not in the shell, or a script one of the
# shells refuses to parse. Each shell is tested with its own parser, and bash is
# driven through the same function it installs.
#
# zsh and fish are optional: the checks that need them are skipped, not failed,
# because a contributor may not have them.
#
# Run: ./tests/completion.sh

set -uo pipefail

IVM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
for _module in common completion; do
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

check_contains() {
    local what=$1 needle=$2 haystack=$3
    checks=$((checks + 1))
    if [[ $haystack == *"$needle"* ]]; then
        printf '  ok   %s\n' "$what"
    else
        printf '  FAIL %s (missing: %s)\n' "$what" "$needle"
        failures=$((failures + 1))
    fi
}

check_lacks() {
    local what=$1 needle=$2 haystack=$3
    checks=$((checks + 1))
    if [[ $haystack != *"$needle"* ]]; then
        printf '  ok   %s\n' "$what"
    else
        printf '  FAIL %s (unexpected: %s)\n' "$what" "$needle"
        failures=$((failures + 1))
    fi
}

skip() {
    printf '  skip %s\n' "$1"
}

# Exit status without the output, for calls that print a script.
status_of() {
    "$@" >/dev/null 2>&1
    printf '%s' "$?"
}

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmpdir"' EXIT

bash_script=$tmpdir/ivm.bash
zsh_script=$tmpdir/_ivm
fish_script=$tmpdir/ivm.fish

ivm_completion bash >"$bash_script"
ivm_completion zsh >"$zsh_script"
ivm_completion fish >"$fish_script"

# --- the command itself ----------------------------------------------------

check 'bash is written' 0 "$(status_of ivm_completion bash)"
check 'zsh is written' 0 "$(status_of ivm_completion zsh)"
check 'fish is written' 0 "$(status_of ivm_completion fish)"

output=$(ivm_completion tcsh 2>&1)
check 'an unknown shell is a usage error' 2 "$(status_of ivm_completion tcsh)"
check_contains 'and names the shell it does not know' 'unknown shell: tcsh' "$output"

output=$(ivm_completion 2>&1)
check 'no argument prints the usage' 0 "$(status_of ivm_completion)"
check_contains 'the usage says where to install it' 'ivm completion bash >' "$output"

# --- bash ------------------------------------------------------------------

check 'the bash script parses' 0 "$(status_of bash -n "$bash_script")"
check_contains 'the bash script registers itself' 'complete -F _ivm_completion ivm' "$(cat "$bash_script")"

# Run the function the script installs, with the state the shell would set up.
bash_complete() {
    local line=$1
    ( . "$bash_script"
      # shellcheck disable=SC2206
      COMP_WORDS=($line)
      # A trailing space means the cursor sits on a fresh, empty word.
      [[ $line == *' ' ]] && COMP_WORDS+=('')
      COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
      COMPREPLY=()
      _ivm_completion
      printf '%s' "${COMPREPLY[*]}" )
}

check 'every command is offered' \
    'up down status net doctor display watch completion version help' \
    "$(bash_complete 'ivm ')"

check 'a prefix narrows the commands' \
    'down doctor display' \
    "$(bash_complete 'ivm d')"

check 'the net subcommands are offered' \
    'status up down help' \
    "$(bash_complete 'ivm net ')"

check 'the net flags are offered' \
    '--verbose --dry-run --yes --help' \
    "$(bash_complete 'ivm net up --')"

check 'the display flags are offered' \
    '--width --height --fps --side --scale --dry-run --verbose --help' \
    "$(bash_complete 'ivm display create --')"

check 'the sides are offered' \
    'right left above below' \
    "$(bash_complete 'ivm display create --side ')"

check 'an attached side value is completed in place' \
    '--side=left' \
    "$(bash_complete 'ivm display create --side=l')"

check 'doctor has its own flags' \
    '--verbose --report --help' \
    "$(bash_complete 'ivm doctor --')"

check_lacks 'a subcommand does not inherit --version' '--version' \
    "$(bash_complete 'ivm doctor --')"

check 'the watch flags are offered' \
    '--grace --interval --once --help' \
    "$(bash_complete 'ivm watch --')"

check 'the shells are offered' \
    'bash zsh fish' \
    "$(bash_complete 'ivm completion ')"

# `ivm help <command>` takes the command's own name, so the topics have to be
# discoverable from the prompt.
check 'help offers the commands' \
    'up down status net doctor display watch completion version help' \
    "$(bash_complete 'ivm help ')"

# --- zsh -------------------------------------------------------------------

if have zsh; then
    check 'the zsh script parses' 0 "$(status_of zsh -n "$zsh_script")"
    check_contains 'the zsh script declares the command' '#compdef ivm' "$(cat "$zsh_script")"

    # Evaluated after compinit, the script must register itself instead of
    # trying to complete something that is not being completed.
    registered=$(zsh -f -c 'autoload -Uz compinit; compinit -u; source "$1"; print -r -- "${_comps[ivm]:-none}"' ivm "$zsh_script" 2>&1)
    check 'evaluating it registers the completion' '_ivm' "$registered"

    zsh_body=$(cat "$zsh_script")
    check_contains 'zsh knows the report flag' '--report[' "$zsh_body"
    check_contains 'zsh knows the sides' 'right left above below' "$zsh_body"
    check_contains 'zsh knows the net subcommands' 'down[deactivate the shared connection]' "$zsh_body"
else
    skip 'zsh is not installed'
fi

# --- fish ------------------------------------------------------------------

if have fish; then
    check 'the fish script parses' 0 "$(status_of fish -n "$fish_script")"
    fish_complete() {
        fish -c "source '$fish_script'; complete -C '$1'" 2>/dev/null
    }
    check_contains 'fish offers the commands' 'doctor' "$(fish_complete 'ivm ')"
    check_contains 'fish offers the net subcommands' 'up' "$(fish_complete 'ivm net ')"
    check_contains 'fish offers --report for doctor' '--report' "$(fish_complete 'ivm doctor --')"
    check_lacks 'fish does not offer --version after a subcommand' '--version' \
        "$(fish_complete 'ivm doctor --')"
    check_contains 'fish offers the sides' 'above' "$(fish_complete 'ivm display create --side ')"
    check_contains 'fish offers the help topics' 'net' "$(fish_complete 'ivm help ')"
else
    skip 'fish is not installed'
fi

printf '\n%d checks, %d failures\n' "$checks" "$failures"
((failures == 0))
