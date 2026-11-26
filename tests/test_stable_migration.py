"""正式候选的实际函数契约及 Linux root 归属测试；无公网流量、无宿主调参。"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MIGRATOR = ROOT / 'dvt-migrate.sh'
TEMPLATE = ROOT / 'tools/profile-template.sh.in'
TARGET_VERSION = re.search(r"^TOOL_VERSION='([^']+)'", MIGRATOR.read_text(), re.M)[1]


def function(name, path=MIGRATOR):
    return re.search(r'^' + name + r'\(\) \{.*?^\}', path.read_text(encoding='utf-8'), re.M | re.S)[0]


KEYS = re.search(r'PROFILE_SYSCTL_KEYS=\((.*?)\n\)', TEMPLATE.read_text(encoding='utf-8'), re.S)[1].split()


def state():
    return dict(schema_version=4, script_version='0.2.0-rc.4', state='VERIFIED',
                profile={'id': 'debian13-1c1g'},
                network={'port_speed_mbps': 5000, 'target_rtt_ms': 100,
                         'buffer_mode': 'auto-clamped', 'buffer_max_bytes': 16777216},
                swap={'created_by_script': True, 'size_mib': 1024},
                original_sysctls={k: '4096 65536 16777216' if k.endswith(('tcp_rmem', 'tcp_wmem')) else '1' for k in KEYS})


@unittest.skipUnless(shutil.which('bash') and shutil.which('jq'), 'requires Bash and jq')
class MigrationContracts(unittest.TestCase):
    def shell(self, body, expected=0):
        result = subprocess.run(['bash'], input=('set -Eeuo pipefail\n'
            'die() { printf "%s\\n" "$*" >&2; exit 2; }\n'
            'jq() { command jq "$@" | tr -d "\\r"; }\n' + body).encode(), capture_output=True)
        self.assertEqual(result.returncode, expected, result.stderr.decode(errors='replace'))
        return result

    def test_supported_edges_and_same_version_refusal(self):
        self.shell(function('validate_migration_edge') + '''
TOOL_VERSION=0.2.0-rc.6; target_version=$TOOL_VERSION
for source_version in 0.2.0-rc.4 0.2.0-rc.5; do validate_migration_edge; done
for source_version in 0.2.0-rc.3 0.2.0-rc.6 0.2.0; do
  result=0; (validate_migration_edge) || result=$?; [ "$result" = 2 ]
done
TOOL_VERSION=0.2.0; target_version=$TOOL_VERSION
for source_version in 0.2.0-rc.4 0.2.0-rc.5 0.2.0-rc.6; do validate_migration_edge; done
target_version=0.2.1; result=0; (validate_migration_edge) || result=$?; [ "$result" = 2 ]
TOOL_VERSION=0.3.0-rc.1; target_version=$TOOL_VERSION
for source_version in 0.2.0-rc.4 0.2.0-rc.5 0.2.0-rc.6; do validate_migration_edge; done
for source_version in 0.2.0 0.3.0-rc.1; do
  result=0; (validate_migration_edge) || result=$?; [ "$result" = 2 ]
done
''')

    def freeze(self, data, extra='', expected=0):
        # 在 Bash 自己的临时目录中生成 fixture，Windows 不冒充 Linux 所有权。
        return self.shell(function('freeze_intent') + '''
temp="$(mktemp -d)"; trap 'rm -rf -- "$temp"' EXIT
STATE_FILE="$temp/state.json"; target_profile="$temp/profile.sh"
cat >"$STATE_FILE" <<'STATE'
''' + json.dumps(data) + '''
STATE
cat >"$target_profile" <<'PROFILE'
PROFILE_SYSCTL_KEYS=(
''' + '\n'.join(KEYS) + '''
)
PROFILE
source_version=0.2.0-rc.4; profile_id=debian13-1c1g; port_mbps=5000
swap_policy=''; swap_mib=''; proxy_unit=''
systemctl() { echo loaded; }
''' + extra + '\nfreeze_intent\nprintf "%s\\n" "$intent"\n', expected)

    def test_auto_intent_and_owned_swap_preserved(self):
        result = json.loads(self.freeze(state()).stdout)
        self.assertEqual(result, dict(port=5000, rtt=100, buffer='auto', swap_policy='create',
                                      swap_mib=1024, proxy_unit='x-ui.service'))

    def test_explicit_buffer_and_unknown_swap_require_choice(self):
        data = state(); data['swap']['created_by_script'] = False
        data['network']['buffer_mode'] = 'explicit'
        self.freeze(data, expected=2)
        result = json.loads(self.freeze(data, 'swap_policy=disabled').stdout)
        self.assertEqual(result['buffer'], '16777216')
        self.assertEqual(result['swap_policy'], 'disabled')
        self.freeze(data, 'swap_policy=create; swap_mib=256', expected=2)

    def test_invalid_source_cannot_be_frozen(self):
        for field, value in [('target_rtt_ms', 19), ('buffer_mode', 'guessed'), ('port_speed_mbps', 200)]:
            with self.subTest(field=field):
                data = state(); data['network'][field] = value; self.freeze(data, expected=2)
        data = state(); del data['original_sysctls'][KEYS[0]]; self.freeze(data, expected=2)
        self.freeze(state(), 'swap_policy=disabled', expected=2)

    def test_clean_environment_and_strict_service_only_at_final_verify(self):
        self.shell(function('run_profile_clean') + '''
temp="$(mktemp -d)"; trap 'rm -rf -- "$temp"' EXIT
STATE_FILE="$temp/state.json"; intent='{"port":5000,"rtt":100,"buffer":"auto","swap_policy":"disabled","swap_mib":1024,"proxy_unit":"x-ui.service"}'
export REQUIRE_PROXY_SERVICE=1 PROXY_SERVICE_UNITS=wrong.service ENABLE_SWAP=1 BUF_MAX=123 DVT_UNRELATED=leak
cat >"$temp/profile" <<'PROFILE'
set -eu
[ -z "${DVT_UNRELATED:-}" ]; [ "$BUF_MAX" = auto ]; [ "$ENABLE_SWAP" = 0 ]
[ "$PORT_SPEED_MBPS" = 5000 ]; [ "$BUFFER_TARGET_RTT_MS" = 100 ]
case "$1" in
 apply) [ -z "${REQUIRE_PROXY_SERVICE:-}" ]; [ -z "${PROXY_SERVICE_UNITS:-}" ];;
 verify) [ "$REQUIRE_PROXY_SERVICE" = 1 ]; [ "$PROXY_SERVICE_UNITS" = x-ui.service ];;
 rollback) [ "$PURGE_CREATED_SWAP" = 1 ];;
esac
PROFILE
run_profile_clean "$temp/profile" apply
run_profile_clean "$temp/profile" verify 1
run_profile_clean "$temp/profile" rollback
''')

    def test_fq_startup_failure_is_not_hidden_by_current_queue(self):
        self.shell(function('verify_fq_service', TEMPLATE) + '''
FQ_SERVICE_NAME=fixture.service; error() { :; }
systemctl() {
  case "$1" in
    is-enabled) echo "$enabled";; is-active) [ "$active" = yes ];;
    show) case "$3" in Result) echo "$result";; ExecMainStatus) echo "$status";; esac;;
  esac
}
enabled=enabled; active=yes; result=success; status=0
verify_fq_service
enabled=disabled; if verify_fq_service; then exit 1; fi
enabled=enabled-runtime; if verify_fq_service; then exit 1; fi
enabled=static; if verify_fq_service; then exit 1; fi
enabled=enabled; active=no; if verify_fq_service; then exit 1; fi
active=yes; result=exit-code; if verify_fq_service; then exit 1; fi
result=success; status=1; if verify_fq_service; then exit 1; fi
''')

    def test_baseline_is_preserved_and_drift_blocks_retry(self):
        self.shell(function('record_baseline') + '\n' + function('verify_target_baseline') + '''
checkpoint="$(mktemp -d)"; trap 'rm -rf -- "$checkpoint"' EXIT
STATE_FILE="$checkpoint/target.json"
printf '%s\n' '{"original_sysctls":{"net.ipv4.tcp_rmem":"4096 65536 16777216","vm.swappiness":"60"}}' >"$checkpoint/source-state.json"
printf '%s\n' '{}' >"$checkpoint/migration.json"
sysctl() { jq -r --arg key "$2" '.original_sysctls[$key]' "$checkpoint/source-state.json"; }
record_baseline
before="$(sha256sum "$checkpoint/migration.json")"
record_baseline
[ "$(sha256sum "$checkpoint/migration.json")" = "$before" ]
cp "$checkpoint/source-state.json" "$STATE_FILE"
verify_target_baseline
jq '.original_sysctls["vm.swappiness"]="10"' "$STATE_FILE" >"$STATE_FILE.next"
mv "$STATE_FILE.next" "$STATE_FILE"
result=0; (verify_target_baseline) || result=$?; [ "$result" = 2 ]
sysctl() { echo 10; }
result=0; (record_baseline) || result=$?; [ "$result" = 2 ]
[ "$(sha256sum "$checkpoint/migration.json")" = "$before" ]
''')

    def test_two_boot_gates_before_strict_verify(self):
        self.shell(function('continue_stage') + '\n' + function('update_phase') + '''
checkpoint="$(mktemp -d)"; trap 'rm -rf -- "$checkpoint"' EXIT
STATE_FILE="$checkpoint/state.json"; trace="$checkpoint/trace"
validate_checkpoint() { :; }; info() { :; }
record_baseline() { :; }; verify_target_baseline() { :; }; verify_frozen_state() { :; }
boot=a; boot_id() { echo "$boot"; }
release_migration() { echo released >>"$trace"; }
run_profile_clean() {
  printf '%s:%s\n' "$2" "${3:-0}" >>"$trace"
  if [ "$2" = apply ]; then
    printf '%s\n' '{"script_version":"0.2.0","profile":{"id":"debian13-1c1g"},"state":"VERIFIED"}' >"$STATE_FILE"
  fi
}
printf '%s\n' '{"phase":"ROLLED_BACK_REBOOT_REQUIRED","reboot_gate_boot_id":"a","target_version":"0.2.0","profile_id":"debian13-1c1g","history":[]}' >"$checkpoint/migration.json"
result=0; (continue_stage) || result=$?; [ "$result" = 2 ]; [ ! -e "$trace" ]
boot=b; continue_stage
jq -e '.phase=="TARGET_APPLIED_REBOOT_REQUIRED" and .reboot_gate_boot_id=="b"' "$checkpoint/migration.json" >/dev/null
before="$(sha256sum "$trace")"
result=0; (continue_stage) || result=$?; [ "$result" = 2 ]
[ "$(sha256sum "$trace")" = "$before" ]
boot=c; continue_stage
jq -e '.phase=="COMPLETE"' "$checkpoint/migration.json" >/dev/null
grep -qx 'verify:1' "$trace"
grep -qx released "$trace"
''')


@unittest.skipUnless(sys.platform.startswith('linux') and os.geteuid() == 0, 'requires Linux root')
class MigrationOwnership(unittest.TestCase):
    def test_prepare_archive_active_lock_cancel_and_tamper(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory); os.chmod(base, 0o700)
            managed = base / 'state'; managed.mkdir(mode=0o700)
            source_state = managed / 'state.json'; source_state.write_text(json.dumps(state()))
            scripts = []
            for version in ('0.2.0-rc.4', TARGET_VERSION):
                path = base / version
                path.write_text("#!/bin/bash\nSCRIPT_VERSION='" + version + "'\nPROFILE_ID='debian13-1c1g'\n"
                                'PROFILE_SYSCTL_KEYS=(\n' + '\n'.join(KEYS) + '\n)\n'
                                'case "$1" in verify|preflight) exit 0;; *) exit 99;; esac\n')
                scripts.append(path)
            registry = base / 'registry'; checkpoint = base / 'checkpoint'
            env = dict(os.environ, DVT_STATE_FILE=str(source_state), DVT_MIGRATION_ROOT=str(registry))
            def call(action, cp=checkpoint, success=True):
                args = ['bash', str(MIGRATOR), action, '--checkpoint', str(cp)]
                if action == 'prepare':
                    args += ['--source-profile', str(scripts[0]), '--target-profile', str(scripts[1]),
                             '--source-version', '0.2.0-rc.4', '--target-version', TARGET_VERSION,
                             '--profile-id', 'debian13-1c1g', '--port', '5000', '--state-sha256',
                             hashlib.sha256(source_state.read_bytes()).hexdigest()]
                result = subprocess.run(args, env=env, capture_output=True)
                self.assertEqual(result.returncode == 0, success, result.stderr.decode())
            before = source_state.read_bytes()
            call('prepare'); self.assertEqual(source_state.read_bytes(), before)
            self.assertEqual((checkpoint / 'recovery/state.json').read_bytes(), before)
            call('prepare', base / 'second', success=False)
            import fcntl
            with (registry / 'lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                call('cancel', success=False)
            archive = checkpoint / 'recovery/state.json'; archive.write_text('{}')
            call('cancel', success=False); archive.write_bytes(before)
            call('cancel'); call('cancel')
            self.assertFalse((registry / 'active').exists())
            call('prepare', base / 'second'); call('cancel', base / 'second')


@unittest.skipUnless(sys.platform.startswith('linux') and os.geteuid() == 0, 'requires Linux root')
class MigrationFailureResume(unittest.TestCase):
    """真实迁移器 CLI/归档/锁；profile 为显式故障替身，boot ID 模拟，sysctl 只读。

    实际 profile 恢复与真实重启由 migration-guest.sh 验证；此处不调宿主内核。
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        os.chmod(self.base, 0o700)
        managed = self.base / 'managed'
        managed.mkdir(mode=0o700)
        self.state_file = managed / 'state.json'
        self.checkpoint = self.base / 'checkpoint'
        self.registry = self.base / 'registry'
        self.boot = self.base / 'boot'
        self.boot.write_text('source-boot\n')
        self.trace = self.base / 'trace'
        data = state()
        data['original_sysctls'] = {key: subprocess.check_output(
            ['sysctl', '-n', key], text=True).strip() for key in KEYS}
        self.source_bytes = json.dumps(data).encode()
        self.state_file.write_bytes(self.source_bytes)
        (self.base / 'source.json').write_bytes(self.source_bytes)
        self.env = dict(os.environ, DVT_STATE_FILE=str(self.state_file),
                        DVT_MIGRATION_ROOT=str(self.registry), DVT_BOOT_ID_FILE=str(self.boot))
        # 故障控制文件在受管树及 checkpoint 外，固定 profile 的摘要始终不变。
        import shlex
        for role, version in [('source', '0.2.0-rc.4'), ('target', TARGET_VERSION)]:
            script = ("#!/bin/bash\nset -Eeuo pipefail\nSCRIPT_VERSION='" + version + "'\n"
                      "PROFILE_ID='debian13-1c1g'\nPROFILE_SYSCTL_KEYS=(\n" + '\n'.join(KEYS) + '\n)\n'
                      'base=' + shlex.quote(str(self.base)) + '\nrole=' + role + '\n' + r'''
printf '%s:%s\n' "$role" "$1" >>"$base/trace"
case "$1" in
  preflight) exit 0 ;;
  rollback)
    [ "${PURGE_CREATED_SWAP:-0}" = 1 ]
    if [ "$role" = source ] && [ -f "$base/fail-rollback" ]; then
      [ "$(cat "$base/fail-rollback")" != removed ] || rm -- "$DVT_STATE_FILE"
      exit 41
    fi
    rm -- "$DVT_STATE_FILE"
    ;;
  apply)
    [ "$role" = target ]
    phase=VERIFIED
    if [ -f "$base/fail-apply" ]; then
      [ "$(cat "$base/fail-apply")" != absent ] || exit 42
      phase=APPLIED
    fi
    jq --arg version "$SCRIPT_VERSION" --arg phase "$phase" \
      '.script_version=$version | .state=$phase' "$base/source.json" >"$DVT_STATE_FILE"
    [ ! -f "$base/fail-apply" ] || exit 42
    ;;
  verify)
    if [ "$role" = target ]; then
      [ "${REQUIRE_PROXY_SERVICE:-0}" = 1 ]
      [ "$PROXY_SERVICE_UNITS" = fixture.service ]
      [ ! -f "$base/fail-verify" ] || exit 43
    fi
    jq -e --arg version "$SCRIPT_VERSION" \
      '.script_version==$version and .state=="VERIFIED"' "$DVT_STATE_FILE" >/dev/null
    ;;
  *) exit 99 ;;
esac
''')
            (self.base / (role + '.sh')).write_text(script)
        self.call('prepare', extra=[
            '--source-profile', str(self.base / 'source.sh'),
            '--target-profile', str(self.base / 'target.sh'),
            '--source-version', '0.2.0-rc.4', '--target-version', TARGET_VERSION,
            '--profile-id', 'debian13-1c1g', '--port', '5000',
            '--proxy-unit', 'fixture.service', '--state-sha256',
            hashlib.sha256(self.source_bytes).hexdigest()])
        self.materials = {str(p.relative_to(self.checkpoint)): p.read_bytes()
                          for p in self.checkpoint.rglob('*') if p.is_file() and p.name != 'migration.json'}

    def call(self, action, expected=0, extra=()):
        runner = self.checkpoint / 'dvt-migrate.sh' if self.checkpoint.exists() else MIGRATOR
        result = subprocess.run(['bash', str(runner), action, '--checkpoint', str(self.checkpoint), *extra],
                                env=self.env, capture_output=True)
        self.assertEqual(result.returncode, expected, result.stderr.decode(errors='replace'))
        return result

    def assert_phase(self, phase, active=True):
        data = json.loads((self.checkpoint / 'migration.json').read_text())
        self.assertEqual(data['phase'], phase)
        self.assertEqual((self.registry / 'active').exists(), active)
        if active:
            self.assertEqual((self.registry / 'active').read_text().strip(), str(self.checkpoint))
        for name, content in self.materials.items():
            self.assertEqual((self.checkpoint / name).read_bytes(), content, name)
        return data

    def count(self, operation):
        return self.trace.read_text().splitlines().count(operation)

    def after_source_exit(self):
        self.call('rollback')
        self.assert_phase('ROLLED_BACK_REBOOT_REQUIRED')
        self.call('continue', expected=2)
        self.boot.write_text('first-reboot\n')

    def target_rollback(self):
        result = subprocess.run(['bash', str(self.checkpoint / 'target-profile.sh'), 'rollback'],
                                env=dict(self.env, PURGE_CREATED_SWAP='1'), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse(self.state_file.exists())

    def test_source_rollback_failure_resumes_with_or_without_state(self):
        flag = self.base / 'fail-rollback'
        flag.write_text('retained')
        self.call('rollback', expected=41)
        self.assert_phase('ROLLBACK_RUNNING')
        self.assertEqual(self.state_file.read_bytes(), self.source_bytes)
        self.call('continue', expected=2)
        # 第二次中断发生于来源已清掉 state、迁移器尚未记录 boot gate。
        flag.write_text('removed')
        self.call('rollback', expected=41)
        self.assert_phase('ROLLBACK_RUNNING')
        self.assertFalse(self.state_file.exists())
        flag.unlink()
        self.call('rollback')
        self.assert_phase('ROLLED_BACK_REBOOT_REQUIRED')
        self.assertEqual(self.count('source:rollback'), 2)
        self.call('continue', expected=2)
        self.assertEqual(self.count('target:apply'), 0)

    def test_apply_failure_retries_only_after_state_exit(self):
        self.after_source_exit()
        flag = self.base / 'fail-apply'
        flag.write_text('absent')
        self.call('continue', expected=42)
        before = self.assert_phase('APPLY_RUNNING')['post_reboot_sysctls']
        self.assertFalse(self.state_file.exists())
        flag.write_text('applied')
        self.call('continue', expected=42)
        self.assert_phase('APPLY_RUNNING')
        self.assertEqual(json.loads(self.state_file.read_text())['state'], 'APPLIED')
        self.call('continue', expected=2)
        self.assertEqual(self.count('target:apply'), 2)
        self.target_rollback()
        flag.unlink()
        self.call('continue')
        after = self.assert_phase('TARGET_APPLIED_REBOOT_REQUIRED')['post_reboot_sysctls']
        self.assertEqual(before, after)
        self.assertEqual(self.count('target:apply'), 3)
        self.call('continue', expected=2)
        self.assertEqual(self.count('target:verify'), 0)
        self.boot.write_text('second-reboot\n')
        self.call('continue')
        self.assert_phase('COMPLETE', active=False)

    def test_strict_verify_failure_retries_without_reapplying(self):
        self.after_source_exit()
        self.call('continue')
        self.boot.write_text('second-reboot\n')
        flag = self.base / 'fail-verify'
        flag.touch()
        before = self.state_file.read_bytes()
        self.call('continue', expected=43)
        self.assert_phase('VERIFY_RUNNING')
        self.assertEqual(self.state_file.read_bytes(), before)
        self.call('continue', expected=43)
        self.assert_phase('VERIFY_RUNNING')
        flag.unlink()
        self.call('continue')
        self.assert_phase('COMPLETE', active=False)
        self.assertEqual(self.count('target:apply'), 1)
        self.assertEqual(self.count('target:verify'), 3)
        self.call('continue')
        self.assertEqual(self.count('target:verify'), 3)

    def test_late_target_exit_does_not_reapply_or_reopen_checkpoint(self):
        self.after_source_exit()
        self.call('continue')
        self.target_rollback()
        self.call('continue', expected=2)
        self.assert_phase('TARGET_APPLIED_REBOOT_REQUIRED')
        self.boot.write_text('second-reboot\n')
        # profile 明确拒绝缺失 state；真实迁移器不得重新 apply 或 COMPLETE。
        result = subprocess.run(['bash', str(self.checkpoint / 'dvt-migrate.sh'), 'continue',
                                 '--checkpoint', str(self.checkpoint)], env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assert_phase('VERIFY_RUNNING')
        self.assertEqual(self.count('target:apply'), 1)
        self.call('cancel', expected=2)
        self.assert_phase('VERIFY_RUNNING')


if __name__ == '__main__':
    unittest.main()
