#!/bin/bash
# Local receipt/archive engine. Network handling is injected by native_adapter.sh.
# Never source receipt text as shell code. All public actions process ONE file.

: "${VTS_LOOT_DIR:=/root/loot/wigle}"
: "${VTS_ARCHIVE_DIR:=/root/loot/archive/wigle}"
: "${VTS_STATE_DIR:=/root/loot/.valleytech_wigle_upload}"
: "${VTS_LOCK_DIR:=/tmp/valleytech_wigle_upload.lock}"
: "${VTS_PROC_ROOT:=/proc}"
: "${VTS_MIN_AGE_SECONDS:=15}"
: "${VTS_STABILITY_SECONDS:=2}"
VTS_MESSAGE=''
VTS_LOCK_HELD=0

vts_fail() { VTS_MESSAGE=$2; return "$1"; }
vts_sha() { sha256sum -- "$1" | awk '{print $1}'; }
vts_name_key() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
vts_valid_sha() { [[ $1 =~ ^[a-f0-9]{64}$ ]]; }
vts_value() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }

vts_init() {
    umask 077
    [[ $VTS_LOOT_DIR == /* && $VTS_ARCHIVE_DIR == /* && $VTS_STATE_DIR == /* && $VTS_LOCK_DIR == /* ]] ||
        { vts_fail 20 'Local directories must be absolute paths.'; return; }
    mkdir -p -- "$VTS_STATE_DIR/receipts" "$VTS_STATE_DIR/snapshots" "$VTS_STATE_DIR/by-name" "$VTS_STATE_DIR/attempts" ||
        { vts_fail 20 'Cannot create local receipt storage.'; return; }
    VTS_LOOT_REAL=$(readlink -f -- "$VTS_LOOT_DIR") || return 20
    [[ -d $VTS_LOOT_REAL ]] || { vts_fail 20 'WiGLE log directory is unavailable.'; return; }
    local state_real
    state_real=$(readlink -f -- "$VTS_STATE_DIR") || return 20
    case "$state_real/" in "$VTS_LOOT_REAL/"*) vts_fail 20 'Receipts must be outside the pending-log directory.'; return;; esac
    [[ -d $VTS_PROC_ROOT ]] || { vts_fail 20 'Active-file inspection is unavailable.'; return; }
}

vts_lock() {
    if ! mkdir -- "$VTS_LOCK_DIR" 2>/dev/null; then
        vts_fail 21 'Another upload/recovery holds the lock. Do not remove a live lock. A stale /tmp lock clears on reboot.'
        return
    fi
    VTS_LOCK_HELD=1
    printf '%s\n' "$$" > "$VTS_LOCK_DIR/pid"
}

vts_unlock() {
    if [[ $VTS_LOCK_HELD == 1 ]]; then
        rm -f -- "$VTS_LOCK_DIR/pid"
        rmdir -- "$VTS_LOCK_DIR" 2>/dev/null || true
        VTS_LOCK_HELD=0
    fi
}

vts_run_locked() {
    vts_init || return $?
    vts_lock || return $?
    "$@"
    local result=$?
    vts_unlock
    return "$result"
}

vts_atomic_text() {
    local target=$1 content=$2 temp
    temp=$(mktemp "$VTS_STATE_DIR/.write.XXXXXX") || return 1
    if ! printf '%s\n' "$content" > "$temp" || ! sync || ! mv -- "$temp" "$target" || ! sync; then
        rm -f -- "$temp"
        return 1
    fi
}

vts_write_state() {
    local status=$1 hash=$2 name=$3 archive_name=${4:-}
    vts_valid_sha "$hash" || return 1
    vts_atomic_text "$VTS_STATE_DIR/receipts/$hash.state" \
        "status=$status
sha256=$hash
source_name=$name
archive_name=$archive_name
updated_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

vts_check_source() {
    local source=$1 real name
    [[ -f $source && ! -L $source ]] || { vts_fail 22 'Select a regular CSV file, not a symlink.'; return; }
    real=$(readlink -f -- "$source") || return 22
    name=${real##*/}
    [[ ${real%/*} == "$VTS_LOOT_REAL" && $name == *.csv && $name != *$'\n'* && $name != *$'\r'* ]] ||
        { vts_fail 22 'Select one CSV directly inside the WiGLE log directory.'; return; }
    VTS_SOURCE=$real
    VTS_SOURCE_NAME=$name
}

vts_is_open() {
    # Bash -ef compares device/inode itself, including symlink dereferencing.
    # Firmware 2.0.0 has no stat command or BusyBox stat applet.
    local source=$1 fd_dir fd
    [[ -f $source && ! -L $source ]] || return 0
    for fd_dir in "$VTS_PROC_ROOT"/[0-9]*/fd; do
        [[ -d $fd_dir ]] || continue
        for fd in "$fd_dir"/*; do
            [[ -L $fd ]] || continue
            [[ ! $source -ef $fd ]] || return 0
        done
    done
    return 1
}

vts_source_stable() {
    local source=$1 before after modified after_modified now
    vts_is_open "$source" && { vts_fail 23 'This log is open. Close/rotate capture before selecting it.'; return; }
    modified=$(date -r "$source" +%s) || { vts_fail 23 'Cannot read the log modification time; no upload was started.'; return; }
    now=$(date +%s) || return 23
    [[ $modified =~ ^[0-9]+$ && $now =~ ^[0-9]+$ ]] ||
        { vts_fail 23 'File time inspection returned invalid metadata.'; return; }
    (( now - modified >= VTS_MIN_AGE_SECONDS )) ||
        { vts_fail 23 'This log was recently modified. Wait until it is closed and stable.'; return; }
    before=$(vts_sha "$source") || return 23
    vts_valid_sha "$before" || return 23
    sleep "$VTS_STABILITY_SECONDS"
    after=$(vts_sha "$source") || return 23
    after_modified=$(date -r "$source" +%s) || return 23
    [[ $after_modified =~ ^[0-9]+$ && $before == "$after" && $modified == "$after_modified" ]] ||
        { vts_fail 23 'The log is changing; it was not uploaded.'; return; }
    vts_is_open "$source" && { vts_fail 23 'The log became active; it was not uploaded.'; return; }
    return 0
}

vts_same_filesystem() {
    # A successful exclusive hard link, verified with Bash -ef, positively
    # proves this regular file and target directory share a filesystem.
    local source=$1 directory=$2 probe result=1
    probe=$(mktemp -d "$directory/.vts-fs-probe.XXXXXX") || return 1
    if ln -- "$source" "$probe/check" 2>/dev/null && [[ $source -ef $probe/check ]]; then
        result=0
    fi
    rm -f -- "$probe/check"
    rmdir -- "$probe" 2>/dev/null || true
    return "$result"
}

vts_snapshot() {
    local source=$1 temp before after snapshot
    vts_check_source "$source" || return $?
    vts_source_stable "$VTS_SOURCE" || return $?
    before=$(vts_sha "$VTS_SOURCE") || return 22
    vts_valid_sha "$before" || return 22
    temp=$(mktemp "$VTS_STATE_DIR/snapshots/.copy.XXXXXX") || return 20
    if ! cp -- "$VTS_SOURCE" "$temp"; then rm -f -- "$temp"; vts_fail 20 'Cannot snapshot the selected log.'; return; fi
    after=$(vts_sha "$VTS_SOURCE") || after=''
    if [[ $before != "$after" || $(vts_sha "$temp") != "$before" ]] || vts_is_open "$VTS_SOURCE"; then
        rm -f -- "$temp"
        vts_fail 23 'The log changed during the snapshot; it was not uploaded.'
        return
    fi
    VTS_HASH=$before
    snapshot="$VTS_STATE_DIR/snapshots/$VTS_HASH.csv"
    if [[ -e $snapshot ]]; then
        [[ ! -L $snapshot && $(vts_sha "$snapshot") == "$VTS_HASH" ]] ||
            { rm -f -- "$temp"; vts_fail 20 'Stored snapshot failed its content check.'; return; }
    elif ! ln -- "$temp" "$snapshot"; then
        rm -f -- "$temp"; vts_fail 20 'Cannot commit local snapshot.'; return
    fi
    rm -f -- "$temp"
    VTS_SNAPSHOT=$snapshot
    VTS_NAME_KEY=$(vts_name_key "$VTS_SOURCE_NAME")
    if [[ -e $VTS_STATE_DIR/by-name/$VTS_NAME_KEY || -L $VTS_STATE_DIR/by-name/$VTS_NAME_KEY ]]; then
        local previous
        [[ -f $VTS_STATE_DIR/by-name/$VTS_NAME_KEY && ! -L $VTS_STATE_DIR/by-name/$VTS_NAME_KEY ]] ||
            { vts_fail 28 'Prior filename marker is damaged. Automatic retry is blocked.'; return; }
        previous=$(cat "$VTS_STATE_DIR/by-name/$VTS_NAME_KEY")
        [[ $previous == "$VTS_HASH" ]] ||
            { vts_fail 24 'This filename changed after a prior attempt. Reconcile it before uploading anything.'; return; }
    fi
}

vts_prepare_archive() {
    # Copy/reserve the entire archive candidate BEFORE the network request.
    # The hidden staged file is outside the pending CSV glob.
    local hash=$1 snapshot=$2 temp archive_real probe
    mkdir -p -- "$VTS_ARCHIVE_DIR" || { vts_fail 25 'Cannot create the archive directory.'; return; }
    archive_real=$(readlink -f -- "$VTS_ARCHIVE_DIR") || return 25
    [[ $archive_real != "$VTS_LOOT_REAL" ]] || { vts_fail 25 'Archive must differ from the pending-log directory.'; return; }
    probe=$(mktemp "$VTS_ARCHIVE_DIR/.vts-probe.XXXXXX") || { vts_fail 25 'Archive is not writable.'; return; }
    if ! printf 'preflight\n' > "$probe"; then rm -f -- "$probe"; vts_fail 25 'Archive write preflight failed.'; return; fi
    rm -f -- "$probe"
    VTS_ARCHIVE_STAGE="$VTS_ARCHIVE_DIR/.vts-pending-$hash"
    if [[ -e $VTS_ARCHIVE_STAGE ]]; then
        [[ ! -L $VTS_ARCHIVE_STAGE && $(vts_sha "$VTS_ARCHIVE_STAGE") == "$hash" ]] ||
            { vts_fail 25 'Archive staging collision; no upload was started.'; return; }
        return 0
    fi
    temp=$(mktemp "$VTS_ARCHIVE_DIR/.vts-copy.XXXXXX") || { vts_fail 25 'Archive is not writable.'; return; }
    if ! cp -- "$snapshot" "$temp" || [[ $(vts_sha "$temp") != "$hash" ]] || ! sync || ! ln -- "$temp" "$VTS_ARCHIVE_STAGE"; then
        rm -f -- "$temp"
        vts_fail 25 'Archive preflight/reservation failed; no upload was started.'
        return
    fi
    rm -f -- "$temp"
}

vts_commit_archive() {
    local hash=$1 name=$2 source=$3 dest="$VTS_ARCHIVE_DIR/$2" state hold_dir held
    state=$(vts_value "$VTS_STATE_DIR/receipts/$hash.state" status)
    [[ $state == uploaded || $state == archived ]] || { vts_fail 26 'No accepted receipt: archive-only recovery refused.'; return; }
    if [[ -e $dest || -L $dest ]]; then
        if [[ -L $dest || ! -f $dest || $(vts_sha "$dest") != "$hash" ]]; then
            dest="$VTS_ARCHIVE_DIR/$hash.csv"
        fi
    fi
    if [[ -e $dest || -L $dest ]]; then
        [[ ! -L $dest && -f $dest && $(vts_sha "$dest") == "$hash" ]] ||
            { vts_fail 27 'Archive name collision; accepted upload retained for archive-only recovery.'; return; }
    elif ! ln -- "$VTS_ARCHIVE_STAGE" "$dest"; then
        vts_fail 27 'Upload accepted but archive commit failed. Retry archive recovery, not upload.'; return
    fi
    [[ $(vts_sha "$dest") == "$hash" ]] || { vts_fail 27 'Archive verification failed; source retained.'; return; }
    vts_write_state archived "$hash" "$name" "${dest##*/}" ||
        { vts_fail 27 'Archive exists but receipt update failed; source retained.'; return; }
    # Never unlink a live pathname based on an earlier hash check. Atomically
    # rename it within its own filesystem, KEEP that original, then inspect it.
    # A writer racing this operation can keep writing its inode without data loss.
    if [[ -e $source ]]; then
        if [[ -L $source || $(vts_sha "$source") != "$hash" ]] || vts_is_open "$source"; then
            vts_fail 24 'Accepted snapshot archived; changed/active original retained. Do not re-upload it.'; return
        fi
        hold_dir="$VTS_LOOT_REAL/.valleytech-upload-originals"
        [[ ! -L $hold_dir ]] || { vts_fail 27 'Original hold directory is a symlink; source retained.'; return; }
        mkdir -p -- "$hold_dir" || { vts_fail 27 'Cannot retain original outside pending queue.'; return; }
        vts_same_filesystem "$source" "$hold_dir" ||
            { vts_fail 27 'Original hold must share the source filesystem; source retained.'; return; }
        held=$(mktemp "$hold_dir/$hash.original.XXXXXX") || return 27
        if ! mv -- "$source" "$held"; then
            rm -f -- "$held"
            vts_fail 27 'Archive verified; original move failed. No re-upload needed.'; return
        fi
        if [[ $(vts_sha "$held") != "$hash" ]] || vts_is_open "$held"; then
            vts_fail 24 'Snapshot archived; concurrent original data retained in the source-hold folder. Reconcile before upload.'; return
        fi
    fi
    rm -f -- "$VTS_ARCHIVE_STAGE" "$VTS_STATE_DIR/snapshots/$hash.csv"
    VTS_MESSAGE='Accepted snapshot archived; original retained outside the pending queue. No duplicate upload.'
}

vts_upload_impl() {
    local source=$1 acknowledgement=${2:-} state response result receipt
    vts_snapshot "$source" || return $?
    receipt="$VTS_STATE_DIR/receipts/$VTS_HASH.state"
    state=$(vts_value "$receipt" status)
    if [[ -e $receipt || -L $receipt ]]; then
        [[ -f $receipt && ! -L $receipt && $(vts_value "$receipt" sha256) == "$VTS_HASH" && ( $state == uncertain || $state == uploaded || $state == archived ) ]] ||
            { vts_fail 28 'Stored receipt is damaged/unknown. Reconcile history; automatic retry is blocked.'; return; }
    elif [[ -e $VTS_STATE_DIR/attempts/$VTS_HASH || -L $VTS_STATE_DIR/attempts/$VTS_HASH || -e $VTS_STATE_DIR/by-name/$VTS_NAME_KEY || -L $VTS_STATE_DIR/by-name/$VTS_NAME_KEY ]]; then
        vts_fail 28 'A prior attempt marker exists without its receipt. Automatic retry is blocked.'; return
    fi
    if [[ $state == uncertain ]]; then
        vts_fail 28 'Earlier upload outcome is uncertain. Reconcile WiGLE history; automatic retry is blocked.'; return
    fi
    vts_prepare_archive "$VTS_HASH" "$VTS_SNAPSHOT" || return $?
    if [[ $state == uploaded || $state == archived ]]; then
        vts_atomic_text "$VTS_STATE_DIR/by-name/$VTS_NAME_KEY" "$VTS_HASH" || return 20
        vts_commit_archive "$VTS_HASH" "$VTS_SOURCE_NAME" "$VTS_SOURCE"
        return $?
    fi
    [[ $acknowledgement == confirmed-not-previously-uploaded ]] ||
        { vts_fail 29 'Explicit confirmation that this file was not previously uploaded is required.'; return; }
    vts_adapter_ready || { vts_fail 78 'WiGLE login or native JSON/curl dependency is unavailable. No upload was started.'; return; }
    if [[ $(vts_sha "$VTS_SOURCE") != "$VTS_HASH" ]] || vts_is_open "$VTS_SOURCE"; then
        vts_fail 23 'Source became active/changed before upload. No upload was started.'; return
    fi
    vts_write_state uncertain "$VTS_HASH" "$VTS_SOURCE_NAME" ||
        { vts_fail 20 'Cannot persist attempt marker; no upload was started.'; return; }
    vts_atomic_text "$VTS_STATE_DIR/attempts/$VTS_HASH" "$VTS_HASH" ||
        { vts_fail 20 'Cannot persist content attempt marker; no upload was started.'; return; }
    vts_atomic_text "$VTS_STATE_DIR/by-name/$VTS_NAME_KEY" "$VTS_HASH" ||
        { vts_fail 20 'Cannot persist filename marker; no upload was started.'; return; }
    response="$VTS_STATE_DIR/receipts/$VTS_HASH.response.json"
    vts_native_upload "$VTS_SNAPSHOT" "$response"
    result=$?
    if (( result != 0 )); then
        vts_fail 28 'Upload acceptance is not confirmed. Automatic retry blocked; inspect/reconcile the receipt.'; return
    fi
    sync || { vts_fail 28 'Cannot flush upload receipt. Outcome held uncertain; do not retry upload.'; return; }
    vts_write_state uploaded "$VTS_HASH" "$VTS_SOURCE_NAME" ||
        { vts_fail 28 'Acceptance receipt could not be committed. Do not retry upload.'; return; }
    vts_commit_archive "$VTS_HASH" "$VTS_SOURCE_NAME" "$VTS_SOURCE"
}

vts_upload_one() { vts_run_locked vts_upload_impl "$@"; }

vts_recover_impl() {
    local hash=$1 state name archive_name snapshot source receipt
    vts_valid_sha "$hash" || return 22
    receipt="$VTS_STATE_DIR/receipts/$hash.state"
    [[ -f $receipt && ! -L $receipt && $(vts_value "$receipt" sha256) == "$hash" ]] ||
        { vts_fail 28 'Accepted receipt is missing or damaged. Recovery refused.'; return; }
    state=$(vts_value "$receipt" status)
    [[ $state == uploaded || $state == archived ]] || { vts_fail 28 'No confirmed acceptance. Recovery will not upload or guess.'; return; }
    name=$(vts_value "$VTS_STATE_DIR/receipts/$hash.state" source_name)
    [[ $name && $name != */* && $name != *$'\n'* && $name != *$'\r'* ]] || return 22
    source="$VTS_LOOT_REAL/$name"
    snapshot="$VTS_STATE_DIR/snapshots/$hash.csv"
    archive_name=$(vts_value "$VTS_STATE_DIR/receipts/$hash.state" archive_name)
    if [[ ! -f $snapshot && $archive_name && $archive_name != */* && -f $VTS_ARCHIVE_DIR/$archive_name ]]; then
        snapshot="$VTS_ARCHIVE_DIR/$archive_name"
    fi
    [[ -f $snapshot && ! -L $snapshot && $(vts_sha "$snapshot") == "$hash" ]] ||
        { vts_fail 27 'Accepted snapshot unavailable or damaged; source left untouched.'; return; }
    vts_prepare_archive "$hash" "$snapshot" || return $?
    vts_commit_archive "$hash" "$name" "$source"
}

vts_recover_receipt() { vts_run_locked vts_recover_impl "$@"; }

vts_archive_confirmed_impl() {
    local source=$1 acknowledgement=${2:-}
    [[ $acknowledgement == confirmed-previously-uploaded ]] ||
        { vts_fail 29 'Confirm prior acceptance from WiGLE history before archive-only recovery.'; return; }
    vts_snapshot "$source" || return $?
    vts_prepare_archive "$VTS_HASH" "$VTS_SNAPSHOT" || return $?
    vts_atomic_text "$VTS_STATE_DIR/by-name/$VTS_NAME_KEY" "$VTS_HASH" || return 20
    vts_atomic_text "$VTS_STATE_DIR/attempts/$VTS_HASH" "$VTS_HASH" || return 20
    vts_atomic_text "$VTS_STATE_DIR/receipts/$VTS_HASH.manual.txt" 'Prior acceptance explicitly confirmed by the user; no network request made.' || return 20
    vts_write_state uploaded "$VTS_HASH" "$VTS_SOURCE_NAME" || return 20
    vts_commit_archive "$VTS_HASH" "$VTS_SOURCE_NAME" "$VTS_SOURCE"
}

vts_archive_confirmed() { vts_run_locked vts_archive_confirmed_impl "$@"; }
