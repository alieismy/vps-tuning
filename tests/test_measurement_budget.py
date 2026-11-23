"""测量父子预留与实际限速参数回归，运行真实函数并隔离网络调用。"""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
JQ = shutil.which('jq')
TEMPLATE = (ROOT / 'tools/profile-template.sh.in').read_text(encoding='utf-8')
PROBE = (ROOT / 'dvt-probe.sh').read_text(encoding='utf-8')
RUNNER = (ROOT / 'experiments/htb-aggregate/rate-sweep-run.sh').read_text(encoding='utf-8')
TCPQUALITY = (ROOT / 'tcpquality-evidence.sh').read_text(encoding='utf-8')


def function(source, name):
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S).group(0)


@unittest.skipUnless(BASH and JQ, 'Bash and jq are required')
class MeasurementBudget(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bridge = 'set -Eeuo pipefail\nPATH="/usr/bin:/bin:$PATH"\n' + (
            'jq() { ' + shlex.quote(JQ.replace('\\', '/')) +
            (' --binary' if os.name == 'nt' else '') + ' "$@"; }\n')
        self.estimator = function(TEMPLATE, 'benchmark_traffic_estimate_json') + '\n'

    def shell(self, code, expected=0):
        script = self.directory / 'run-fixture.sh'
        script.write_text(self.bridge + code, encoding='utf-8', newline='\n')
        result = subprocess.run([BASH, script.name],
                                cwd=self.directory, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stderr.decode(errors='replace'))
        return result.stdout.decode(errors='replace')

    def test_probe_parent_matches_child_reservations_for_all_directions_and_warmup_modes(self):
        code = self.estimator + function(PROBE, 'planned_payload_bytes') + '''
rate_cap=100
samples=2
seconds=5
for omit in 0 2; do
 for direction in upload download both; do
  parent=$(planned_payload_bytes)
  child=$(benchmark_traffic_estimate_json "$rate_cap" explicit "$seconds" "$omit" "$direction" "$((seconds + omit + 15))" 1 | jq -r '.reservation_bytes')
  printf '%s %s %s %s\\n' "$direction" "$omit" "$parent" "$child"
 done
done
'''
        for row in self.shell(code).splitlines():
            direction, omit, parent, child = row.split()
            self.assertEqual(int(parent), int(child) * 2)
            count = 2 if direction == 'both' else 1
            self.assertEqual(int(parent), (100 * 125000 * (5 + int(omit) + 20) + 1048576) * count * 2)

    def test_old_sweep_execution_reservation_matches_each_child_and_exceeds_nominal_plan(self):
        block = RUNNER.split('  planned_payload="$(jq -r ', 1)[1].split('\n  install -d ', 1)[0]
        block = 'planned_payload="$(jq -r ' + block
        plan = {'benchmark': {'seconds': 10, 'omit_seconds': 3, 'parallel': 2},
                'stages': [{'rate_cap_mbit': r} for r in (200, 150, 100)]}
        (self.directory / 'plan.json').write_text(json.dumps(plan))
        code = self.estimator + 'plan_file=plan.json\n' + block + '''
printf '%s\\n' "$planned_payload"
for rate in 200 150 100; do
 benchmark_traffic_estimate_json "$rate" explicit 10 3 upload 28 2 | jq -r '.reservation_bytes'
done
'''
        parent, *children = map(int, self.shell(code).splitlines())
        self.assertEqual(parent, sum(children))
        self.assertGreater(parent, sum((200, 150, 100)) * 125000 * 13)

    def benchmark_source(self):
        return self.estimator + function(TEMPLATE, 'run_network_benchmark') + '''
EXIT_USAGE=2
EXIT_UNSUPPORTED=3
EXIT_CONFLICT=4
EXIT_VERIFY=5
SCRIPT_VERSION=fixture
PROFILE_ID=fixture
STATE_FILE="$PWD/state.json"
BENCHMARK_TIMEOUT_TERMINATE_GRACE_SECONDS=5
DVT_TRAFFIC_BUDGET_BYPASS=1
ensure_required_tools() { :; }
check_supported_os() { :; }
info() { :; }
warn() { :; }
die() { exit "$1"; }
is_bool() { case "$1" in 0|1) return 0;; *) return 1;; esac; }
default_route_ifaces() { printf 'eth0\\n'; }
state_file_is_valid() { [ "${STATE_VALID:-0}" = 1 ]; }
sysctl() { printf 'fixture\\n'; }
iperf3() { printf 'iperf 3.fixture\\n'; }
setsid() { :; }
timeout() { :; }
benchmark_reap_active_child() { :; }
benchmark_handle_signal() { exit "$2"; }
detect_policy_routing() { POLICY_ROUTING_IPV4_STATE=false; POLICY_ROUTING_IPV6_STATE=false; }
show_policy_routing_evidence() { printf 'fixture\\n'; }
run_benchmark_phase() {
 local phase="$1" directory="$3"
 declare -p BENCHMARK_RATE_ARGS >"$directory/rate-args"
 printf '{"end":{"sum_sent":{"bytes":1000}}}\\n' >"$directory/$phase.iperf3.json"
 printf '{"sender":{"bytes":1000}}\\n' >"$directory/$phase.summary.json"
}
'''

    def test_old_sweep_records_verified_child_rate_cap_and_rejects_inconsistent_metadata(self):
        benchmark = self.directory / 'stage' / 'benchmark'
        benchmark.mkdir(parents=True)
        (benchmark / 'benchmark-result.json').write_text('{}')
        (self.directory / 'plan.json').write_text(json.dumps({'benchmark': {'parallel': 2}}))
        metadata = {'benchmark': {'rate_cap_enforced': True,
                                  'rate_cap_method': 'iperf3-bitrate',
                                  'rate_cap_scope': 'aggregate-target-divided-across-streams',
                                  'rate_cap_per_stream_bps': 100000000}}
        source = function(RUNNER, 'write_stage_result') + '''
plan_file=plan.json
managed_profile_id=fixture; managed_script_version=fixture
managed_state_sha256_frozen=fixture; tuning_script_sha256=fixture
die() { printf '%s\\n' "$*" >&2; exit 1; }
write_stage_result "$PWD/stage" '{"sequence":1,"label":"fixture","rate_cap_mbit":200}' before after
'''
        meta_file = benchmark / 'benchmark-meta.json'
        meta_file.write_text(json.dumps(metadata))
        self.shell(source)
        stage = json.loads((benchmark.parent / 'stage-result.json').read_text())
        self.assertEqual(stage['software_rate_cap'], metadata['benchmark'])
        mutations = ({}, {'rate_cap_enforced': False},
                     {'rate_cap_per_stream_bps': 200000000},
                     {'rate_cap_method': 'unverified'})
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                changed = {} if not mutation else {'benchmark': {**metadata['benchmark'], **mutation}}
                meta_file.write_text(json.dumps(changed))
                (benchmark.parent / 'stage-result.json').unlink()
                self.shell(source, expected=1)
                self.assertFalse((benchmark.parent / 'stage-result.json').exists())
                # 每轮失败保留临时文件，下一轮先重建通过的对照结果。
                meta_file.write_text(json.dumps(metadata))
                self.shell(source)

    def test_old_sweep_session_summary_uses_recorded_stage_controls(self):
        stages = self.directory / 'stages'
        for sequence, rate in ((1, 200000000), (2, 190000000)):
            stage = stages / str(sequence)
            stage.mkdir(parents=True)
            (stage / 'stage-result.json').write_text(json.dumps({
                'plan_stage': {'sequence': sequence, 'label': str(sequence)},
                'software_rate_cap': {'rate_cap_enforced': True,
                                      'rate_cap_method': 'iperf3-bitrate',
                                      'rate_cap_scope': 'aggregate-target-divided-across-streams',
                                      'rate_cap_per_stream_bps': rate}}))
        (self.directory / 'session-meta.json').write_text('{"software_rate_caps":[]}')
        snippet = RUNNER.split('  software_rate_caps="$(jq -s ', 1)[1].split(
            "  current_stage='budget-commit'", 1)[0]
        self.shell('output_dir="$PWD"\nsoftware_rate_caps="$(jq -s ' + snippet)
        result = json.loads((self.directory / 'session-meta.json').read_text())
        self.assertEqual([item['software_rate_cap']['rate_cap_per_stream_bps']
                          for item in result['software_rate_caps']], [200000000, 190000000])

    def test_default_cap_is_applied_and_explicit_timeout_is_budgeted(self):
        code = self.benchmark_source() + '''
BENCHMARK_HOST=fixture.invalid BENCHMARK_RATE_CAP_MBPS=200 BENCHMARK_PARALLEL=2 \\
 BENCHMARK_PHASE_TIMEOUT_SECONDS=40 BENCHMARK_OUTPUT_DIR="$PWD/output" run_network_benchmark >/dev/null
'''
        self.shell(code)
        meta = json.loads((self.directory / 'output/benchmark-meta.json').read_text())
        benchmark = meta['benchmark']
        self.assertTrue(benchmark['rate_cap_enforced'])
        self.assertEqual(benchmark['rate_cap_per_stream_bps'], 100000000)
        expected = (200 * 125000 * 45 + 2 * 1048576) * 2
        self.assertEqual(benchmark['traffic_estimate']['reservation_bytes'], expected)
        self.assertEqual(meta['traffic_budget']['planned_payload_bytes'], expected)
        self.assertIn('100000000', (self.directory / 'output/rate-args').read_text())

    def test_cap_can_use_verified_managed_state(self):
        (self.directory / 'state.json').write_text('{"state":"VERIFIED","network":{"port_speed_mbps":500}}')
        self.shell(self.benchmark_source() + '''
STATE_VALID=1 BENCHMARK_HOST=fixture.invalid BENCHMARK_OUTPUT_DIR="$PWD/output" run_network_benchmark >/dev/null
''')
        benchmark = json.loads((self.directory / 'output/benchmark-meta.json').read_text())['benchmark']
        self.assertEqual(benchmark['traffic_estimate']['cap_source'], 'managed-state')
        self.assertEqual(benchmark['rate_cap_per_stream_bps'], 500000000)

    def test_explicit_open_rate_is_rejected_before_output_or_traffic(self):
        self.shell(self.benchmark_source() + '''
BENCHMARK_HOST=fixture.invalid BENCHMARK_RATE_CAP_MBPS=200 BENCHMARK_ENFORCE_RATE_CAP=0 \\
 BENCHMARK_OUTPUT_DIR="$PWD/output" run_network_benchmark
''', expected=2)
        self.assertFalse((self.directory / 'output').exists())

    def test_preparation_failure_precedes_reservation_for_probe_sweep_and_tcpquality(self):
        # 直接执行正式入口中创建目录和 reserve 的原始代码段，禁止网络入口参与测试。
        blocks = [
            (PROBE, '  if [ -z "$output_dir" ]; then', '  budget_reserved=1', 'mkdir', 'output_dir'),
            (RUNNER, '  install -d -o root -g root -m 0700 "$output_dir"', '  traffic_reserved=1', 'install', 'output_dir'),
            (TCPQUALITY, '  mkdir -m 0700 -- "$EVIDENCE_DIR"', '  TRAFFIC_RESERVED=1', 'mkdir', 'EVIDENCE_DIR')]
        for source, start, end, command, variable in blocks:
            with self.subTest(tool=variable, command=command):
                snippet = source.split(start, 1)[1].split(end, 1)[0]
                snippet = start + snippet
                code = '''
output_dir="$PWD/output"
EVIDENCE_DIR="$PWD/output"
DVT_TRAFFIC_BUDGET_TOOL=budget
budget_tool=budget
bash() { printf 'reserve\\n' >reserved; exit 91; }
mkdir() { return 71; }
install() { return 71; }
die() { exit 2; }
''' + snippet
                self.shell(code, expected=71)
                self.assertFalse((self.directory / 'reserved').exists())

    def probe_source(self):
        ownership = '''
id() { printf '0\\n'; }
stat() { case "$2" in '%u') printf '0\\n';; '%a') printf '700\\n';; *) command stat "$@";; esac; }
flock() { :; }
'''
        budget_source = (ROOT / 'dvt-traffic-budget.sh').read_text(encoding='utf-8')
        budget = self.directory / 'budget.sh'
        budget.write_text(budget_source.rsplit('\nmain "$@"', 1)[0] + '\n' +
                          self.bridge + ownership + '\nmain "$@"\n',
                          encoding='utf-8', newline='\n')
        (self.directory / 'tuning.sh').write_text('#!/usr/bin/env bash\nexit 0\n')
        return PROBE.rsplit('\nif [ "${BASH_SOURCE[0]}"', 1)[0] + '\n' + self.bridge + ownership + '''
env() {
 local arg destination=''
 for arg in "$@"; do
  case "$arg" in BENCHMARK_OUTPUT_DIR=*) destination="${arg#*=}";; esac
 done
 command mkdir "$destination"
 printf '{"end":{"sum_sent":{"bytes":5000}}}\\n' >"$destination/upload.iperf3.json"
 printf '{"status":"PASS","exit_code":0,"metadata":{"benchmark":{"rate_cap_enforced":true,"rate_cap_method":"iperf3-bitrate","traffic_estimate":{"cap_mbps":100}}},"phases":{"upload":{"measurement_window":{"valid":true},"sender":{"mbps":100,"bytes":5000,"retransmits":0,"retransmits_per_gib":0},"receiver":{"mbps":100},"host":{"tcp_delta":{"TcpRetransSegs":0}},"qdisc_active_totals":{"dropped_delta":0}}}}\\n' >"$destination/benchmark-result.json"
 (cd "$destination" && sha256sum benchmark-result.json >SHA256SUMS && : >COMPLETED)
}
'''

    def test_probe_parent_settlement_preserves_warmup_and_known_excess(self):
        for omit in (0, 2):
            with self.subTest(omit=omit):
                source = self.probe_source()
                self.shell(source + f'''
main --tuning-script "$PWD/tuning.sh" --profile-id fixture --host fixture.invalid \\
 --rate-cap 100 --samples 2 --seconds 5 --omit {omit} --direction upload \\
 --budget-mib 2048 --budget-tool "$PWD/budget.sh" --ledger "$PWD/ledger-{omit}.json" \\
 --window-id test --output-dir "$PWD/output-{omit}" --yes >/dev/null
''')
                ledger = json.loads((self.directory / f'ledger-{omit}.json').read_text())
                entry = ledger['entries'][0]
                expected = 10000 if omit == 0 else (100 * 125000 * 27 + 1048576) * 2
                self.assertEqual(entry['accounted_bytes'], expected)
                self.assertEqual(entry['actual_known_bytes'], 10000 if omit == 0 else None)
                self.assertEqual(ledger['reserved_bytes'], 0)

        source = self.probe_source() + '''
env() {
 local arg destination=''
 for arg in "$@"; do
  case "$arg" in BENCHMARK_OUTPUT_DIR=*) destination="${arg#*=}";; esac
 done
 command mkdir "$destination"
 printf '{"end":{"sum_sent":{"bytes":2000000000}}}\\n' >"$destination/upload.iperf3.json"
 return 73
}
main --tuning-script "$PWD/tuning.sh" --profile-id fixture --host fixture.invalid \\
 --rate-cap 100 --samples 2 --seconds 5 --omit 0 --direction upload \\
 --budget-mib 2048 --budget-tool "$PWD/budget.sh" --ledger "$PWD/failed-ledger.json" \\
 --window-id test --output-dir "$PWD/failed-output" --yes >/dev/null
'''
        self.shell(source, expected=73)
        entry = json.loads((self.directory / 'failed-ledger.json').read_text())['entries'][0]
        self.assertEqual(entry['accounted_bytes'], 2000000000)
        self.assertEqual(entry['status'], 'FAILED_CONSERVATIVE')


if __name__ == '__main__':
    unittest.main()
