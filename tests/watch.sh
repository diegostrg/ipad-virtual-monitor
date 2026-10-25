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
restarts=0
restart_result=0

display_exists() { ((output_present)); }
display_name() { printf 'MOONLIGHT'; }
sunshine_session_active() { ((session_running)); }

# The real `sunshine_rearm` runs: it guards on the session, then calls this.
sunshine_restart() {
    restarts=$((restarts + 1))
    return "$restart_result"
}

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
    restarts=0
    restart_result=0
    IVM_WATCH_IDLE_SINCE=0
    IVM_VERBOSE=0
    fake_now=1000
    _IVM_WATCH_WARNED_MISSING=0
    _IVM_WATCH_WAITING=0
    _IVM_WATCH_REARM_PENDING=0
    # Per test, so a stub replaced by one case cannot leak into the next.
    hypr_env_discover() { return 0; }
    _display_remove() { removals=$((removals + 1)); output_present=0; return 0; }
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

# --- Sunshine is re-armed so the next connection runs the prep ------------
#
# Sunshine runs the prep when it launches the session's app, and the desktop app
# never exits, so a stale process skips the hook and streams a clone. Removing
# the output has to be paired with a restart.

reset
output_present=1
session_running=1
_watch_reconcile 20 >/dev/null
check 'a running stream never restarts Sunshine' 0 "$restarts"

session_running=0
fake_now=4000
_watch_reconcile 20 >/dev/null
check 'nothing restarts before the grace period' 0 "$restarts"

fake_now=4020
_watch_reconcile 20 >/dev/null
check 'the output goes before the restart' 0 "$output_present"
check 'and Sunshine is restarted once' 1 "$restarts"
check 'leaving no rearm pending' 0 "$_IVM_WATCH_REARM_PENDING"

# --- a restart that fails is retried on the next tick ---------------------

reset
output_present=1
restart_result=1
_watch_reconcile 0 >/dev/null
check 'a failed restart leaves the rearm pending' 1 "$_IVM_WATCH_REARM_PENDING"
check 'the output is removed anyway' 0 "$output_present"

fake_now=5000
restart_result=0
_watch_reconcile 20 >/dev/null
check 'the next tick retries the restart' 2 "$restarts"
check 'and clears the pending flag' 0 "$_IVM_WATCH_REARM_PENDING"

# --- a client that returns while the rearm is pending is not disturbed ----

reset
output_present=1
restart_result=1
_watch_reconcile 0 >/dev/null
check 'the rearm is pending after a failure' 1 "$_IVM_WATCH_REARM_PENDING"

session_running=1
restart_result=0
restarts_before=$restarts
_watch_reconcile 20 >/dev/null
check 'a returning client is not interrupted' "$restarts_before" "$restarts"
check 'and the pending rearm is dropped' 0 "$_IVM_WATCH_REARM_PENDING"

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
check 'a repeated failure is only announced once' 1 "$_IVM_WATCH_WAITING"
_watch_reconcile 0 >/dev/null
check 'and it is not announced again' 1 "$_IVM_WATCH_WAITING"
hypr_env_discover() { return 0; }
_watch_reconcile 0 >/dev/null
check 'recovery is announced and clears the flag' 0 "$_IVM_WATCH_WAITING"

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
