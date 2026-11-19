#!/bin/bash
# OFFLINE synthetic self-test. No real WiGLE credentials or requests are used.
# Run: bash /root/payloads/user/exfiltration/valleytech_wigle_upload/tests/offline_on_pager.sh --persistent-fixtures
# Real jshn, /proc, cp, date, hard links, atomic rename and archive recovery are used.
# Match the production payload's shell options; the native jshn library may
# legitimately reference unset optional variables.
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
case "${1:-}" in
    '') TEST_TEMPLATE=/tmp/valleytech-wigle-offline.XXXXXX;;
    --persistent-fixtures) TEST_TEMPLATE=/root/.valleytech-wigle-offline.XXXXXX;;
    *) printf 'Usage: %s [--persistent-fixtures]\n' "$0" >&2; exit 2;;
esac
(( $# <= 1 )) || exit 2
TEST_ROOT=$(mktemp -d "$TEST_TEMPLATE") || exit 1
case "$TEST_ROOT" in /tmp/valleytech-wigle-offline.*|/root/.valleytech-wigle-offline.*) ;; *) exit 1;; esac
[[ -d $TEST_ROOT && ! -L $TEST_ROOT ]] || exit 1
TEST_PASSED=0
TEST_FAILED=0
cleanup() {
    vts_unlock 2>/dev/null || true
    # Only our exact mktemp result under either fixed permitted prefix.
    case "$TEST_ROOT" in /tmp/valleytech-wigle-offline.*|/root/.valleytech-wigle-offline.*) rm -rf -- "$TEST_ROOT";; esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# Define guards BEFORE sourcing code. The stock helper and config command are
# never invoked; every curl call is this synthetic function, not an executable.
PAYLOAD_GET_CONFIG() {
    case "${2:-}" in authname) printf 'OFFLINE-SYNTHETIC-NAME';; token) printf 'OFFLINE-SYNTHETIC-TOKEN';; *) return 1;; esac
}
WIGLE_UPLOAD() { printf 'FAIL: stock helper must never be called\n' >&2; return 99; }
curl() {
    local dest='' first=${1:-}
    [[ $first == -q ]] || return 99
    cat >/dev/null
    while (( $# )); do
        if [[ $1 == --output ]]; then dest=$2; shift; fi
        shift
    done
    [[ $dest == "$TEST_ROOT/"* ]] || return 99
    printf '%s\n' "$TEST_BODY" > "$dest" || return 99
    printf '%s' "$TEST_HTTP"
    return "$TEST_CURL_RC"
}
. "$TEST_DIR/../lib/wigle_safe.sh" || exit 1
. "$TEST_DIR/../lib/native_adapter.sh" || exit 1
# Genuine firmware library, with no /lib/hak5/commands.sh or stored credentials.
[[ -r /usr/share/libubox/jshn.sh ]] || { printf 'FAIL: native jshn unavailable\n'; exit 1; }
. /usr/share/libubox/jshn.sh || exit 1
eval "$(declare -f vts_native_upload | sed '1s/vts_native_upload/vts_real_native_upload/')"
eval "$(declare -f vts_commit_archive | sed '1s/vts_commit_archive/vts_real_commit_archive/')"
vts_native_upload() {
    TEST_UPLOAD_CALLS=$((TEST_UPLOAD_CALLS + 1))
    printf '%s\n' "$TEST_VALID_JSON" > "$2"
    return "$TEST_UPLOAD_RC"
}
vts_commit_archive() {
    (( TEST_FAIL_ARCHIVE == 0 )) || return 27
    vts_real_commit_archive "$@"
}
vts_adapter_ready() {
    # Synthetic configuration only; native dependency/JSON behavior tested below.
    VTS_AUTHNAME=OFFLINE-SYNTHETIC-NAME
    VTS_TOKEN=OFFLINE-SYNTHETIC-TOKEN
}

pass() { TEST_PASSED=$((TEST_PASSED+1)); printf 'PASS: %s\n' "$1"; }
fail() { TEST_FAILED=$((TEST_FAILED+1)); printf 'FAIL: %s\n' "$1"; }
expect_rc() {
    local expected=$1 label=$2 actual
    shift 2
    "$@"; actual=$?
    if (( actual == expected )); then pass "$label"; else fail "$label (expected $expected, got $actual)"; fi
}
filesystem_name() {
    local output name
    output=$(df -P "$1") || return 1
    name=$(printf '%s\n' "$output" | awk 'NR == 2 {print $1}') || return 1
    [[ $name && $name != *$'\n'* && $name != *$'\r'* ]] || return 1
    printf '%s' "$name"
}
fresh() {
    VTS_LOOT_DIR="$TEST_ROOT/$1/loot"
    VTS_ARCHIVE_DIR="$TEST_ROOT/$1/archive"
    VTS_STATE_DIR="$TEST_ROOT/$1/state"
    VTS_LOCK_DIR="$TEST_ROOT/$1/lock"
    VTS_PROC_ROOT=/proc
    VTS_MIN_AGE_SECONDS=0
    VTS_STABILITY_SECONDS=0
    TEST_UPLOAD_CALLS=0
    TEST_UPLOAD_RC=0
    TEST_FAIL_ARCHIVE=0
    mkdir -p -- "$VTS_LOOT_DIR"
    TEST_SOURCE="$VTS_LOOT_DIR/offline fixture.csv"
    printf 'WigleWifi-1.6,offline fixture\nMAC,SSID,FirstSeen\n00:00:00:00:00:01,SYNTHETIC,2020-01-01\n' > "$TEST_SOURCE"
    TEST_HASH=$(vts_sha "$TEST_SOURCE")
}
TEST_VALID_JSON='{"success":true,"results":{"transids":[{"transId":"OFFLINE-FIXTURE-ONLY"}]}}'
TEST_BODY=$TEST_VALID_JSON
TEST_HTTP=200
TEST_CURL_RC=0

printf 'Valleytech offline self-test: synthetic data, stubbed network/config only\n'
if (df() { return 127; }; filesystem_name "$TEST_ROOT") >/dev/null 2>&1; then
    fail 'missing filesystem tool rejected'
else pass 'missing filesystem tool rejected'; fi
if (df() { return 0; }; filesystem_name "$TEST_ROOT") >/dev/null 2>&1; then
    fail 'empty filesystem metadata rejected'
else pass 'empty filesystem metadata rejected'; fi
if [[ ${1:-} == --persistent-fixtures ]]; then
    fixture_filesystem=$(filesystem_name "$TEST_ROOT") || fixture_filesystem=''
    for real_directory in /root/loot/wigle /root/loot/archive/wigle; do
        actual_filesystem=$(filesystem_name "$real_directory") || actual_filesystem=''
        if [[ -d $real_directory && $fixture_filesystem && $actual_filesystem && $actual_filesystem == "$fixture_filesystem" ]]; then
            pass "fixture filesystem matches $real_directory"
        else
            fail "fixture filesystem does not match $real_directory; storage compatibility not proven"
        fi
    done
fi
printf '%s\n' "$TEST_VALID_JSON" > "$TEST_ROOT/valid.json"
expect_rc 0 'native jshn accepts explicit true and transaction ID' vts_accept_response "$TEST_ROOT/valid.json"
printf '{broken\n' > "$TEST_ROOT/bad.json"
if vts_accept_response "$TEST_ROOT/bad.json" 2>/dev/null; then fail 'malformed JSON rejected'; else pass 'malformed JSON rejected'; fi
printf '{"success":"true","results":{"transids":[{"transId":"x"}]}}\n' > "$TEST_ROOT/bad.json"
if vts_accept_response "$TEST_ROOT/bad.json"; then fail 'string success rejected'; else pass 'string success rejected'; fi
printf '{"success":true,"results":{"transids":[]}}\n' > "$TEST_ROOT/bad.json"
if vts_accept_response "$TEST_ROOT/bad.json"; then fail 'empty transactions rejected'; else pass 'empty transactions rejected'; fi

fresh native
vts_adapter_ready
expect_rc 0 'isolated backend uses stub curl and real jshn' vts_real_native_upload "$TEST_SOURCE" "$TEST_ROOT/native-response.json"
vts_adapter_ready
TEST_CURL_RC=28
expect_rc 28 'transport ambiguity remains failure even with valid body' vts_real_native_upload "$TEST_SOURCE" "$TEST_ROOT/native-response.json"
TEST_CURL_RC=0

fresh archive
expect_rc 0 'synthetic upload archived with receipt' vts_upload_one "$TEST_SOURCE" confirmed-not-previously-uploaded
if [[ ! -e $TEST_SOURCE && -f $VTS_ARCHIVE_DIR/'offline fixture.csv' && $TEST_UPLOAD_CALLS == 1 ]]; then
    pass 'archive created and pending file retired once'
else fail 'archive created and pending file retired once'; fi
held=("$VTS_LOOT_DIR/.valleytech-upload-originals"/*)
if [[ ${#held[@]} == 1 && $(vts_sha "${held[0]}") == "$TEST_HASH" ]]; then pass 'original retained byte-for-byte'; else fail 'original retained byte-for-byte'; fi

fresh recovery
TEST_FAIL_ARCHIVE=1
expect_rc 27 'accepted upload can survive archive failure' vts_upload_one "$TEST_SOURCE" confirmed-not-previously-uploaded
TEST_FAIL_ARCHIVE=0
expect_rc 0 'archive-only retry recovers accepted snapshot' vts_recover_receipt "$TEST_HASH"
if [[ $TEST_UPLOAD_CALLS == 1 ]]; then pass 'recovery made no second upload call'; else fail 'recovery made no second upload call'; fi

fresh uncertain
TEST_UPLOAD_RC=28
expect_rc 28 'uncertain upload recorded' vts_upload_one "$TEST_SOURCE" confirmed-not-previously-uploaded
TEST_UPLOAD_RC=0
expect_rc 28 'uncertain upload retry blocked' vts_upload_one "$TEST_SOURCE" confirmed-not-previously-uploaded
rm -f -- "$VTS_STATE_DIR/receipts/$TEST_HASH.state"
mv -- "$TEST_SOURCE" "$VTS_LOOT_DIR/renamed.csv"
expect_rc 28 'missing receipt plus renamed content still blocked' vts_upload_one "$VTS_LOOT_DIR/renamed.csv" confirmed-not-previously-uploaded
if [[ $TEST_UPLOAD_CALLS == 1 ]]; then pass 'content marker prevented duplicate'; else fail 'content marker prevented duplicate'; fi

fresh active
if ln -- "$TEST_SOURCE" "$TEST_ROOT/open-alias"; then pass 'filesystem supports exclusive hard-link commits'; else fail 'filesystem supports exclusive hard-link commits'; fi
exec 9< "$TEST_ROOT/open-alias"
expect_rc 23 'real /proc detects open inode through hard link' vts_upload_one "$TEST_SOURCE" confirmed-not-previously-uploaded
exec 9<&-
if [[ $TEST_UPLOAD_CALLS == 0 ]]; then pass 'active file made no upload call'; else fail 'active file made no upload call'; fi

printf 'RESULT: %s passed, %s failed; no real credentials or network used\n' "$TEST_PASSED" "$TEST_FAILED"
(( TEST_FAILED == 0 ))
