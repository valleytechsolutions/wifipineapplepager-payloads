#!/bin/bash
# Title: Valleytech WiGLE Upload
# Description: Confirm one closed log, upload with a receipt, and recover archives without re-uploading
# Author: Valleytech Solutions
# Version: 0.1.0
# Category: Exfiltration

# Launch is local-only. No login, network probe, batch upload or capture changes.
. "${VTS_COMMANDS_LIBRARY:-/lib/hak5/commands.sh}" || exit 78
# The native runner copies this entry script into /tmp but keeps the installed
# payload directory as its working directory. Direct/development runs retain
# adjacent libraries. Require both files in whichever directory is selected.
VTS_PAYLOAD_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P) || VTS_PAYLOAD_DIR=''
if [[ ! -r $VTS_PAYLOAD_DIR/lib/wigle_safe.sh || ! -r $VTS_PAYLOAD_DIR/lib/native_adapter.sh ]]; then
    VTS_PAYLOAD_DIR=$(pwd -P) || exit 1
fi
if [[ ! -r $VTS_PAYLOAD_DIR/lib/wigle_safe.sh || ! -r $VTS_PAYLOAD_DIR/lib/native_adapter.sh ]]; then
    ERROR_DIALOG 'Valleytech companion libraries are missing. Reinstall the complete payload folder.'
    exit 1
fi
. "$VTS_PAYLOAD_DIR/lib/wigle_safe.sh" || exit 1
. "$VTS_PAYLOAD_DIR/lib/native_adapter.sh" || exit 1
trap 'vts_unlock' EXIT
trap 'exit 130' INT TERM HUP

vts_ui_finish() {
    local result=$1
    if (( result == 0 )); then
        LOG green "$VTS_MESSAGE"
    else
        LOG yellow "$VTS_MESSAGE"
        ERROR_DIALOG "$VTS_MESSAGE"
    fi
    exit "$result"
}

vts_ui_file() {
    local file label selected index=0
    local -a labels=(Cancel) paths=('')
    for file in "$VTS_LOOT_DIR"/*.csv; do
        [[ -f $file && ! -L $file ]] || continue
        label=${file##*/}
        [[ $label != *$'\n'* && $label != *$'\r'* ]] || continue
        ((index+=1))
        labels+=("$index: $label")
        paths+=("$file")
    done
    if (( index == 0 )); then
        VTS_MESSAGE='No pending CSV files. Capture settings were not changed.'
        vts_ui_finish 0
    fi
    selected=$(LIST_PICKER 'Choose one closed log' "${labels[@]}" Cancel) || exit 0
    for ((index=1; index<${#labels[@]}; index++)); do
        if [[ $selected == "${labels[index]}" ]]; then
            VTS_SELECTED_FILE=${paths[index]}
            return 0
        fi
    done
    exit 0
}

vts_ui_recover() {
    local file hash state name choice index=0
    local -a labels=(Cancel) hashes=('')
    for file in "$VTS_STATE_DIR/receipts"/*.state; do
        [[ -f $file && ! -L $file ]] || continue
        hash=${file##*/}; hash=${hash%.state}
        vts_valid_sha "$hash" || continue
        state=$(vts_value "$file" status)
        [[ $state == uploaded || $state == archived ]] || continue
        name=$(vts_value "$file" source_name)
        ((index+=1))
        labels+=("$index: ${hash:0:10} $name")
        hashes+=("$hash")
    done
    if (( index == 0 )); then
        VTS_MESSAGE='No accepted receipts to recover. Uncertain uploads require checking WiGLE history; they are never resent automatically.'
        vts_ui_finish 0
    fi
    choice=$(LIST_PICKER 'Retry archive' "${labels[@]}" Cancel) || exit 0
    for ((index=1; index<${#labels[@]}; index++)); do
        if [[ $choice == "${labels[index]}" ]]; then
            vts_recover_receipt "${hashes[index]}"
            vts_ui_finish $?
        fi
    done
    exit 0
}

choice=$(LIST_PICKER 'Valleytech WiGLE' 'Upload new log' 'Retry archive' 'Archive prior upload' Cancel Cancel) || exit 0
case "$choice" in
    'Upload new log')
        vts_ui_file
        # Existing legacy logs have no local proof that stock Toolkit uploaded
        # them already. The user must reconcile these before this confirmation.
        LOG blue "Selected file: ${VTS_SELECTED_FILE##*/}"
        response=$(CONFIRMATION_DIALOG "${VTS_SELECTED_FILE##*/}
Send Wi-Fi, Bluetooth and GPS to WiGLE?
Only proceed if never uploaded.") || exit 0
        [[ $response == 1 ]] || exit 0
        choice=$(LIST_PICKER 'Upload to WiGLE?' Cancel 'New log: upload once' Cancel) || exit 0
        [[ $choice == 'New log: upload once' ]] || exit 0
        LOG blue 'Checking closed log, archive space and local receipt...'
        vts_upload_one "$VTS_SELECTED_FILE" confirmed-not-previously-uploaded
        vts_ui_finish $?
        ;;
    'Retry archive')
        vts_ui_recover
        ;;
    'Archive prior upload')
        vts_ui_file
        LOG blue "Selected file: ${VTS_SELECTED_FILE##*/}"
        response=$(CONFIRMATION_DIALOG "${VTS_SELECTED_FILE##*/}
WiGLE history confirms this exact file?
Archive locally; no upload.") || exit 0
        [[ $response == 1 ]] || exit 0
        choice=$(LIST_PICKER 'Archive only?' Cancel 'Confirmed: archive' Cancel) || exit 0
        [[ $choice == 'Confirmed: archive' ]] || exit 0
        vts_archive_confirmed "$VTS_SELECTED_FILE" confirmed-previously-uploaded
        vts_ui_finish $?
        ;;
esac
exit 0
