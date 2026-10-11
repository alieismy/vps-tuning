"""旧状态升级回归：执行真实 profile 入口、预检和校验，隔离宿主探测与写入。"""

from pathlib import Path
import copy
import hashlib
import json
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
JQ = shutil.which('jq')
TARGET_VERSION = re.search(r"^CONTROLLER_VERSION='([^']+)'", (ROOT / 'debian-vps-tuning.sh').read_text(encoding='utf-8'), re.M)[1]
HOSTS = (
    (3, '0.1.0-rc.11', 'debian13-1c1g', 500),
    (4, '0.1.0-rc.12', 'debian13-1c1g', 100),
    (4, '0.1.0-rc.16', 'debian13-1c2g', 500),
    (4, '0.1.0-rc.12', 'debian13-1c2g', 200),
    (4, '0.1.0-rc.17', 'debian13-1c1g', 200),
)


def state_fixture(schema=4, version='0.1.0-rc.17', profile='debian13-1c1g', port=200):
    return dict(schema_version=schema, script_version=version, state='VERIFIED',
                profile={'id': profile}, network={'port_speed_mbps': port},
                original_sysctls={'net.ipv4.tcp_rmem': '4096', 'net.ipv4.tcp_wmem': '4096'},
                qdisc={'file': '/fixture/qdisc.json', 'sha256': 'a' * 64},
                swap={}, managed_files=[], timestamps={},
                provider_sysctl_transfer=dict(required=False, source_path='/etc/sysctl.conf',
                    backup_path='/var/lib/proxy-vps-tuning/provider-sysctl.conf.original',
                    original_sha256=None, backup_sha256=None, transferred_sha256=None,
                    original_uid=None, original_gid=None, original_mode=None,
                    keys=[], state='NOT_REQUIRED'))


def function(source, name):
    inline = re.search(r'^' + name + r'\(\) \{[^\n]*\}', source, re.M)
    return (inline or re.search(r'^' + name + r'\(\) \{.*?^\}', source, re.M | re.S))[0]


def definitions(source):
    assert source.count('\nmain "$@"') == 1
    return source.rsplit('\nmain "$@"', 1)[0]


@unittest.skipUnless(BASH and JQ, 'Bash and jq are required')
class UpdatePreflightTest(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.tmp'
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='update-preflight-', dir=scratch)
        self.work = Path(self.temp.name).resolve()
        self.assertEqual(self.work.parent, scratch.resolve())
        self.addCleanup(self.temp.cleanup)

    def write(self, name, content):
        (self.work / name).write_text(content, encoding='utf-8', newline='\n')

    def shell(self, script):
        return subprocess.run([BASH], input=script.encode(), cwd=self.work,
                              capture_output=True, timeout=20)

    def platform_stubs(self):
        # Windows 与非 root CI 只模拟文件元数据；实际 JSON/parser/入口/预检均保留。
        return ('PATH="$fixture_path"\n'
                'jq() { MSYS_NO_PATHCONV=1 ' + shlex.quote(JQ.replace('\\', '/')) + ' "$@"; }\n' + r'''
stat() { case "$2" in '%u') printf '%s\n' "${fixture_uid:-0}";; '%a') printf '600\n';; *) return 99;; esac; }
''')

    def profile_runner(self, profile='debian13-1c1g'):
        source = (ROOT / (profile + '-vps-tuning.sh')).read_text(encoding='utf-8')
        return 'fixture_path="$PATH"\n' + definitions(source) + '\n' + self.platform_stubs() + r'''
STATE_FILE='state.json'
SYSCTL_FILE='absent-sysctl'
JOURNAL_FILE='absent-journal'
FQ_HELPER='absent-fq-helper'
FQ_SERVICE='absent-fq-service'
XUI_DROPIN='absent-xui-dropin'
SWAP_FILE='absent-swap'
need_root() { printf 'ROOT_GATE_REACHED\n' >&2; }
acquire_lock() { :; }
ensure_required_tools() { :; }
check_supported_os() { :; }
check_resource_profile() { :; }
scan_sysctl_conflicts() { :; }
check_bbr_fq_capability() { :; }
validate_qdisc_topology() { :; }
check_swap_preconditions() { :; }
show_environment() { :; }
apply_settings() { die 98 UNEXPECTED_WRITE; }
rollback_internal() { die 98 UNEXPECTED_WRITE; }
reconfigure_port_settings() { die 98 UNEXPECTED_WRITE; }
recover_empty_legacy_state() { die 98 UNEXPECTED_WRITE; }
recover_incomplete_reconfigure() { die 98 UNEXPECTED_WRITE; }
verify_settings() { die 98 UNEXPECTED_OTHER_ACTION; }
show_status() { die 98 UNEXPECTED_OTHER_ACTION; }
show_diagnostics() { die 98 UNEXPECTED_OTHER_ACTION; }
run_network_benchmark() { die 98 UNEXPECTED_OTHER_ACTION; }
'''

    def run_profile(self, state, action='preflight', update=1, profile='debian13-1c1g', tail='', uid=0):
        raw = state if isinstance(state, str) else json.dumps(state)
        self.write('state.json', raw)
        runner = self.profile_runner(profile)
        if isinstance(state, dict):
            runner += f"PORT_SPEED_MBPS_INPUT='{state['network']['port_speed_mbps']}'\n"
        runner += f'UPDATE_PREFLIGHT={update}\nfixture_uid={uid}\n' + tail + '\n'
        runner += 'validate_state_file\n' if action == 'validate-state' else f'main {shlex.quote(action)}\n'
        result = self.shell(runner)
        self.assertEqual((self.work / 'state.json').read_text(encoding='utf-8'), raw)
        self.assertNotIn(b'UNEXPECTED_WRITE', result.stderr)
        return result

    def test_actual_preflight_accepts_all_five_historical_states(self):
        for schema, version, profile, port in HOSTS:
            with self.subTest(version=version, profile=profile, port=port):
                result = self.run_profile(state_fixture(schema, version, profile, port), profile=profile)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertIn('只读 update-preflight', result.stdout.decode())

    def test_normal_mode_keeps_version_boundary_and_names_the_versions(self):
        result = self.run_profile(state_fixture(), action='validate-state', update=0)
        self.assertEqual(result.returncode, 4)
        self.assertIn('0.1.0-rc.17', result.stderr.decode())
        self.assertIn(TARGET_VERSION, result.stderr.decode())
        result = self.run_profile(state_fixture(version=TARGET_VERSION), action='validate-state', update=0)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_update_flag_is_rejected_before_any_other_action(self):
        for action in ('apply', 'rollback', 'reconfigure', 'recover', 'verify', 'status', 'diagnose', 'benchmark'):
            with self.subTest(action=action):
                result = self.run_profile(state_fixture(), action=action)
                self.assertEqual(result.returncode, 2, result.stderr.decode())
                self.assertNotIn(b'ROOT_GATE_REACHED', result.stderr)
                self.assertIn('UPDATE_PREFLIGHT', result.stderr.decode())

    def test_read_only_compatibility_preserves_validation_and_phase_gates(self):
        base = state_fixture()
        variants = []
        for path, value in (('script_version', '0.1.0-rc.20'), ('script_version', '9.9.9-rc.1'),
                            ('schema_version', 99), ('state', 'DEGRADED')):
            state = copy.deepcopy(base)
            state[path] = value
            variants.append((path + ':' + str(value), state))
        wrong_profile = copy.deepcopy(base)
        wrong_profile['profile']['id'] = 'debian13-1c2g'
        variants.append(('profile', wrong_profile))
        bad_transfer = copy.deepcopy(base)
        bad_transfer['provider_sysctl_transfer']['source_path'] = '/unowned/sysctl.conf'
        variants.append(('provider-path', bad_transfer))
        missing_transfer = copy.deepcopy(base)
        del missing_transfer['provider_sysctl_transfer']
        variants.append(('provider-missing', missing_transfer))
        variants.extend((('empty', ''), ('multiple-json', json.dumps(base) + '\n' + json.dumps(base))))
        for label, state in variants:
            with self.subTest(label=label):
                self.assertEqual(self.run_profile(state).returncode, 4)
        self.assertEqual(self.run_profile(base, uid=1000).returncode, 4)
        self.assertEqual(self.run_profile(state_fixture(schema=3, version='0.1.0-rc.11'), update=0).returncode, 4)
        applied = copy.deepcopy(base)
        applied['state'] = 'APPLIED'
        result = self.run_profile(applied)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def run_controller_update(self, source_exit=0):
        self.write('state.json', json.dumps(state_fixture()))
        self.write('target.sh', self.profile_runner() + '\nmain "$@"\n')
        self.write('source.sh', f'#!/usr/bin/env bash\n[ "$1" = verify ] || exit 98\nexit {source_exit}\n')
        controller = (ROOT / 'debian-vps-tuning.sh').read_text(encoding='utf-8')
        script = 'set -Eeuo pipefail\n' + function(controller, 'run_update') + '\n' + r'''
info() { printf '[+] %s\n' "$*"; }
die() { exit "$1"; }
validate_port_speed() { [ "$1" = 200 ]; }
resolve_update_release() { UPDATE_TAG_SELECTED='vfixture'; }
resolve_installed_profile() { SOURCE_PROFILE_PATH='source.sh'; SOURCE_PROFILE_SHA256='source-fixture'; }
resolve_update_controller() { UPDATE_CONTROLLER_PATH='target.sh'; UPDATE_CONTROLLER_SHA256='target-fixture'; }
STATE_VERSION='0.1.0-rc.17'
STATE_PORT_SPEED_MBPS=200
PROFILE_FILE='debian13-1c1g-vps-tuning.sh'
REPOSITORY='fixture/repository'
EXIT_CONFLICT=4
run_update
'''
        before = (self.work / 'state.json').read_bytes()
        result = self.shell(script)
        self.assertEqual((self.work / 'state.json').read_bytes(), before)
        return result

    def test_controller_update_reaches_real_target_preflight(self):
        result = self.run_controller_update()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn('升级检查通过；系统配置未修改。', result.stdout.decode())
        self.assertIn('只有 checkpoint 为 PREPARED', result.stdout.decode())
        self.assertIn('TCP 原值不完整时停止', result.stdout.decode())

    def test_controller_stops_before_target_when_source_verify_fails(self):
        result = self.run_controller_update(source_exit=9)
        self.assertEqual(result.returncode, 9)
        self.assertNotIn(b'ROOT_GATE_REACHED', result.stderr)

    def test_migration_rejects_all_five_incomplete_originals_before_checkpoint(self):
        migrator = (ROOT / 'dvt-migrate.sh').read_text(encoding='utf-8')
        for schema, version, profile, port in HOSTS:
            with self.subTest(version=version, profile=profile, port=port):
                self.write('state.json', json.dumps(state_fixture(schema, version, profile, port)))
                self.write('source.sh', f"SCRIPT_VERSION='{version}'\nPROFILE_ID='{profile}'\nexit 98\n")
                self.write('target.sh', f"SCRIPT_VERSION='{TARGET_VERSION}'\nPROFILE_ID='{profile}'\nexit 98\n")
                before = (self.work / 'state.json').read_bytes()
                script = 'fixture_path="$PATH"\n' + definitions(migrator) + '\n' + self.platform_stubs()
                script += f"source_version='{version}'\ntarget_version='{TARGET_VERSION}'\nprofile_id='{profile}'\nport_mbps={port}\n"
                script += f"state_sha256='{hashlib.sha256(before).hexdigest()}'\n" + r'''
STATE_FILE='state.json'
source_profile="$PWD/source.sh"
target_profile="$PWD/target.sh"
checkpoint="$PWD/checkpoint"
install() { die UNEXPECTED_WRITE; }
prepare
'''
                result = self.shell(script)
                self.assertEqual(result.returncode, 2, result.stderr.decode())
                self.assertIn('来源状态缺少完整 TCP buffer 三元组', result.stderr.decode())
                self.assertEqual((self.work / 'state.json').read_bytes(), before)
                self.assertFalse((self.work / 'checkpoint').exists())


if __name__ == '__main__':
    unittest.main()
