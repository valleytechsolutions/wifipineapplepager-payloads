"""Offline integration tests: synthetic files and shell stubs, never real upload."""
from pathlib import Path
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash') or r'C:\Program Files\Git\bin\bash.exe'


def unix(path):
    p = Path(path).resolve().as_posix()
    return '/'+p[0].lower()+p[2:] if len(p)>1 and p[1]==':' else p


def q(value):
    return shlex.quote(str(value))


class SafeUploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vts-wigle-offline-')
        self.root = Path(self.temp.name)
        self.loot = self.root/'loot'
        self.state = self.root/'state'
        self.archive = self.root/'archive'
        self.proc = self.root/'proc'
        self.lock = self.root/'lock'
        self.calls = self.root/'calls'
        self.loot.mkdir(); self.proc.mkdir()
        self.source = self.loot/'test log.csv'
        self.source.write_bytes(b'WigleWifi-1.6,fixture\nMAC,SSID,FirstSeen\n00:00:00:00:00:01,TEST,2020-01-01\n')
        self.hash = hashlib.sha256(self.source.read_bytes()).hexdigest()

    def tearDown(self):
        self.temp.cleanup()

    def script(self, action, extra='', native=True):
        config = {'VTS_LOOT_DIR': self.loot, 'VTS_ARCHIVE_DIR': self.archive,
                  'VTS_STATE_DIR': self.state, 'VTS_PROC_ROOT': self.proc,
                  'VTS_LOCK_DIR': self.lock, 'VTS_TEST_CALLS': self.calls}
        pre = 'export PATH=/usr/bin:/bin\n'
        pre += '\n'.join(f'{k}={q(unix(v))}' for k,v in config.items())
        pre += '\nVTS_MIN_AGE_SECONDS=0\nVTS_STABILITY_SECONDS=0\n'
        pre += 'source '+q(unix(ROOT/'lib/wigle_safe.sh'))+'\n'
        pre += 'source '+q(unix(ROOT/'lib/native_adapter.sh'))+'\n'
        # Exercise ordering/failure paths; physical power-loss durability is a
        # device property, and global Windows flushes slow these fixtures hugely.
        pre += 'sync() { return 0; }\n'
        pre += "trap 'vts_unlock' EXIT\n"
        if native:
            pre += '''
vts_adapter_ready() { return 0; }
vts_native_upload() {
    printf 'upload\n' >> "$VTS_TEST_CALLS"
    printf '{"success":true,"results":{"transids":[{"transid":"OFFLINE-FIXTURE"}]}}\n' > "$2"
    return 0
}
'''
        return pre+'\n'+extra+'\n'+action+'\nrc=$?\nprintf "RESULT:%s\\nMESSAGE:%s\\n" "$rc" "$VTS_MESSAGE"\n'

    def run_action(self, action=None, extra='', native=True):
        action = action or f'vts_upload_one {q(unix(self.source))} confirmed-not-previously-uploaded'
        result = subprocess.run([BASH,'--noprofile','--norc','-c',self.script(action,extra,native)],
                                capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        match = re.search(r'RESULT:(\d+)',result.stdout)
        self.assertIsNotNone(match,result.stdout+result.stderr)
        return int(match.group(1)), result.stdout+result.stderr

    def count(self):
        return len(self.calls.read_text().splitlines()) if self.calls.exists() else 0

    def status(self):
        return (self.state/'receipts'/f'{self.hash}.state').read_text().splitlines()[0]

    def test_success_archives_once_and_retains_original(self):
        rc,out=self.run_action(); self.assertEqual(rc,0,out)
        self.assertEqual(self.count(),1); self.assertFalse(self.source.exists())
        self.assertEqual(hashlib.sha256((self.archive/self.source.name).read_bytes()).hexdigest(),self.hash)
        held=list((self.loot/'.valleytech-upload-originals').iterdir())
        self.assertEqual(len(held),1)
        self.assertEqual(hashlib.sha256(held[0].read_bytes()).hexdigest(),self.hash)
        self.assertEqual(self.status(),'status=archived')

    def test_accepted_archive_failure_then_recovery_never_reuploads(self):
        rc,_=self.run_action(extra="vts_commit_archive() { vts_fail 27 'mock archive failure'; }")
        self.assertEqual(rc,27); self.assertEqual(self.status(),'status=uploaded')
        rc,out=self.run_action(f'vts_recover_receipt {self.hash}')
        self.assertEqual(rc,0,out); self.assertEqual(self.count(),1)

    def test_retry_upload_action_with_accepted_receipt_is_archive_only(self):
        self.run_action(extra="vts_commit_archive() { return 27; }")
        rc,out=self.run_action(); self.assertEqual(rc,0,out); self.assertEqual(self.count(),1)

    def test_uncertain_network_response_blocks_all_automatic_retries(self):
        extra='vts_native_upload() { printf "call\\n" >> "$VTS_TEST_CALLS"; return 7; }'
        rc,_=self.run_action(extra=extra); self.assertEqual(rc,28)
        rc,_=self.run_action(); self.assertEqual(rc,28); self.assertEqual(self.count(),1)
        self.assertTrue(self.source.exists())

    def test_failed_accepted_receipt_commit_stays_uncertain(self):
        extra='''
eval "$(declare -f vts_write_state | sed '1s/vts_write_state/vts_real_write_state/')"
vts_write_state() { if [[ $1 == uploaded ]]; then return 1; fi; vts_real_write_state "$@"; }
'''
        rc,_=self.run_action(extra=extra); self.assertEqual(rc,28)
        self.assertEqual(self.status(),'status=uncertain')
        rc,_=self.run_action(); self.assertEqual(rc,28); self.assertEqual(self.count(),1)

    def test_corrupt_receipt_blocks_retry(self):
        self.run_action(extra='vts_commit_archive() { return 27; }')
        (self.state/'receipts'/f'{self.hash}.state').write_text('status=bogus\n')
        rc,_=self.run_action(); self.assertEqual(rc,28); self.assertEqual(self.count(),1)

    def test_missing_receipt_with_attempt_marker_blocks_retry(self):
        self.run_action(extra='vts_commit_archive() { return 27; }')
        (self.state/'receipts'/f'{self.hash}.state').unlink()
        rc,_=self.run_action(); self.assertEqual(rc,28); self.assertEqual(self.count(),1)

    def test_missing_receipt_then_renamed_same_content_cannot_upload(self):
        self.run_action(extra='vts_commit_archive() { return 27; }')
        (self.state/'receipts'/f'{self.hash}.state').unlink()
        renamed=self.loot/'same bytes new name.csv'
        self.source.rename(renamed); self.source=renamed
        rc,_=self.run_action(); self.assertEqual(rc,28); self.assertEqual(self.count(),1)

    def test_same_content_new_name_is_not_uploaded_again(self):
        content=self.source.read_bytes()
        self.run_action()
        self.source=self.loot/'renamed copy.csv'; self.source.write_bytes(content)
        rc,out=self.run_action(); self.assertEqual(rc,0,out); self.assertEqual(self.count(),1)

    def test_archive_collision_preserves_existing_file(self):
        self.archive.mkdir(); target=self.archive/self.source.name; target.write_text('different old archive')
        rc,out=self.run_action(); self.assertEqual(rc,0,out)
        self.assertEqual(target.read_text(),'different old archive')
        self.assertTrue((self.archive/f'{self.hash}.csv').is_file())

    def test_archive_unavailable_prevents_network(self):
        self.archive.write_text('not a directory')
        rc,_=self.run_action(); self.assertEqual(rc,25); self.assertEqual(self.count(),0)

    def test_archive_copy_failure_prevents_network(self):
        extra='''cp() { case "$2" in "$VTS_ARCHIVE_DIR"/*) return 1;; *) command cp "$@";; esac; }'''
        # Arguments include --, so destination is last rather than positional $2.
        extra='''cp() { local dest="${@: -1}"; case "$dest" in "$VTS_ARCHIVE_DIR"/*) return 1;; *) command cp "$@";; esac; }'''
        rc,_=self.run_action(extra=extra); self.assertEqual(rc,25); self.assertEqual(self.count(),0)

    def test_open_file_is_excluded(self):
        fd=self.proc/'123'/'fd'; fd.mkdir(parents=True)
        try: (fd/'4').symlink_to(self.source)
        except OSError: self.skipTest('Host does not allow symlinks')
        rc,_=self.run_action(); self.assertEqual(rc,23); self.assertEqual(self.count(),0)

    def test_recent_file_is_excluded(self):
        rc,_=self.run_action(extra='VTS_MIN_AGE_SECONDS=60')
        self.assertEqual(rc,23); self.assertEqual(self.count(),0)

    def test_open_predicate_excludes_file_without_host_symlink_support(self):
        rc,_=self.run_action(extra='vts_is_open() { return 0; }')
        self.assertEqual(rc,23); self.assertEqual(self.count(),0)

    def test_absent_stat_command_does_not_prevent_safe_archive(self):
        rc,out=self.run_action(extra='stat() { return 127; }')
        self.assertEqual(rc,0,out); self.assertEqual(self.count(),1)

    def test_unavailable_file_time_fails_closed_before_network(self):
        rc,_=self.run_action(extra='date() { if [[ ${1:-} == -r ]]; then return 127; fi; command date "$@"; }')
        self.assertEqual(rc,23); self.assertEqual(self.count(),0)

    def test_failed_same_filesystem_probe_retains_source(self):
        rc,_=self.run_action(extra='vts_same_filesystem() { return 1; }')
        self.assertEqual(rc,27); self.assertEqual(self.count(),1)
        self.assertTrue(self.source.exists())

    def test_changed_source_after_upload_is_retained_and_not_retried(self):
        extra='''vts_native_upload() { printf 'call\n' >> "$VTS_TEST_CALLS"; printf '{}\n' > "$2"; printf 'new observation\n' >> "$VTS_LOOT_DIR/test log.csv"; return 0; }'''
        rc,_=self.run_action(extra=extra); self.assertEqual(rc,24)
        self.assertTrue(self.source.exists()); self.assertIn('new observation',self.source.read_text())
        rc,_=self.run_action(); self.assertEqual(rc,24); self.assertEqual(self.count(),1)

    def test_rename_race_preserves_unuploaded_original_bytes(self):
        extra='''mv() { if [[ "$2" == "$VTS_LOOT_DIR/test log.csv" ]]; then printf 'racing observation\n' >> "$2"; fi; command mv "$@"; }'''
        rc,_=self.run_action(extra=extra); self.assertEqual(rc,24)
        held=list((self.loot/'.valleytech-upload-originals').iterdir())
        self.assertEqual(len(held),1); self.assertIn('racing observation',held[0].read_text())
        self.assertEqual(self.count(),1)

    def test_missing_legacy_confirmation_prevents_upload(self):
        rc,_=self.run_action(f'vts_upload_one {q(unix(self.source))}')
        self.assertEqual(rc,29); self.assertEqual(self.count(),0)

    def test_manual_prior_acceptance_archives_without_network(self):
        rc,out=self.run_action(f'vts_archive_confirmed {q(unix(self.source))} confirmed-previously-uploaded')
        self.assertEqual(rc,0,out); self.assertEqual(self.count(),0)
        self.assertTrue((self.state/'receipts'/f'{self.hash}.manual.txt').is_file())

    def test_missing_native_dependencies_disable_upload(self):
        rc,_=self.run_action(native=False); self.assertEqual(rc,78); self.assertEqual(self.count(),0)

    def test_unicode_and_spaces_are_preserved(self):
        name='test café log.csv'; self.source.rename(self.loot/name); self.source=self.loot/name
        rc,out=self.run_action(); self.assertEqual(rc,0,out)
        self.assertTrue((self.archive/name).exists())

    def test_concurrent_invocation_cannot_upload(self):
        action=f'vts_upload_one {q(unix(self.source))} confirmed-not-previously-uploaded'
        script=self.script(action,"vts_native_upload() { printf 'call\\n' >> \"$VTS_TEST_CALLS\"; printf '{}\\n' > \"$2\"; sleep 2; }")
        proc=subprocess.Popen([BASH,'--noprofile','--norc','-c',script],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            deadline=time.time()+10
            while not self.lock.exists() and time.time()<deadline: time.sleep(0.02)
            self.assertTrue(self.lock.exists())
            rc,_=self.run_action(); self.assertEqual(rc,21)
            out,err=proc.communicate(timeout=30); self.assertIn('RESULT:0',out,err)
            self.assertEqual(self.count(),1)
        finally:
            if proc.poll() is None: proc.kill(); proc.communicate()


if __name__=='__main__':
    unittest.main(verbosity=2)
