"""独立测量的离线契约与故障注入；不访问公网、不改变内核配置。"""
import copy
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch, Mock
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dvt_measure", ROOT / "dvt-measure.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def args(**values):
    base = dict(rate_cap=20, samples=3, seconds=5, max_attempts=4, host=None,
                max_duration=300, budget_mib=600, family="auto", output_dir="", ledger="/ledger", window_id="test")
    base.update(values)
    return type("Args", (), base)()


ENDPOINT = dict(id="fixture", host="test.invalid", ip="192.0.2.1", family=4, port=5201)
ROUTE = dict(dev="eth0", gateway=None, prefsrc="192.0.2.2", src=None, table=None)


def row(role, rate, retrans=0, **values):
    result = dict(role=role, rate_mbps=rate, endpoint=ENDPOINT.copy(), route=ROUTE.copy(),
                  eligible=True, issues=[], sender=dict(bytes=rate * 625000, mbps=rate, retransmits_per_gib=retrans),
                  receiver=dict(mbps=rate))
    result.update(values)
    return result


def full_rows(plan):
    return [row(role, rate) for role, rate in plan["schedule"]]


def write_sample(directory, rate=20):
    directory.mkdir()
    sender = dict(bytes=rate * 625000, mbps=rate, retransmits=0, retransmits_per_gib=0)
    summary = dict(sender=sender, receiver=dict(mbps=rate), measurement_window=dict(valid=True, issues=[]),
                   qdisc_health=dict(any_drop_or_requeue=False))
    raw = dict(start=dict(connected=[dict(remote_host=ENDPOINT["ip"], remote_port=5201, local_host="192.0.2.2", local_port=40000)]),
               end=dict(cpu_utilization_percent=dict(host_total=10, remote_total=10), streams=[dict(sender=dict(mean_rtt=800))]))
    m.write_json(directory / "upload.summary.json", summary)
    m.write_json(directory / "upload.iperf3.json", raw)
    for when, cpu, softnet in (("before", "idle\t100\nsteal\t0\nuser\t10\n", "0\t100\t0\t0\n"),
                               ("after", "idle\t200\nsteal\t0\nuser\t20\n", "0\t200\t0\t0\n")):
        (directory / f"upload.cpu.{when}").write_text(cpu)
        (directory / f"upload.softnet.{when}").write_text(softnet)


class MeasurementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.plan = m.make_plan(args(), [])

    def tearDown(self):
        self.tmp.cleanup()

    def test_plan_needs_no_linux_root_network_or_write(self):
        with patch.object(m, "bounded", side_effect=AssertionError("network")), patch.object(m, "write_json", side_effect=AssertionError("write")), redirect_stdout(io.StringIO()):
            for cap in (1, 10, 20, 50, 2500, 10000):
                self.assertEqual(m.main(["measure", "--rate-cap", str(cap), "--plan-only"]), 0)
        self.assertEqual(self.plan["rates_mbps"], [2, 5, 10, 15, 20])
        self.assertGreater(self.plan["worst_case_reservations_bytes"], 0)

    def test_catalog_sources_ports_and_invalid_records(self):
        catalog = m.load_catalog(ROOT / "measurement-endpoints.json")
        self.assertEqual({e["provider"] for e in catalog}, {"Leaseweb", "Clouvider"})
        for e in catalog:
            self.assertEqual(e["ports"], list(range(5201, 5211)) if e["provider"] == "Leaseweb" else list(range(5200, 5210)))
        for change in (lambda c: c[0].update(ports=[0]), lambda c: c[0].update(ports=[5201, 5201]),
                       lambda c: c[0].update(host="--bad"), lambda c: c[0].update(source="file:///bad"),
                       lambda c: c.append(c[0])):
            data = copy.deepcopy(catalog)
            change(data)
            p = self.root / "catalog.json"
            m.write_json(p, dict(schema_version=1, endpoints=data))
            with self.assertRaises(m.MeasurementError):
                m.load_catalog(p)

    def test_reservation_covers_timeout_and_cleanup_windows(self):
        self.assertGreaterEqual(m.reservation_bytes(100, 5), 100 * 125000 * (5 + 10 + 8 + 5))
        expected = self.plan["max_attempts"] * m.reservation_bytes(1, self.plan["seconds"])
        expected += sum(m.reservation_bytes(rate, self.plan["seconds"]) for _, rate in self.plan["schedule"])
        self.assertEqual(self.plan["worst_case_reservations_bytes"], expected)

    def test_icmp_failure_mapped_ipv6_and_private_public_rejection(self):
        item = dict(id="one", host="example.invalid", ports=[5200], provider="public", families=[4, 6])
        responses = [dict(returncode=0, stdout=json.dumps(["::ffff:8.8.8.8", "8.8.8.8", "127.0.0.1"]), stderr=""),
                     dict(returncode=1, stdout="", stderr="filtered")]
        with patch.object(m, "bounded", side_effect=responses):
            d = m.discover_one(item, "auto")
        self.assertEqual(len(d["addresses"]), 1)
        self.assertEqual(d["addresses"][0]["ip"], "8.8.8.8")
        self.assertIsNone(d["addresses"][0]["rtt_ms"])
        candidates = m.candidates_from([d], [item], 4)
        self.assertEqual([(e["family"], e["port"]) for e in candidates], [(4, 5200)])

    def test_discovery_dns_timeout_and_rtt_order(self):
        item = dict(id="one", host="example.invalid", ports=[5201, 5202], provider="user", families=[4, 6])
        with patch.object(m, "bounded", return_value=dict(returncode=-1, stdout="", stderr="timeout")):
            self.assertEqual(m.discover_one(item, "4")["addresses"], [])
        two = dict(item, id="two", ports=[5200])
        d = [dict(id="one", addresses=[dict(ip="192.0.2.1", family=4, rtt_ms=None)]),
             dict(id="two", addresses=[dict(ip="192.0.2.2", family=4, rtt_ms=2)])]
        self.assertEqual([(c["id"], c["port"]) for c in m.candidates_from(d, [item, two], 4)],
                         [("two", 5200), ("one", 5201), ("one", 5202)])

    def test_route_is_to_endpoint_and_records_ipv6(self):
        endpoint = dict(ENDPOINT, ip="2001:db8::1", family=6)
        with patch.object(m, "bounded", return_value=dict(returncode=0, stdout=json.dumps([ROUTE]))) as command:
            self.assertEqual(m.route_for(endpoint), ROUTE)
        self.assertIn("-6", command.call_args.args[0])
        self.assertIn("2001:db8::1", command.call_args.args[0])
        self.assertEqual(command.call_args.args[0][-4:], ["ipproto", "tcp", "dport", "5201"])

    def test_analysis_clean_confirmed_isolated_spike_and_underload(self):
        rows = full_rows(self.plan)
        self.assertEqual(m.analyze(rows, self.plan, None)["status"], "NO_RISE_IN_TESTED_RANGE")
        high = [r for r in rows if r["rate_mbps"] == 20]
        high[0]["sender"]["retransmits_per_gib"] = 1000
        self.assertIsNone(m.analyze(rows, self.plan, None)["candidate_interval"])
        high[1]["sender"]["retransmits_per_gib"] = 1000
        report = m.analyze(rows, self.plan, None)
        self.assertEqual(report["candidate_interval"], dict(lower_mbps=15, upper_mbps=20))
        self.assertFalse(report["policer_identified"])
        high[2].update(eligible=False, issues=["UNDERDRIVEN"])
        self.assertEqual(m.analyze(rows, self.plan, None)["status"], "INSUFFICIENT_EVIDENCE")

    def test_analysis_missing_reference_dirty_control_path_change_budget(self):
        rows = full_rows(self.plan)
        self.assertIn("INVALID_CONTROL", m.analyze(rows[:-1], self.plan, None)["issues"])
        for r in rows[-3:]:
            r["sender"]["retransmits_per_gib"] = 500
        self.assertIn("CONTROL_DRIFT", m.analyze(rows, self.plan, None)["issues"])
        rows[0]["endpoint"] = dict(ENDPOINT, port=5202)
        self.assertIn("PATH_CHANGED", m.analyze(rows, self.plan, None)["issues"])
        self.assertIsNone(m.analyze(rows, self.plan, "BUDGET_LIMIT")["candidate_interval"])

    def test_sample_gate_load_window_endpoint_and_resources(self):
        d = self.root / "sample"
        write_sample(d)
        good = m.sample_row(d, "sweep", 20, ENDPOINT, ROUTE)
        self.assertTrue(good["eligible"])
        self.assertEqual(good["loaded_mean_rtt_ms"], .8)
        summary = m.read_json(d / "upload.summary.json")
        summary["sender"]["mbps"] = 10
        m.write_json(d / "upload.summary.json", summary)
        self.assertIn("UNDERDRIVEN", m.sample_row(d, "sweep", 20, ENDPOINT, ROUTE)["issues"])
        raw = m.read_json(d / "upload.iperf3.json")
        raw["end"]["cpu_utilization_percent"]["host_total"] = 95
        m.write_json(d / "upload.iperf3.json", raw)
        self.assertIn("CPU_PRESSURE", m.sample_row(d, "sweep", 20, ENDPOINT, ROUTE)["issues"])
        raw["start"]["connected"][0]["remote_port"] = 5202
        m.write_json(d / "upload.iperf3.json", raw)
        with self.assertRaises(m.MeasurementError):
            m.sample_row(d, "sweep", 20, ENDPOINT, ROUTE)

    def test_evidence_integrity_and_traversal(self):
        (self.root / "INCOMPLETE").touch()
        m.write_json(self.root / "measurement-result.json", dict(schema=m.SCHEMA))
        m.write_json(self.root / "plan.json", self.plan)
        m.finalize_evidence(self.root)
        self.assertEqual(m.verify_report(self.root)["schema"], m.SCHEMA)
        (self.root / "plan.json").write_text("tampered")
        with self.assertRaises(m.MeasurementError):
            m.verify_report(self.root)
        (self.root / "SHA256SUMS").write_text("a" * 64 + "  ../outside\n")
        (self.root / "COMPLETED").write_text("evidence_manifest_sha256=" + m.sha(self.root / "SHA256SUMS") + "\n")
        with self.assertRaises(m.MeasurementError):
            m.verify_report(self.root)

    def make_run(self):
        run = m.MeasurementRun(args(output_dir=str(self.root / "run")), self.plan)
        run.output.mkdir()
        calls = []
        def budget(action, *extra):
            calls.append(action)
            if action == "status":
                return dict(window_id="test", budget_bytes=600 * 1048576, remaining_bytes=600 * 1048576)
            return dict(reservation=dict(status="COMMITTED"))
        run.budget = Mock(side_effect=budget)
        return run, calls

    def test_attempt_reserves_before_process_and_commits(self):
        run, calls = self.make_run()
        def process(command, **kwargs):
            self.assertEqual(calls[-1], "reserve")
            write_sample(Path(command[-1]))
            return Mock(wait=Mock(return_value=0))
        with patch.object(m, "route_for", return_value=ROUTE), patch.object(m.subprocess, "Popen", side_effect=process), redirect_stdout(io.StringIO()):
            result = run.attempt(ENDPOINT, "sweep", 20)
        self.assertTrue(result["eligible"])
        self.assertEqual(calls, ["status", "reserve", "commit"])
        self.assertIsNone(run.reservation)

    def test_budget_exhaustion_never_starts_process(self):
        run, _ = self.make_run()
        run.budget = Mock(return_value=dict(window_id="test", budget_bytes=600 * 1048576, remaining_bytes=1))
        with patch.object(m, "route_for", return_value=ROUTE), patch.object(m.subprocess, "Popen") as child:
            with self.assertRaises(m.StopMeasurement):
                run.attempt(ENDPOINT, "sweep", 20)
            child.assert_not_called()

    def test_actual_socket_route_change_stops_after_accounting(self):
        run, calls = self.make_run()
        def process(command, **kwargs):
            write_sample(Path(command[-1]))
            return Mock(wait=Mock(return_value=0))
        with patch.object(m, "route_for", side_effect=[ROUTE, ROUTE, dict(ROUTE, dev="eth1")]), patch.object(m.subprocess, "Popen", side_effect=process), redirect_stdout(io.StringIO()):
            with self.assertRaises(m.MeasurementInvalid):
                run.attempt(ENDPOINT, "sweep", 20)
        self.assertEqual(calls, ["status", "reserve", "commit"])
        self.assertIsNone(run.reservation)
        self.assertEqual(run.events[-1]["socket_route"]["dev"], "eth1")

    def test_rate_cap_violation_is_fatal_and_accounted(self):
        run, calls = self.make_run()
        def process(command, **kwargs):
            directory = Path(command[-1])
            write_sample(directory, rate=30)
            return Mock(wait=Mock(return_value=0))
        with patch.object(m, "route_for", return_value=ROUTE), patch.object(m.subprocess, "Popen", side_effect=process), redirect_stdout(io.StringIO()):
            with self.assertRaises(m.MeasurementInvalid):
                run.attempt(ENDPOINT, "sweep", 20)
        self.assertEqual(calls, ["status", "reserve", "commit"])
        self.assertIn("RATE_CAP_NOT_OBSERVED", run.events[-1]["issues"])

    def test_busy_failure_conservative_settlement(self):
        run, calls = self.make_run()
        with patch.object(m, "route_for", return_value=ROUTE), patch.object(m.subprocess, "Popen", return_value=Mock(wait=Mock(return_value=1))), redirect_stdout(io.StringIO()):
            with self.assertRaises(m.MeasurementError):
                run.attempt(ENDPOINT, "discovery", 1)
        self.assertEqual(calls, ["status", "reserve", "fail"])
        self.assertEqual(run.events[-1]["status"], "FAILED")

    def test_interrupt_reaps_only_owned_child_and_settles(self):
        run, calls = self.make_run()
        child = Mock(pid=12345, wait=Mock(side_effect=[KeyboardInterrupt(), 0]), poll=Mock(return_value=None))
        with patch.object(m, "route_for", return_value=ROUTE), patch.object(m.subprocess, "Popen", return_value=child), redirect_stdout(io.StringIO()):
            with self.assertRaises(KeyboardInterrupt):
                run.attempt(ENDPOINT, "sweep", 20)
        child.terminate.assert_called_once()
        self.assertEqual(calls, ["status", "reserve", "fail"])
        self.assertIsNone(run.active)

    def test_settlement_failure_blocks_subsequent_attempts(self):
        run, _ = self.make_run()
        original = run.budget.side_effect
        def budget(action, *extra):
            if action == "fail":
                raise m.MeasurementError("storage unavailable")
            return original(action, *extra)
        run.budget.side_effect = budget
        with patch.object(m, "route_for", return_value=ROUTE), patch.object(m.subprocess, "Popen", return_value=Mock(wait=Mock(return_value=1))), redirect_stdout(io.StringIO()):
            with self.assertRaises(m.MeasurementError):
                run.attempt(ENDPOINT, "sweep", 20)
        self.assertIsNotNone(run.reservation)
        self.assertIn("settlement_error", run.events[0])

    def test_no_managed_detection_before_independent_dispatch(self):
        if not m.shutil.which("bash"):
            self.skipTest("Bash unavailable")
        controller = (ROOT / "debian-vps-tuning.sh").as_posix()
        # 测试真实 main，使用函数替身证明高资源/Ubuntu/ARM 等不会走 profile gate。
        script = f'''source '{controller}'
need_root() {{ exit 91; }}
detect_environment() {{ exit 92; }}
need_command() {{ :; }}
resolve_companion_assets() {{ MEASUREMENT_PATH=fixture; }}
python3() {{ printf '%s\\n' "$*"; }}
main measure --rate-cap 20 --plan-only
'''
        result = subprocess.run([m.shutil.which("bash")], input=script.encode(), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout.splitlines(), [b"fixture", b"measure", b"--rate-cap", b"20", b"--plan-only"])

    def test_internal_runtime_cannot_start_without_reservation(self):
        if not m.shutil.which("bash"):
            self.skipTest("Bash unavailable")
        env = {key: value for key, value in os.environ.items() if key not in ("DVT_TRAFFIC_LEDGER", "DVT_MEASURE_RESERVATION")}
        # 参数有效；缺少父层预留时应在 mkdir/任何 iperf3 调用之前拒绝。
        output = "/dvt-test-no-budget-" + m.uuid.uuid4().hex
        result = subprocess.run([m.shutil.which("bash"), str(ROOT / "dvt-measure-runtime.sh"),
                                 "192.0.2.1", "5201", "4", "eth0", "20", "5", "20000000", "131072", output],
                                capture_output=True, env=env)
        self.assertEqual(result.returncode, 2)
        self.assertIn("budget reservation", result.stderr.decode(errors="replace"))

    def test_htb_take_bounds_short_window_backlog_without_reducing_reservation(self):
        a = args(rate_cap=5, lower=1, upper=4, interface="eth0", fine_step=1,
                 output_dir=str(self.root / 'bounded'))
        run = m.HTBMeasurementRun(a, m.make_htb_plan(a, []))
        run.output.mkdir()
        run.transaction = Mock(assert_active=Mock())
        run.budget = Mock(return_value=dict(window_id=a.window_id,
            budget_bytes=run.plan['window_budget_bytes'], remaining_bytes=10**9))
        commands = []
        def process(command, **kwargs):
            commands.append(command)
            write_sample(Path(command[-1]), rate=2)
            return Mock(wait=Mock(return_value=0))
        with patch.object(m, 'route_for', return_value=ROUTE), patch.object(m.subprocess, 'Popen', side_effect=process), redirect_stdout(io.StringIO()):
            run.take(ENDPOINT, ROUTE, 'sweep', 2)
        # 2 Mbps 的短窗不再持续按 5 Mbps 向 socket 入队；不缩小 TCP window。
        self.assertEqual(commands[0][-3:-1], ['2000000', '12500'])
        reservation = next(c for c in run.budget.call_args_list if c.args[0] == 'reserve')
        self.assertEqual(reservation.args[-1], m.reservation_bytes(5, 5))
        self.assertEqual(run.rows[0]['offered_rate_mbps'], 2)
        self.assertEqual(run.rows[0]['write_block_bytes'], 12500)

    def test_full_flow_failover_and_complete_report(self):
        output = self.root / "full"
        run = m.MeasurementRun(args(output_dir=str(output)), self.plan)
        run.budget = Mock(return_value=dict(status="OPEN"))
        attempt_count = 0
        def attempt(endpoint, role, rate):
            nonlocal attempt_count
            attempt_count += 1
            if attempt_count == 1:
                raise m.MeasurementError("busy")
            return row(role, rate, endpoint=endpoint)
        run.attempt = attempt
        observations = {"observations": {key: dict(status="available", stdout="fixed") for key in
                                       ("qdisc", "classes", "congestion_control", "default_qdisc")}}
        with patch.object(m, "diagnose", return_value=observations), patch.object(m, "bounded", return_value={}), patch.object(m, "candidates_from", return_value=[ENDPOINT, dict(ENDPOINT, port=5202)]), patch.object(m, "route_for", return_value=ROUTE), redirect_stdout(io.StringIO()):
            result = run.run()
        self.assertEqual(result["endpoint"]["port"], 5202)
        self.assertEqual(result["analysis"]["status"], "NO_RISE_IN_TESTED_RANGE")
        self.assertEqual(m.verify_report(output)["schema"], m.SCHEMA)
        self.assertFalse((output / "INCOMPLETE").exists())

    def test_configuration_drift_and_missing_observation(self):
        before = {"observations": {key: dict(status="available", stdout="fixed") for key in
                                   ("qdisc", "classes", "congestion_control", "default_qdisc")}}
        after = copy.deepcopy(before)
        self.assertEqual(m.compare_configuration(before, after)["status"], "UNCHANGED")
        after["observations"]["classes"]["stdout"] = "changed"
        self.assertEqual(m.compare_configuration(before, after)["changed_fields"], ["classes"])
        after = copy.deepcopy(before)
        after["observations"]["qdisc"]["status"] = "unavailable"
        self.assertEqual(m.compare_configuration(before, after)["status"], "UNAVAILABLE")

    def test_discovery_rate_or_path_violation_stops_without_failover(self):
        output = self.root / 'invalid-discovery'
        run = m.MeasurementRun(args(output_dir=str(output)), self.plan)
        run.budget = Mock(return_value=dict(status='OPEN'))
        run.attempt = Mock(side_effect=m.MeasurementInvalid('rate or path changed'))
        with patch.object(m, 'diagnose', return_value={}), patch.object(m, 'bounded', return_value={}), patch.object(m, 'candidates_from', return_value=[ENDPOINT, dict(ENDPOINT, port=5202)]), redirect_stdout(io.StringIO()), self.assertRaises(m.MeasurementInvalid):
            run.run()
        self.assertEqual(run.attempt.call_count, 1)
        self.assertFalse((output / 'COMPLETED').exists())

    def test_migration_version_gate_accepts_rc19_to_new_line(self):
        if not m.shutil.which("bash"):
            self.skipTest("Bash unavailable")
        source = (ROOT / "dvt-migrate.sh").read_text(encoding="utf-8")
        prepare = re.search(r"^prepare\(\) \{.*?^\}", source, re.M | re.S).group()
        for version, expected in (("0.1.0-rc.19", "当前 managed state"),
                                  ("0.1.0-rc.20", "本版迁移器只接受"),
                                  ("0.2.0-rc.1", "本版迁移器只接受")):
            script = f'''set -euo pipefail
die() {{ printf '%s\\n' "$*"; exit 2; }}
validate_file() {{ :; }}
{prepare}
checkpoint='/dvt-test-nonexistent-{m.uuid.uuid4().hex}'
source_profile=unused target_profile=unused
source_version='{version}' target_version='0.2.0-rc.2'
profile_id=debian13-1c1g port_mbps=200
state_sha256='{'a' * 64}' STATE_FILE='/dvt-test-nonexistent-state-{m.uuid.uuid4().hex}'
prepare
'''
            result = subprocess.run([m.shutil.which("bash")], input=script.encode(), capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn(expected, result.stdout.decode())

    def test_ledger_schema_preserves_rc19_window_and_rejects_unknown(self):
        if not m.shutil.which("bash") or not m.shutil.which("jq"):
            self.skipTest("Bash/jq unavailable")
        source = (ROOT / "dvt-traffic-budget.sh").read_text(encoding="utf-8")
        validate = re.search(r"^validate_ledger_json\(\) \{.*?^\}", source, re.M | re.S).group()
        p = self.root / "ledger.json"
        for version, expected in (("0.1.0-rc.19", 0), ("0.2.0-rc.1", 0), ("0.2.0-rc.2", 2)):
            m.write_json(p, dict(schema_version=1, tool_version=version, window_id="test", budget_bytes=1000,
                                 reserved_bytes=0, accounted_bytes=900,
                                 entries=[dict(status="COMMITTED", planned_bytes=1000, accounted_bytes=900)]))
            before = p.read_bytes()
            script = f'''set -euo pipefail
die() {{ exit 2; }}
SCHEMA_VERSION=1
ledger='{p.as_posix()}'
{validate}
validate_ledger_json
'''
            result = subprocess.run([m.shutil.which("bash")], input=script.encode(), capture_output=True)
            self.assertEqual(result.returncode, expected, result.stderr.decode(errors="replace"))
            self.assertEqual(p.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
