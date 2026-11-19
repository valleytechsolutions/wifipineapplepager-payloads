#!/bin/bash
# Uses the same on-device credential store as firmware 2.0.0 WIGLE_UPLOAD.
# Credentials never leave this device except as HTTP Basic auth to WiGLE.
# The stock helper does not expose its JSON receipt and can return success after
# errors; do not interpret its human-readable messages as upload acceptance.

vts_adapter_ready() {
    command -v curl >/dev/null && command -v PAYLOAD_GET_CONFIG >/dev/null || return 1
    if ! declare -F json_load >/dev/null; then
        [[ -r /usr/share/libubox/jshn.sh ]] || return 1
        . /usr/share/libubox/jshn.sh || return 1
    fi
    VTS_AUTHNAME=$(PAYLOAD_GET_CONFIG wigle authname 2>/dev/null) || return 1
    VTS_TOKEN=$(PAYLOAD_GET_CONFIG wigle token 2>/dev/null) || { unset VTS_AUTHNAME; return 1; }
    [[ $VTS_AUTHNAME && $VTS_TOKEN && $VTS_AUTHNAME != *$'\n'* && $VTS_AUTHNAME != *$'\r'* && $VTS_TOKEN != *$'\n'* && $VTS_TOKEN != *$'\r'* ]] ||
        { unset VTS_AUTHNAME VTS_TOKEN; return 1; }
}

vts_accept_response() {
    local response=$1 type accepted keys key transid size
    [[ -f $response && ! -L $response ]] || return 1
    size=$(wc -c < "$response") || return 1
    [[ $size =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || return 1
    (( size > 0 && size <= 131072 )) || return 1
    json_init || return 1
    json_load "$(cat -- "$response")" || return 1
    json_get_type type success || return 1
    json_get_var accepted success || return 1
    [[ $type == boolean && $accepted == 1 ]] || return 1
    json_get_type type results || return 1
    [[ $type == object ]] || return 1
    json_select results || return 1
    json_get_type type transids || return 1
    [[ $type == array ]] || return 1
    json_select transids || return 1
    json_get_keys keys || return 1
    [[ $keys ]] || return 1
    # Official schema spells this transId, not transid. Require at least one
    # nonempty transaction identifier and reject malformed entries.
    for key in $keys; do
        json_get_type type "$key" || return 1
        [[ $type == object ]] || return 1
        json_select "$key" || return 1
        json_get_type type transId || return 1
        json_get_var transid transId || return 1
        [[ $type == string && $transid && $transid != *$'\n'* && $transid != *$'\r'* ]] || return 1
        json_select .. || return 1
    done
    return 0
}

vts_native_upload() {
    local snapshot=$1 response=$2 rc status auth
    [[ $VTS_AUTHNAME && $VTS_TOKEN ]] || return 78
    auth="$VTS_AUTHNAME:$VTS_TOKEN"
    auth=${auth//\\/\\\\}; auth=${auth//\"/\\\"}
    # Pass auth on stdin, never argv/logs; no redirects or automatic curl retries.
    # Limit response storage even on curl builds whose --max-filesize only
    # checks Content-Length. A limit/timeout is uncertain and MUST NOT resend.
    status=$(
        ulimit -f 256 || exit 78
        printf 'user = "%s"\n' "$auth" |
            curl -q --config - --basic --silent --show-error --request POST \
                --connect-timeout 15 --max-time 180 --max-filesize 131072 \
                --header 'accept: application/json' \
                --form "file=@$snapshot;type=text/csv" --form 'donate=on' \
                --output "$response" --write-out '%{http_code}' \
                'https://api.wigle.net/api/v2/file/upload' 2> "$response.stderr"
    )
    rc=$?
    unset VTS_AUTHNAME VTS_TOKEN auth
    printf '%s\n' "$status" > "$response.http-status" || return 78
    (( rc == 0 )) || return "$rc"
    [[ $status == 200 ]] || return 78
    vts_accept_response "$response"
}
