# Valleytech WiGLE Upload

Companion payload for the Valleytech Theme shortcut. Install this folder at
`/root/payloads/user/exfiltration/valleytech_wigle_upload`. The theme manifest
registers `wigle_upload` as that directory and links to the firmware-generated
`execute_payload_wigle_upload` action. Launch shows a local menu with Cancel
selected. It does not upload, probe the network, log in, or change capture.

The native payload runner copies the entry script into `/tmp` while retaining
the installed payload folder as its working directory. The entry script checks
for both companion libraries beside its own path, then checks the actual working
directory. A partial installation fails before any menu action or upload.

## Use

1. Close or rotate the selected capture log. Wait at least 15 seconds after its
   last modification. Open file descriptors and changing files are rejected.
2. For existing logs left after a failed stock Toolkit archive, check your WiGLE
   upload history first. These files may already have been accepted. Select
   **Archive prior upload** only after confirming acceptance; it makes no request.
3. For a file known never to have been uploaded, choose **Upload new log** and
   select the file. Read the native confirmation showing the filename and that
   WiFi/Bluetooth observations and GPS are sent to WiGLE. After accepting that
   disclosure, explicitly choose **New log: upload once** in the final menu,
   whose default is Cancel. The existing native WiGLE login is reused.
4. If the upload has a confirmed receipt but moving it into the archive failed,
   choose **Retry archive**. This only repairs local files. The four-entry main
   menu fits the native picker's four rows with Cancel visible and selected.

WiGLE API credentials are fetched by `PAYLOAD_GET_CONFIG wigle authname` and
`PAYLOAD_GET_CONFIG wigle token` only after explicit upload confirmation. They
stay in the device process and are supplied to curl over stdin; they are not
printed, stored in receipts, passed in curl's command line, changed, or exported
to the computer. The backend posts to the same WiGLE API and uses `donate=on`,
matching the current firmware helper.

## Receipt and archive behavior

- One process holds an atomic local lock. It checks the selected file for open
  descriptors, recent edits, stable modification times, and matching hashes before and
  after copying an immutable snapshot.
- A complete archive copy and a writable-directory probe occur before the
  request. Local state lives outside the stock `wigle/*.csv` upload glob.
- A durable `uncertain` receipt, content-hash attempt marker, and filename marker
  are written before sending. The content marker survives a missing receipt and
  still blocks the same data under a new filename.
  HTTP 200 alone is insufficient: a bounded JSON response must have boolean
  `success: true`, a results object, and nonempty `transids` with string
  `transId` values. Confirmed acceptance is recorded before archive operations.
- Transport failure, timeout, invalid JSON, or an unconfirmed response remains
  uncertain. No automatic resend occurs, even if a later call uses the same
  content under another filename. Damaged receipts and missing receipts with
  surviving attempt markers also block automatic resend.
- Archive retries use the accepted snapshot and never send another request.
  Existing files are not overwritten; a content-hash filename resolves a name
  collision. Changed content under a previously attempted filename is blocked.
- The accepted snapshot goes into `/root/loot/archive/wigle`. The original is
  atomically moved into `/root/loot/wigle/.valleytech-upload-originals` and
  retained. It is never deleted after a potentially stale hash/open-file check.
  A racing writer can continue its inode without losing new observations.
  Changed/active originals are retained and require reconciliation. This
  conservative retention uses extra storage and requires eventual manual
  cleanup after the data and writer state have been checked.

Firmware 2.0.0 on this Pager does not provide the external `stat` command or its
BusyBox applet. This payload uses Bash's built-in `-ef` inode/device comparison
for `/proc` descriptors, `date -r` for modification time, `wc -c` for response
size, and a positively verified temporary hard link for same-filesystem moves.
Missing or invalid metadata fails closed; two empty tool outputs are never
treated as a successful filesystem comparison.

Receipts: `/root/loot/.valleytech_wigle_upload/receipts`.
Lock: `/tmp/valleytech_wigle_upload.lock`. A live lock must not be removed.
A stale lock after an abrupt process termination clears on reboot; uncertain
receipts persist. Do not erase receipts to force a retry.

This prevents ordinary repeat uploads through this companion after known
acceptance or an uncertain attempt. It cannot guarantee exactly-once delivery:
WiGLE provides no documented idempotency key, and a network failure can happen
after the server accepted data. WiGLE history lacks a content hash. Legacy
uploads, changed/renamed copies, erased local state, or uploads from other tools
require manual reconciliation. No automated history matching is claimed.

## Why a separate backend

The actual firmware 2.0.0 `WIGLE_UPLOAD` inspected on this Pager correctly sets
`/root/loot/archive/wigle`; the historic unset-directory bug is already fixed.
Its underlying archive failure on the user's files has not been established.
However, the helper prints human-readable output, defaults its success value
before JSON parsing, and can finish without reporting failures via a nonzero
exit code. It does not expose the accepted JSON receipt. This payload therefore
uses an isolated strict backend with the same native credential store rather
than changing the system `WIGLE_UPLOAD` helper or treating its output as proof.
The old Toolkit and native helper remain unchanged. Curl's default configuration
is disabled so a user's `.curlrc` cannot silently enable redirects or retries.

## Validation limits and sources

Offline tests use synthetic CSVs, a synthetic `/proc` tree, and stubbed upload
functions. They cover duplicate prevention, uncertain outcomes, receipt loss,
archive failures/collisions, source races, local locking and cancellation. Host
tests cannot prove power-loss durability or actual firmware/API behavior. Any
real-service acceptance test requires a deliberately selected new log; no such
upload has been performed during development. The host JSON tests use a Python
bridge that models jshn's interface, so they do not validate the device's actual
libubox parser or kernel file-size limits.

Run host tests with `python -m unittest discover -s tests -v`. A separate
`tests/offline_on_pager.sh` needs Bash and the Pager's existing native jshn, but no
Python. Run it with `bash tests/offline_on_pager.sh --persistent-fixtures` to
exercise native JSON parsing, real `/proc` open-inode
detection, hard-link/rename compatibility and archive-only recovery. It creates
only synthetic files in a unique `/root/.valleytech-wigle-offline.*` directory,
checks that its filesystem matches the real log/archive directories using
directory metadata only, overrides curl and config access before loading the
implementation, and cleans up its own exact test directory. Without the option,
it uses `/tmp` and does not establish persistent-storage compatibility.
It never calls the stock helper, reads real credentials, or sends a request.

The corrected persistent-fixture run on the actual Pager passed **23 checks
with zero failures**, covering native jshn, real storage, active-file detection,
archive recovery and blocked repeat attempts. The final host suite ran **39
tests: 38 passed and one Windows symlink fixture was skipped**; the real `/proc`
inode behavior passed on the device instead.

The actual Pager's **Wardriving > Upload & Archive > Launch** route opened the
Valleytech WiGLE picker with all four rows visible and Cancel preselected.
Pressing A on Cancel ended with the native completed checkmark and no error.
The temporary launch diagnostics were removed. These observations came from
the actual device through Virtual Pager. No real upload or archive action was
performed during this menu test; no real API acceptance, processing, or score
change has been tested or claimed.

- [Hak5 WiGLE commands](https://documentation.hak5.org/wifi-pineapple-pager/wifi-pineapple-commands/wigle)
- [Official WiGLE Toolkit](https://github.com/hak5/wifipineapplepager-payloads/blob/b7e7604d0716d5eba7f97d7c91b3c2844d0e8961/library/user/exfiltration/wigle-toolkit/payload.sh)
- [Fixed historical archive issue](https://github.com/hak5/wifipineapplepager/issues/28)
- [WiGLE API schema](https://api.wigle.net/swagger.json)
- [LIST_PICKER contract](https://documentation.hak5.org/wifi-pineapple-pager/list_picker)

This implementation was written for Valleytech Solutions; its workflow and
credential compatibility were checked against the official Hak5 Toolkit by mik
and the firmware 2.0.0 helper. It does not copy authentication data.
