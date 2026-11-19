"""No network: curl/config/menu are shell stubs; JSON uses a jshn fixture bridge."""
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_wigle_safe import BASH, ROOT, q, unix


VALID = {'success': True, 'results': {'transids': [{'transId': 'OFFLINE-TEST-ONLY'}]}}

JSHN_SHIM = r'''
declare -A MOCK_TYPE MOCK_VALUE MOCK_CHILD MOCK_KEYS MOCK_PARENT
json_init() { MOCK_TYPE=(); MOCK_VALUE=(); MOCK_CHILD=(); MOCK_KEYS=(); MOCK_PARENT=(); MOCK_NODE=n0; }
json_load() { local code; code=$(printf '%s' "$1" | "$FIXTURE_PYTHON" "$FIXTURE_BRIDGE") || return 1; eval "$code"; }
json_get_type() { [[ -v MOCK_TYPE[$MOCK_NODE:$2] ]] || return 1; printf -v "$1" '%s' "${MOCK_TYPE[$MOCK_NODE:$2]}"; }
json_get_var() { [[ -v MOCK_VALUE[$MOCK_NODE:$2] ]] || return 1; printf -v "$1" '%s' "${MOCK_VALUE[$MOCK_NODE:$2]}"; }
json_get_keys() { printf -v "$1" '%s' "${MOCK_KEYS[$MOCK_NODE]}"; }
json_select() {
    if [[ $1 == .. ]]; then MOCK_NODE=${MOCK_PARENT[$MOCK_NODE]}; return 0; fi
    [[ -v MOCK_CHILD[$MOCK_NODE:$1] ]] || return 1
    MOCK_NODE=${MOCK_CHILD[$MOCK_NODE:$1]}
}
'''


class NativeAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vts-native-offline-')
        self.root = Path(self.temp.name)
        self.response = self.root/'response.json'
        self.fixture = self.root/'fixture.json'
        self.snapshot = self.root/'snapshot.csv'
        self.snapshot.write_text('SYNTHETIC CSV ONLY\n')

    def tearDown(self):
        self.temp.cleanup()

    def run_backend(self, body=VALID, status='200', curl_rc=0, prefix=''):
        self.fixture.write_text(body if isinstance(body,str) else json.dumps(body),encoding='utf-8')
        script = '\n'.join([
            'export PATH=/usr/bin:/bin',
            f'FIXTURE_PYTHON={q(unix(sys.executable))}',
            f'FIXTURE_BRIDGE={q(unix(ROOT/"tests/json_fixture_bridge.py"))}',
            f'FIXTURE_BODY={q(unix(self.fixture))}',
            f'FIXTURE_CAPTURE={q(unix(self.root/"curl-capture"))}',
            f'FIXTURE_STATUS={q(status)}',
            f'FIXTURE_RC={curl_rc}',
            f'source {q(unix(ROOT/"lib/native_adapter.sh"))}',
            JSHN_SHIM,
            # Git Bash cannot set Linux RLIMIT_FSIZE. The parser's explicit
            # byte limit is tested; kernel write limiting requires the Pager.
            r'''ulimit() { return 0; }
PAYLOAD_GET_CONFIG() { case "$2" in authname) printf 'TEST-NAME';; token) printf 'TEST-TOKEN';; *) return 1;; esac; }
curl() {
    local arg destination last
    printf '%s\n' "$@" > "$FIXTURE_CAPTURE.argv"
    cat > "$FIXTURE_CAPTURE.stdin"
    while (( $# )); do
        if [[ $1 == --output ]]; then destination=$2; shift; fi
        shift
    done
    cp -- "$FIXTURE_BODY" "$destination"
    printf '%s' "$FIXTURE_STATUS"
    return "$FIXTURE_RC"
}''',
            prefix,
            f'vts_adapter_ready && vts_native_upload {q(unix(self.snapshot))} {q(unix(self.response))}',
            'rc=$?; printf "RESULT:%s\\n" "$rc"',
            '[[ -z $VTS_AUTHNAME && -z $VTS_TOKEN ]] && printf "AUTH:CLEARED\\n"',
        ])
        result = subprocess.run([BASH,'--noprofile','--norc','-c',script],capture_output=True,text=True,timeout=20)
        match = re.search(r'RESULT:(\d+)',result.stdout)
        self.assertIsNotNone(match,result.stdout+result.stderr)
        return int(match.group(1)),result.stdout+result.stderr

    def test_valid_acceptance_and_private_auth_transport(self):
        rc,out=self.run_backend(); self.assertEqual(rc,0,out)
        self.assertIn('AUTH:CLEARED',out)
        argv=(self.root/'curl-capture.argv').read_text()
        self.assertEqual(argv.splitlines()[0],'-q')
        self.assertNotIn('TEST-NAME',argv); self.assertNotIn('TEST-TOKEN',argv)
        self.assertNotIn('--retry',argv); self.assertNotIn('--location',argv)
        self.assertIn('user = "TEST-NAME:TEST-TOKEN"',(self.root/'curl-capture.stdin').read_text())
        self.assertEqual(self.response.read_text(),self.fixture.read_text())

    def test_malformed_json_is_not_acceptance(self):
        self.assertNotEqual(self.run_backend('{broken')[0],0)

    def test_false_success_is_not_acceptance(self):
        self.assertNotEqual(self.run_backend({'success':False,'results':VALID['results']})[0],0)

    def test_string_success_is_not_boolean_acceptance(self):
        self.assertNotEqual(self.run_backend({'success':'true','results':VALID['results']})[0],0)

    def test_missing_or_empty_transactions_are_not_acceptance(self):
        for results in ({},{'transids':[]},{'transids':[{'transid':'wrong-case'}]},{'transids':[{'transId':''}]}):
            with self.subTest(results=results):
                self.assertNotEqual(self.run_backend({'success':True,'results':results})[0],0)

    def test_non_200_is_not_acceptance_even_with_success_body(self):
        self.assertNotEqual(self.run_backend(status='500')[0],0)

    def test_transport_error_is_uncertain_even_with_received_success_body(self):
        self.assertEqual(self.run_backend(curl_rc=28)[0],28)

    def test_oversized_response_is_not_acceptance(self):
        body=dict(VALID); body['padding']='x'*131073
        self.assertNotEqual(self.run_backend(body)[0],0)

    def test_missing_credentials_prevents_curl(self):
        rc,_=self.run_backend(prefix='PAYLOAD_GET_CONFIG() { return 1; }')
        self.assertNotEqual(rc,0)
        self.assertFalse((self.root/'curl-capture.argv').exists())

    def test_acceptance_does_not_require_stat_command(self):
        rc,out=self.run_backend(prefix='stat() { return 127; }')
        self.assertEqual(rc,0,out)


class MenuTests(unittest.TestCase):
    def run_cancel_menu(self, copied_entry=False, missing_libraries=False):
        with tempfile.TemporaryDirectory(prefix='vts-menu-offline-') as temp:
            path=Path(temp); commands=path/'commands.sh'; marker=path/'forbidden'; menu=path/'menu'
            commands.write_text('''LIST_PICKER() { printf '%s\\n' "$@" > "$VTS_TEST_MENU"; printf 'Cancel'; }
PAYLOAD_GET_CONFIG() { printf 'config' >> "$VTS_TEST_FORBIDDEN"; return 1; }
curl() { printf 'curl' >> "$VTS_TEST_FORBIDDEN"; return 1; }
LOG() { :; }
ERROR_DIALOG() { :; }
''',encoding='utf-8')
            env=os.environ.copy()
            env.update(VTS_COMMANDS_LIBRARY=unix(commands), VTS_TEST_FORBIDDEN=unix(marker),
                       VTS_TEST_MENU=unix(menu), VTS_STATE_DIR=unix(path/'receipts'),
                       VTS_LOOT_DIR=unix(path/'loot'),VTS_ARCHIVE_DIR=unix(path/'archive'))
            entry=ROOT/'payload.sh'
            cwd=ROOT
            if copied_entry:
                entry=path/'temporary-payload-entry.sh'
                shutil.copyfile(ROOT/'payload.sh',entry)
            if missing_libraries:
                cwd=path
            result=subprocess.run([BASH,'--noprofile','--norc',unix(entry)],cwd=cwd,
                                  env=env,capture_output=True,text=True,timeout=10)
            if missing_libraries:
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(menu.exists()); self.assertFalse(marker.exists())
                return
            self.assertEqual(result.returncode,0,result.stderr)
            arguments=menu.read_text().splitlines()
            self.assertEqual(arguments[-1],'Cancel')
            self.assertEqual(arguments[1:-1],['Upload new log','Retry archive','Archive prior upload','Cancel'])
            self.assertLessEqual(len(arguments[0]),21)
            self.assertTrue(all(len(label)<=23 for label in arguments[1:-1]))
            self.assertFalse(marker.exists()); self.assertFalse((path/'receipts').exists())

    def test_initial_cancel_does_not_read_credentials_touch_receipts_or_upload(self):
        self.run_cancel_menu()

    def test_native_copied_entry_uses_validated_payload_working_directory(self):
        self.run_cancel_menu(copied_entry=True)

    def test_copied_entry_without_either_library_directory_fails_closed(self):
        self.run_cancel_menu(copied_entry=True,missing_libraries=True)

    def test_disclosed_upload_still_requires_explicit_final_selection(self):
        for confirmation in ('0','1','unexpected'):
            with self.subTest(confirmation=confirmation), tempfile.TemporaryDirectory(prefix='vts-confirm-offline-') as temp:
                path=Path(temp); commands=path/'commands.sh'; loot=path/'loot'; loot.mkdir()
                (loot/'synthetic fixture.csv').write_text('synthetic only\n')
                commands.write_text('''LIST_PICKER() {
    case "$1" in
        'Valleytech WiGLE') printf 'Upload new log';;
        'Choose one closed log') printf '1: synthetic fixture.csv';;
        'Upload to WiGLE?') printf '%s\\n' "$@" > "$VTS_TEST_FINAL"; printf 'Cancel';;
        *) return 1;;
    esac
}
CONFIRMATION_DIALOG() { printf '%s' "$1" > "$VTS_TEST_DISCLOSURE"; printf '%s' "$VTS_TEST_CONFIRMATION"; }
PAYLOAD_GET_CONFIG() { printf 'config' >> "$VTS_TEST_FORBIDDEN"; return 1; }
curl() { printf 'curl' >> "$VTS_TEST_FORBIDDEN"; return 1; }
LOG() { :; }
ERROR_DIALOG() { :; }
''',encoding='utf-8')
                env=os.environ.copy()
                env.update(VTS_COMMANDS_LIBRARY=unix(commands),VTS_LOOT_DIR=unix(loot),
                           VTS_STATE_DIR=unix(path/'receipts'),VTS_TEST_FORBIDDEN=unix(path/'forbidden'),
                           VTS_TEST_DISCLOSURE=unix(path/'disclosure'),VTS_TEST_FINAL=unix(path/'final'),
                           VTS_TEST_CONFIRMATION=confirmation)
                result=subprocess.run([BASH,'--noprofile','--norc',unix(ROOT/'payload.sh')],
                                      cwd=ROOT,env=env,capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,0,result.stderr)
                disclosure=(path/'disclosure').read_text()
                for text in ('synthetic fixture.csv','Wi-Fi','Bluetooth','GPS','WiGLE','never uploaded'):
                    self.assertIn(text,disclosure)
                self.assertEqual((path/'final').exists(),confirmation=='1')
                if confirmation=='1':
                    options=(path/'final').read_text().splitlines()
                    self.assertEqual(options[-1],'Cancel')
                    self.assertLessEqual(len(options[0]),21)
                    self.assertTrue(all(len(label)<=23 for label in options[1:]))
                self.assertFalse((path/'forbidden').exists()); self.assertFalse((path/'receipts').exists())


if __name__=='__main__':
    unittest.main(verbosity=2)
