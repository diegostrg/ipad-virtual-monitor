#!/usr/bin/env bash
#
# Checks for the supervisor's decision logic.
#
# These are plain Bash on purpose: no test framework, nothing to install. The
# functions that talk to the real system are replaced by stubs, so the loop can
# be walked through every branch without Sunshine or a compositor.
#
# Run: ./tests/watch.sh

set -uo pipefail

IVM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
for _module in common config platform hyprland sunshine display watch; do
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

# --- stubs -----------------------------------------------------------------

output_present=0

display_exists() { ((output_present)); }
display_name() { printf 'MOONLIGHT'; }
hypr_env_discover() { return 0; }
sunshine_session_active() { ((session_running)); }
_display_remove() { removals=$((removals + 1)); output_present=0; return 0; }

# A clock the test can move.
fake_now=1000
date() {
    if [[ ${1:-} == '+%s' ]]; then
        printf '%s' "$fake_now"
    else
        command date "$@"
    fi
}

reset() {
    output_present=0
    session_running=0
    removals=0
    IVM_WATCH_IDLE_SINCE=0
    IVM_VERBOSE=0
    fake_now=1000
}

# --- a stream that ends is cleaned up after the grace period ----------------

reset
output_present=1
session_running=1
_watch_reconcile 20 >/dev/null
check 'a running stream keeps the output' 1 "$output_present"
check 'a running stream resets the idle timer' 0 "$IVM_WATCH_IDLE_SINCE"

fake_now=1010
session_running=0
_watch_reconcile 20 >/dev/null
check 'the idle timer starts when the stream ends' 1010 "$IVM_WATCH_IDLE_SINCE"
check 'nothing is removed before the grace period' 1 "$output_present"

fake_now=1029
_watch_reconcile 20 >/dev/null
check 'still nothing one second before the end' 1 "$output_present"

fake_now=1030
_watch_reconcile 20 >/dev/null
check 'the output is removed when the grace period ends' 0 "$output_present"
check 'the removal happens once' 1 "$removals"
check 'the idle timer is reset after removing' 0 "$IVM_WATCH_IDLE_SINCE"

# --- a client that comes back cancels the pending removal ------------------

reset
output_present=1
fake_now=2000
_watch_reconcile 20 >/dev/null
fake_now=2010
session_running=1
_watch_reconcile 20 >/dev/null
check 'a returning client cancels the removal' 1 "$output_present"
check 'a returning client resets the timer' 0 "$IVM_WATCH_IDLE_SINCE"

fake_now=2100
session_running=0
_watch_reconcile 20 >/dev/null
check 'the timer restarts from the new idle moment' 2100 "$IVM_WATCH_IDLE_SINCE"

# --- grace zero removes immediately ---------------------------------------

reset
output_present=1
_watch_reconcile 0 >/dev/null
check 'grace 0 removes on the first check' 0 "$output_present"

# --- no output means nothing to do ----------------------------------------

reset
_watch_reconcile 20 >/dev/null
check 'no output, no removal' 0 "$removals"
check 'no output, no timer' 0 "$IVM_WATCH_IDLE_SINCE"

# --- an unreachable compositor is not fatal -------------------------------

reset
output_present=1
hypr_env_discover() { return 1; }
_watch_reconcile 0 >/dev/null
check 'an unreachable compositor does not remove anything' 1 "$output_present"
hypr_env_discover() { return 0; }

# --- a failed removal is retried ------------------------------------------

reset
output_present=1
_display_remove() { removals=$((removals + 1)); return 1; }
fake_now=3000
_watch_reconcile 20 >/dev/null
fake_now=3021
_watch_reconcile 20 >/dev/null
check 'a failed removal is attempted once' 1 "$removals"
check 'the output is still there after a failure' 1 "$output_present"

fake_now=3022
_watch_reconcile 20 >/dev/null
check 'the next tick retries immediately instead of waiting again' 2 "$removals"

printf '\n%d checks, %d failures\n' "$checks" "$failures"
((failures == 0))
