"""针对真实文件事务测试；内核读取/来源 verify 使用明确的隔离替身。"""
import copy
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('tcp_recovery', ROOT / 'tools/recover_tcp_baseline.py')
r = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(r)
HOSTS = (
    ('VPS-01', 3, '0.1.0-rc.11', 'debian13-1c1g', 500),
    ('VPS-02', 4, '0.1.0-rc.12', 'debian13-1c1g', 100),
    ('VPS-03', 4, '0.1.0-rc.16', 'debian13-1c2g', 500),
    ('VPS-04', 4, '0.1.0-rc.12', 'debian13-1c2g', 200),
    ('VPS-05', 4, '0.1.0-rc.17', 'debian13-1c1g', 200),
)


class FixtureHost(r.Host):
    def __init__(self, root):
        super().__init__(root)
        self.verifications = 0
        self.fail_verify = False
        self.qdisc = [{'kind': 'fq', 'dev': 'fixture0', 'root': True}]

    def qdiscs(self):
        return copy.deepcopy(self.qdisc)

    def verify_source(self, profile):
        self.verifications += 1
        r.require(not self.fail_verify, 'source verify fixture failure')

    @contextmanager
    def locked(self):
        if os.name == 'posix':
            with super().locked():
                yield
        else:
            yield


class BaselineRecoveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.owner = patch.object(r, 'OWNER_UID', os.getuid() if hasattr(os, 'getuid') else 0)
        self.owner.start()
        self.addCleanup(self.owner.stop)
        if os.name != 'posix':
            # Windows 无 Linux uid/mode/flock；字节级事务测试仍运行，权限/锁另有 Linux 测试。
            def windows_secure(path, directory=False):
                path = Path(path)
                r.require(path.is_absolute() and '..' not in path.parts, 'absolute path required')
                r.require(not path.is_symlink(), 'symlink refused')
                r.require(path.is_dir() if directory else path.is_file(), 'wrong file type')
                return path
            permission = patch.object(r, 'secure', windows_secure)
            permission.start()
            self.addCleanup(permission.stop)
        self.host = FixtureHost(self.root)
        self.write('/etc/machine-id', 'a' * 32)
        self.write('/etc/os-release', 'ID=debian\nVERSION_ID="13"\n')
        self.write('/proc/sys/kernel/random/boot_id', 'boot-fixture-a')
        self.write('/proc/swaps', 'Filename Type Size Used Priority\n/swapfile-proxy file 1024 0 -2\n')
        self.write(r.LOCK, 'existing lock metadata')
        for name in (*r.MANAGED, *r.BACKUPS):
            self.write(name, 'fixture bytes for ' + name)
        for key in r.KEYS:
            value = '4096 131072 16777216' if key == r.TCP[0] else (
                '4096 65536 16777216' if key == r.TCP[1] else '1')
            self.write('/proc/sys/' + key.replace('.', '/'), value)
        self.configure(HOSTS[4])

    def write(self, absolute, raw):
        target = self.host.path(absolute)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw.encode() if isinstance(raw, str) else raw)
        target.chmod(0o600)
        return target

    def configure(self, spec):
        host_id, schema, version, profile, port = spec
        originals = {key: ('4096' if key in r.TCP else '1') for key in r.KEYS}
        state = {'schema_version': schema, 'script_version': version, 'state': 'VERIFIED',
                 'profile': {'id': profile}, 'network': {'port_speed_mbps': port},
                 'original_sysctls': originals,
                 'timestamps': {'prepared': '2026-08-16T01:15:50Z', 'last_update': '2026-08-16T01:15:52Z'},
                 'managed_files': [{'path': p, 'sha256': r.sha(self.host.path(p).read_bytes())} for p in r.MANAGED]}
        self.write(r.STATE, r.encode(state))
        source = self.write('/source.sh', f"SCRIPT_VERSION='{version}'\nPROFILE_ID='{profile}'\n")
        _, _, binding, guard = self.host.observe()
        self.plan = {'schema_version': 1, 'approved': True, 'host_id': host_id,
                     'target_version': r.VERSION, 'binding': binding, 'guard_sha256': r.sha(r.encode(guard)),
                     'mode': 'replacement', 'accept_new_baseline': True,
                     'vectors': {key: guard['sysctls'][key] for key in r.TCP},
                     'evidence': {'kind': 'current-verified-runtime'},
                     'source_profile': {'path': str(source), 'sha256': r.sha(source.read_bytes())}}
        self.plan_file = self.root / 'plan.json'
        self.archive = self.root / ('archive-' + host_id)

    def prepare(self):
        self.plan_file.write_bytes(r.encode(self.plan))
        self.plan_file.chmod(0o600)
        self.plan_hash = r.sha(self.plan_file.read_bytes())
        return r.prepare(self.host, self.plan_file, self.archive)

    def transition(self, action):
        return r.transition(self.host, self.archive, self.plan_hash, action)

    def historical(self):
        self.plan['mode'] = 'historical'
        self.plan['accept_new_baseline'] = False
        values = dict(zip(r.TCP, ('4096 131072 6291456', '4096 16384 4194304')))
        self.plan['vectors'] = values
        evidence = self.write('/historical.txt', '\n'.join(f'{k} = {v}' for k, v in values.items()))
        self.plan['evidence'] = {'kind': 'same-host-same-deployment', 'host_deployment_confirmed': True,
                                 'timestamps': copy.deepcopy(self.plan['binding']['timestamps']),
                                 'path': str(evidence), 'sha256': r.sha(evidence.read_bytes())}

    def test_all_five_numbered_hosts_prepare_activate_and_undo(self):
        for spec in HOSTS:
            with self.subTest(host=spec[0]):
                self.configure(spec)
                if spec[0] == 'VPS-04':
                    self.historical()
                original = self.host.path(r.STATE).read_bytes()
                guard = self.host.observe()[3]
                prepared = self.prepare()
                self.assertFalse(prepared['state_changed'])
                self.assertEqual(self.host.path(r.STATE).read_bytes(), original)
                self.assertEqual(self.transition('activate')['phase'], 'ACTIVATED')
                actual = r.decode(self.host.path(r.STATE).read_bytes())
                self.assertEqual(actual['tcp_baseline_recovery']['host_id'], spec[0])
                self.assertEqual(actual['tcp_baseline_recovery']['historical_originals_recovered'], spec[0] == 'VPS-04')
                self.assertEqual({k: actual['original_sysctls'][k] for k in r.TCP}, self.plan['vectors'])
                self.assertEqual(self.host.observe()[3], guard)
                self.assertEqual((self.archive / 'state.before.json').read_bytes(), original)
                self.transition('activate')  # 进程中断后再次调用幂等。
                self.assertEqual(self.transition('status')['phase'], 'ACTIVATED')
                self.transition('undo')
                self.assertEqual(self.host.path(r.STATE).read_bytes(), original)

    def test_reject_unapproved_wrong_host_version_state_and_vectors(self):
        changes = [('approved', False), ('host_id', 'server'), ('target_version', '0.2.0-rc.1'),
                   ('accept_new_baseline', False), ('mode', 'guess'),
                   ('vectors', {r.TCP[0]: '4096', r.TCP[1]: '4096 65536 1'})]
        base = copy.deepcopy(self.plan)
        raw = self.host.path(r.STATE).read_bytes()
        for key, value in changes:
            with self.subTest(key=key):
                self.plan = copy.deepcopy(base)
                self.plan[key] = value
                with self.assertRaises(r.Refused):
                    self.prepare()
                self.assertFalse(self.archive.exists())
                self.assertEqual(self.host.path(r.STATE).read_bytes(), raw)
        for key in ('machine_id_sha256', 'state_sha256', 'profile_id', 'timestamps'):
            self.plan = copy.deepcopy(base)
            self.plan['binding'][key] = 'incorrect'
            with self.assertRaises(r.Refused):
                self.prepare()

    def test_historical_requires_explicit_same_deployment_evidence(self):
        self.historical()
        self.plan['evidence']['host_deployment_confirmed'] = False
        with self.assertRaises(r.Refused):
            self.prepare()
        self.plan['evidence']['host_deployment_confirmed'] = True
        self.plan['evidence']['timestamps']['prepared'] = 'wrong'
        with self.assertRaises(r.Refused):
            self.prepare()

    def test_wrong_evidence_hash_or_values_refused(self):
        self.historical()
        self.plan['evidence']['sha256'] = '0' * 64
        with self.assertRaises(r.Refused):
            self.prepare()
        self.historical()
        self.plan['vectors'][r.TCP[0]] = '4096 131072 8388608'
        with self.assertRaises(r.Refused):
            self.prepare()

    def test_reference_values_never_marked_as_historical(self):
        self.historical()
        self.plan.update(mode='replacement', accept_new_baseline=True)
        self.plan['evidence']['kind'] = 'reference'
        self.prepare()
        self.transition('activate')
        metadata = r.decode(self.host.path(r.STATE).read_bytes())['tcp_baseline_recovery']
        self.assertFalse(metadata['historical_originals_recovered'])

    def test_source_verification_failure_never_creates_archive(self):
        self.host.fail_verify = True
        with self.assertRaises(r.Refused):
            self.prepare()
        self.assertFalse(self.archive.exists())

    def test_wrong_source_asset_refused_before_execution(self):
        self.plan['source_profile']['sha256'] = '0' * 64
        with self.assertRaises(r.Refused):
            self.prepare()
        self.assertEqual(self.host.verifications, 0)

    def test_runtime_boot_qdisc_and_state_drift_block_activation(self):
        self.prepare()
        path = self.host.path('/proc/sys/net/ipv4/tcp_wmem')
        original = path.read_bytes()
        path.write_text('4096 65536 33554432')
        with self.assertRaises(r.Refused):
            self.transition('activate')
        path.write_bytes(original)
        self.host.qdisc[0]['kind'] = 'fq_codel'
        with self.assertRaises(r.Refused):
            self.transition('activate')
        self.host.qdisc[0]['kind'] = 'fq'
        self.write('/proc/sys/kernel/random/boot_id', 'boot-b')
        with self.assertRaises(r.Refused):
            self.transition('activate')
        self.write('/proc/sys/kernel/random/boot_id', 'boot-fixture-a')
        self.write(r.STATE, '{}')
        with self.assertRaises(r.Refused):
            self.transition('activate')

    def test_swap_usage_alone_does_not_change_guard(self):
        self.prepare()
        self.write('/proc/swaps', 'Filename Type Size Used Priority\n/swapfile-proxy file 1024 100 -2\n')
        self.assertEqual(self.transition('activate')['phase'], 'ACTIVATED')

    def test_undo_after_lifecycle_changes_refused(self):
        self.prepare()
        self.transition('activate')
        self.write(r.MANAGED[0], 'changed configuration')
        with self.assertRaises(r.Refused):
            self.transition('undo')

    def test_archive_tampering_and_wrong_plan_digest_refused(self):
        self.prepare()
        with self.assertRaises(r.Refused):
            r.transition(self.host, self.archive, '0' * 64, 'activate')
        (self.archive / 'state.proposed.json').write_bytes(b'{}')
        with self.assertRaises(r.Refused):
            self.transition('activate')

    def test_archive_rejects_more_than_the_two_field_changes_even_with_rehashed_payload(self):
        self.prepare()
        target = self.archive / 'state.proposed.json'
        value = r.decode(target.read_bytes())
        value['script_version'] = r.VERSION
        target.write_bytes(r.encode(value))
        receipt = r.decode((self.archive / 'receipt.json').read_bytes())
        receipt['files']['state.proposed.json'] = r.sha(target.read_bytes())
        (self.archive / 'receipt.json').write_bytes(r.encode(receipt))
        with self.assertRaises(r.Refused):
            self.transition('activate')

    def test_partial_archive_is_never_active(self):
        self.plan_file.write_bytes(r.encode(self.plan))
        real = r.write_new
        def fail_receipt(path, raw):
            if path.name == 'receipt.json':
                raise OSError('injected interruption')
            real(path, raw)
        with patch.object(r, 'write_new', fail_receipt), self.assertRaises(OSError):
            self.prepare()
        self.assertFalse((self.archive / 'receipt.json').exists())
        with self.assertRaises((OSError, r.Refused)):
            self.transition('activate')

    def test_atomic_replace_failure_preserves_original(self):
        self.prepare()
        before = self.host.path(r.STATE).read_bytes()
        with patch.object(r.os, 'replace', side_effect=OSError('injected')), self.assertRaises(OSError):
            self.transition('activate')
        self.assertEqual(self.host.path(r.STATE).read_bytes(), before)
        self.assertEqual(self.transition('status')['phase'], 'PREPARED')

    def test_interruption_after_replace_is_recoverable(self):
        self.prepare()
        with patch.object(r, 'sync_dir', side_effect=OSError('injected')), self.assertRaises(OSError):
            self.transition('activate')
        self.assertEqual(self.transition('status')['phase'], 'ACTIVATED')
        self.transition('undo')
        self.assertEqual(self.transition('status')['phase'], 'PREPARED')

    def test_archive_cannot_be_under_old_state_or_overwritten(self):
        self.archive = self.host.path('/var/lib/proxy-vps-tuning/recovery')
        with self.assertRaises(r.Refused):
            self.prepare()
        self.archive = self.root / 'archive'
        self.prepare()
        with self.assertRaises(r.Refused):
            self.prepare()

    def test_duplicate_json_and_malformed_vectors_refused(self):
        with self.assertRaises(r.Refused):
            r.decode('{"approved":false,"approved":true}')
        for value in ('4096', '0 1 2', '4096 1 999999', '4096 65536 2147483648', '4096\n65536 16777216'):
            with self.assertRaises(r.Refused):
                r.vector(value)

    @unittest.skipUnless(os.name == 'posix', 'requires POSIX ownership, permissions and flock')
    def test_real_permissions_and_exclusive_lock(self):
        self.prepare()
        lock_before = self.host.path(r.LOCK).read_bytes()
        with self.host.locked(), self.assertRaises(r.Refused):
            self.transition('activate')
        self.assertEqual(self.host.path(r.LOCK).read_bytes(), lock_before)
        (self.archive / 'receipt.json').chmod(0o666)
        with self.assertRaises(r.Refused):
            self.transition('activate')

    def test_cli_help_exposes_no_migration_or_reboot_operation(self):
        result = subprocess.run([sys.executable, str(ROOT / 'tools/recover_tcp_baseline.py'), '--help'],
                                capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn(b'inspect,prepare,activate,undo,status', result.stdout)

    @unittest.skipUnless(sys.platform.startswith('linux') and hasattr(os, 'geteuid') and os.geteuid() == 0,
                         'requires Linux root for actual migrator CLI and file ownership')
    def test_native_migrator_preserves_provenance_and_captures_post_boot_baseline(self):
        # 真实恢复工具事务 -> 真实迁移 CLI；profile 只修改临时 fixture，boot ID 模拟。
        for mode in ('historical', 'replacement'):
            with self.subTest(mode=mode):
                self.configure(HOSTS[3] if mode == 'historical' else HOSTS[4])
                self.write('/etc/machine-id', Path('/etc/machine-id').read_text())
                version = self.plan['binding']['script_version']
                profile = self.plan['binding']['profile_id']
                source = self.write('/source.sh', f"""#!/bin/bash
set -Eeuo pipefail
SCRIPT_VERSION='{version}'
PROFILE_ID='{profile}'
case "$1" in
 verify) jq -e '.state=="VERIFIED"' "$DVT_STATE_FILE" >/dev/null ;;
 rollback) rm -- "$DVT_STATE_FILE" ;;
 *) exit 2 ;;
esac
""")
                target = self.write('/target.sh', f"""#!/bin/bash
set -Eeuo pipefail
SCRIPT_VERSION='{r.VERSION}'
PROFILE_ID='{profile}'
case "$1" in
 preflight) : ;;
 apply)
   jq -n --arg rmem "$(sysctl -n net.ipv4.tcp_rmem)" --arg wmem "$(sysctl -n net.ipv4.tcp_wmem)" \\
     '{{schema_version:4,script_version:"{r.VERSION}",state:"APPLIED",profile:{{id:"{profile}"}},original_sysctls:{{"net.ipv4.tcp_rmem":$rmem,"net.ipv4.tcp_wmem":$wmem}}}}' >"$DVT_STATE_FILE" ;;
 verify) jq '.state="VERIFIED"' "$DVT_STATE_FILE" >"$DVT_STATE_FILE.tmp"; mv "$DVT_STATE_FILE.tmp" "$DVT_STATE_FILE" ;;
 *) exit 2 ;;
esac
""")
                self.plan['binding'] = self.host.observe()[2]
                self.plan['source_profile'] = {'path': str(source), 'sha256': r.sha(source.read_bytes())}
                if mode == 'historical':
                    self.historical()
                self.prepare()
                self.transition('activate')
                checkpoint = self.root / ('migration-' + mode)
                boot = self.host.path('/proc/sys/kernel/random/boot_id')
                env = dict(os.environ, DVT_STATE_FILE=str(self.host.path(r.STATE)), DVT_BOOT_ID_FILE=str(boot))
                def migrate(tool, *args, success=True):
                    result = subprocess.run(['bash', str(tool), *args, '--checkpoint', str(checkpoint)],
                                            env=env, capture_output=True)
                    self.assertEqual(result.returncode == 0, success, result.stderr.decode())
                    return result
                migrate(ROOT / 'dvt-migrate.sh', 'prepare', '--source-profile', str(source),
                        '--target-profile', str(target), '--source-version', version,
                        '--target-version', r.VERSION, '--profile-id', profile, '--port', '200',
                        '--state-sha256', r.sha(self.host.path(r.STATE).read_bytes()))
                tool = checkpoint / 'dvt-migrate.sh'
                original = (checkpoint / 'baseline-recovery/state.before.json').read_bytes()
                self.assertEqual(r.decode(original)['original_sysctls'][r.TCP[0]], '4096')
                migration_path = checkpoint / 'migration.json'
                prepared = r.decode(migration_path.read_bytes())
                self.assertEqual(prepared['history'][0]['phase'], 'PREPARING')
                interrupted = copy.deepcopy(prepared)
                interrupted['phase'] = 'PREPARING'
                migration_path.write_bytes(r.encode(interrupted))
                migrate(tool, 'rollback', success=False)
                migration_path.write_bytes(r.encode(prepared))
                receipt_path = checkpoint / 'baseline-recovery/receipt.json'
                saved_receipt = receipt_path.read_bytes()
                receipt_path.write_bytes(b'{}')
                migrate(tool, 'rollback', success=False)
                receipt_path.write_bytes(saved_receipt)
                migrate(tool, 'rollback')
                migrate(tool, 'continue', success=False)
                boot.write_text('boot-second')
                migrate(tool, 'continue')
                migrate(tool, 'continue', success=False)
                boot.write_text('boot-third')
                applied = self.host.path(r.STATE).read_bytes()
                broken = r.decode(applied)
                broken['original_sysctls'][r.TCP[0]] = '4096'
                self.host.path(r.STATE).write_bytes(r.encode(broken))
                migrate(tool, 'continue', success=False)
                self.host.path(r.STATE).write_bytes(applied)
                migrate(tool, 'continue')
                record = r.decode((checkpoint / 'migration.json').read_bytes())
                final = r.decode(self.host.path(r.STATE).read_bytes())
                self.assertEqual(record['phase'], 'COMPLETE')
                self.assertEqual(record['baseline_recovery']['mode'], mode)
                self.assertEqual(record['post_reboot_tcp'], final['original_sysctls'])
                self.assertEqual((checkpoint / 'baseline-recovery/state.before.json').read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
