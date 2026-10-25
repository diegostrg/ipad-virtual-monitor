#!/usr/bin/env bash
#
# Checks for the Sunshine configuration writer.
#
# This is the only code in the project that edits a file the user cares about, so
# it is tested directly: an existing file, the round trip, the backup, and the
# case where nothing has to change. The real file is never touched; IVM_SUNSHINE_CONF
# points the functions at a copy in a temporary directory.

set -uo pipefail

IVM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
for _module in common config platform sunshine; do
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

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$tmpdir"' EXIT

conf=$tmpdir/sunshine.conf
cat >"$conf" <<'EOF'
# a comment
capture = kms
encoder = vaapi
min_log_level = 2
global_prep_cmd = [{"do":"/old/hook"}]
EOF
IVM_SUNSHINE_CONF=$conf

backups() { find "$tmpdir" -maxdepth 1 -name 'sunshine.conf.bak-ivm-*' | wc -l; }

# --- replacing a value -----------------------------------------------------

result=0
sunshine_set_key capture wlr || result=$?
check 'setting a key reports a change' 0 "$result"
check 'the value is replaced' 'wlr' "$(sunshine_conf_get capture)"
check 'other keys are preserved' 'vaapi' "$(sunshine_conf_get encoder)"
check 'the comment is preserved' 1 "$(grep -c '^# a comment' "$conf")"
check 'the file has one line per key' 1 "$(grep -c '^capture = ' "$conf")"
check 'a backup was written' 1 "$(backups)"

# --- the same value again --------------------------------------------------

result=0
sunshine_set_key capture wlr || result=$?
check 'an unchanged value reports no change' 1 "$result"
check 'no second backup is written' 1 "$(backups)"

# --- adding a key that is not there ----------------------------------------

result=0
sunshine_set_key output_name MOONLIGHT || result=$?
check 'adding a key reports a change' 0 "$result"
check 'the key is readable afterwards' 'MOONLIGHT' "$(sunshine_conf_get output_name)"
check 'it is appended at the end' 'output_name = MOONLIGHT' "$(tail -1 "$conf")"

# --- a JSON value survives -------------------------------------------------

result=0
sunshine_set_key global_prep_cmd '[{"do":"/new/hook"}]' || result=$?
check 'a JSON value can be written' 0 "$result"
check 'it reads back intact' '[{"do":"/new/hook"}]' "$(sunshine_conf_get global_prep_cmd)"
check 'the old hook is gone' 0 "$(grep -c '/old/hook' "$conf")"

# --- a duplicated key collapses to one -------------------------------------

printf 'capture = kms\ncapture = x11\n' >"$conf"
result=0
sunshine_set_key capture wlr || result=$?
check 'a duplicated key is replaced once' 1 "$(grep -c '^capture = ' "$conf")"
check 'the surviving value is the new one' 'wlr' "$(sunshine_conf_get capture)"

# --- a missing file is reported, not created -------------------------------

IVM_SUNSHINE_CONF=$tmpdir/does-not-exist.conf
result=0
sunshine_set_key capture wlr 2>/dev/null || result=$?
check 'a missing file is an error' 2 "$result"
check 'the file is not created' 0 "$([[ -e $tmpdir/does-not-exist.conf ]] && echo 1 || echo 0)"

printf '\n%d checks, %d failures\n' "$checks" "$failures"
((failures == 0))
