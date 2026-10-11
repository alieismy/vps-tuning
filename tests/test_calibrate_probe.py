"""离线校准的完整摘要链 fixture；不创建网络连接或执行调优。"""

import copy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from calibrate_probe import EvidenceError, ProbeEvidence, analyze, manifest_entries
from render_profiles import PROFILES

NOW = datetime(2026, 9, 22, 12, tzinfo=timezone.utc)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fixture(root, mutate=lambda *_: None, profile="debian13-1c2g", port=1000, rtt=200000,
            direction="both", mutate_sample=lambda *_: None, manifest_files=lambda files: files):
    """生成和实际 probe 相同的双层 manifest/result/COMPLETED 结构。"""
    profile_values = PROFILES[profile + "-vps-tuning.sh"]
    rows, artifacts = [], {}
    directions = ("upload", "download") if direction == "both" else (direction,)
    for sample in (1, 2, 3):
        for phase in directions:
            seconds, mbps = 10, 180
            sent = {"bytes": int(mbps * 1e6 * seconds / 8), "seconds": seconds,
                    "bits_per_second": mbps * 1e6, "retransmits": 2}
            received = {k: v for k, v in sent.items() if k != "retransmits"}
            raw = {"start": {"test_start": {"protocol": "TCP", "num_streams": 1,
                       "reverse": int(phase == "download"), "duration": seconds, "omit": 2},
                    "connected": [{"remote_host": "192.0.2.1"}]},
                   "end": {"sum_sent": sent, "sum_received": received,
                           "streams": [{"sender": {"min_rtt": rtt, "mean_rtt": rtt + 1000,
                                                      "max_rtt": rtt + 2000}}]}}
            summary = {"schema_version": 3, "direction": phase, "reverse": phase == "download",
                       "measurement_window": {"valid": True},
                       "sender": dict(sent, mbps=mbps), "receiver": dict(received, mbps=mbps)}
            row = {"sample": sample, "direction": phase, "measurement_window_valid": True,
                   "sender_mbps": mbps, "receiver_mbps": mbps,
                   "sender_bytes": sent["bytes"], "sender_retransmits": 2,
                   "sender_retransmits_per_gib": 2 * 1073741824 / sent["bytes"]}
            artifacts[sample, phase] = (raw, summary, row)
            rows.append(row)
    network = {"port_speed_mbps": port, "buffer_max_bytes": 16777216, "target_rtt_ms": 200,
               "buffer_target_numerator": int(profile_values["BUFFER_TARGET_NUMERATOR"]),
               "buffer_target_denominator": int(profile_values["BUFFER_TARGET_DENOMINATOR"])}
    meta = {"schema_version": 1, "profile": profile, "utc": "2026-09-22T11:00:00Z",
            "script_version": "0.1.0-rc.18", "script_sha256": "a" * 64,
            "state": "VERIFIED", "boot_id": "fixture-boot", "state_network": network,
            "benchmark": {"host": "example.test", "port": 5201, "parallel": 1, "family": "4",
                          "direction": direction, "seconds": 10, "omit_seconds": 2, "rate_cap_enforced": True,
                          "rate_cap_method": "iperf3-bitrate", "traffic_estimate": {"cap_mbps": port}}}
    probe = {"schema_version": 1, "advisory_only": True, "status": "REVIEW_REQUIRED",
             "profile": profile, "endpoint": {"host": "example.test", "port": 5201},
             "traffic_control": {"enforced": True, "method": "iperf3-bitrate", "rate_cap_mbps": port},
             "samples": rows, "aggregates": {}}
    for phase in ("upload", "download"):
        phase_rows = [row for row in rows if row["direction"] == phase]
        probe["aggregates"][phase] = dict(
            samples=len(phase_rows), valid_windows=len(phase_rows),
            **{key + "_median": statistics.median(row[key] for row in phase_rows)
               for key in ("sender_mbps", "receiver_mbps", "sender_retransmits_per_gib")}
        ) if phase_rows else None
    mutate(artifacts, meta, probe)

    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        data = value if isinstance(value, bytes) else json.dumps(value).encode()
        path.write_bytes(data)

    def complete(path, result_name, files):
        manifest = "".join(f"{sha((path / name).read_bytes())}  {name}\n" for name in sorted(files)).encode()
        write(path / "SHA256SUMS", manifest)
        result = json.loads((path / result_name).read_bytes())
        if result_name == "benchmark-result.json":
            result["evidence_manifest_sha256"] = sha(manifest)
            write(path / result_name, result)
        write(path / "COMPLETED", (f"status=COMPLETED\nevidence_manifest_sha256={sha(manifest)}\n"
                                  f"result_sha256={sha((path / result_name).read_bytes())}\n").encode())

    for sample in (1, 2, 3):
        folder = root / f"sample-{sample:02d}"
        sample_meta = copy.deepcopy(meta)
        mutate_sample(sample, sample_meta, artifacts)
        write(folder / "benchmark-meta.json", sample_meta)
        phases = {"upload": None, "download": None}
        for phase in directions:
            raw, summary, _ = artifacts[sample, phase]
            write(folder / f"{phase}.iperf3.json", raw)
            write(folder / f"{phase}.summary.json", summary)
            phases[phase] = summary
        write(folder / "benchmark-result.json", {"schema_version": 1, "status": "PASS", "exit_code": 0,
                                                "metadata": sample_meta, "phases": phases})
        complete(folder, "benchmark-result.json", [p.name for p in folder.iterdir() if p.name != "benchmark-result.json"])
    write(root / "probe-result.json", probe)
    complete(root, "probe-result.json", manifest_files(
        [p.relative_to(root).as_posix() for p in root.rglob("*")
         if p.is_file() and p.name not in {"SHA256SUMS", "SHA256SUMS.tmp", "COMPLETED", "INCOMPLETE"}]))


class CalibrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def result(self, **kwargs):
        return analyze(self.root, "fixture-path", now=NOW, representative=True, **kwargs)

    def test_candidate_uses_declared_capacity_not_capped_observation(self):
        fixture(self.root)
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        result = self.result()
        up = result["directions"][0]
        self.assertEqual(up["decision"], "EXPERIMENT_CANDIDATE")
        self.assertEqual(up["candidate_buffer_max_bytes"], 67108864)
        self.assertEqual(up["declared_cap_bdp_bytes"], 25000000)
        self.assertEqual(up["loaded_min_rtt_ms"]["median"], 200)
        self.assertEqual(up["receiver_mbps"]["median"], 180)
        self.assertFalse(result["interpretation"]["provider_capacity_discovered"])
        self.assertNotIn("192.0.2.1", json.dumps(result))
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()})

    def test_supported_source_versions_preserve_report_and_evidence(self):
        for version in ("0.1.0-rc.17", "0.1.0-rc.18", "0.1.0-rc.19", "0.2.0-rc.1", "0.2.0-rc.2"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                fixture(root, profile="debian13-1c1g", port=200, direction="upload",
                        mutate=lambda d, m, p: m.update(script_version=version))
                before = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
                result = analyze(root, "fixture", True, now=NOW)
                self.assertEqual(result["source_script_version"], version)
                self.assertEqual(result["profile"], "debian13-1c1g")
                self.assertFalse(result["configuration_changed"])
                self.assertEqual(len(result["directions"]), 1)
                self.assertEqual(result["directions"][0]["decision"], "KEEP_CURRENT_CEILING")
                self.assertEqual(result["directions"][0]["candidate_buffer_max_bytes"], 16777216)
                self.assertEqual(before, {p: p.read_bytes() for p in root.rglob("*") if p.is_file()})

    def test_unreviewed_source_versions_remain_rejected(self):
        for version in ("0.1.0-rc.16", "0.1.0-rc.20"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                fixture(root, mutate=lambda d, m, p: m.update(script_version=version))
                with self.assertRaisesRegex(EvidenceError, "同一 VERIFIED 版本"):
                    analyze(root, "fixture", True, now=NOW)

    def test_rc17_requires_verified_and_identical_sample_bindings(self):
        for field, changed in (("script_version", "0.1.0-rc.18"),
                               ("script_sha256", "b" * 64), ("boot_id", "other-boot"),
                               ("state", "DEGRADED")):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                fixture(root, mutate=lambda d, m, p: m.update(script_version="0.1.0-rc.17"),
                        mutate_sample=lambda sample, meta, data:
                            meta.update({field: changed}) if sample == 3 else None)
                with self.assertRaisesRegex(EvidenceError, "同一 VERIFIED 版本"):
                    analyze(root, "fixture", True, now=NOW)

    @unittest.skipUnless(shutil.which("bash"), "Bash is required for producer manifest selection")
    def test_manifest_layout_matches_probe_producer(self):
        fixture(self.root)
        source = (Path(__file__).resolve().parents[1] / "dvt-probe.sh").read_text(encoding="utf-8")
        command = re.search(r"find \. -type f .*? -print0", source).group()
        selected = subprocess.run([shutil.which("bash"), "-c", "PATH=/usr/bin:/bin:$PATH\n" + command], cwd=self.root,
                                  capture_output=True, check=True, timeout=15).stdout
        producer_files = {name.decode().removeprefix("./") for name in selected.split(b"\0") if name}
        entries = manifest_entries((self.root / "SHA256SUMS").read_bytes())
        self.assertEqual(set(entries), producer_files)
        self.assertNotIn("sample-01/COMPLETED", entries)
        self.assertNotIn("sample-01/SHA256SUMS", entries)
        self.assertIn("sample-01/benchmark-result.json", entries)
        self.assertEqual(self.result()["directions"][0]["decision"], "EXPERIMENT_CANDIDATE")

    def test_unlisted_child_control_files_still_require_integrity(self):
        for case in ("missing-marker", "missing-manifest", "marker-result", "manifest",
                     "manifest-and-marker", "incomplete"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                fixture(root)
                child = root / "sample-01"
                if case == "missing-marker":
                    (child / "COMPLETED").unlink()
                elif case == "missing-manifest":
                    (child / "SHA256SUMS").unlink()
                elif case == "incomplete":
                    (child / "INCOMPLETE").touch()
                elif case == "marker-result":
                    marker = (child / "COMPLETED").read_text()
                    actual = sha((child / "benchmark-result.json").read_bytes())
                    (child / "COMPLETED").write_text(marker.replace(actual, "0" * 64))
                else:
                    manifest = (child / "SHA256SUMS").read_bytes()
                    changed = b"\n".join(reversed(manifest.splitlines())) + b"\n"
                    (child / "SHA256SUMS").write_bytes(changed)
                    if case == "manifest-and-marker":
                        marker = (child / "COMPLETED").read_text()
                        (child / "COMPLETED").write_text(marker.replace(sha(manifest), sha(changed)))
                expected = {"marker-result": "子样本结果摘要不符", "manifest": "子样本清单摘要不符",
                            "manifest-and-marker": "子样本未通过或结果没有绑定清单",
                            "incomplete": "子样本仍有 INCOMPLETE"}.get(case, "证据文件缺失")
                with self.assertRaisesRegex(EvidenceError, expected):
                    analyze(root, "fixture", True, now=NOW)

    def test_child_control_reads_count_toward_total_limit(self):
        fixture(self.root)
        evidence = ProbeEvidence(self.root)
        evidence.bytes_read = 256 * 1024 * 1024
        with self.assertRaisesRegex(EvidenceError, "256 MiB"):
            evidence.benchmark("sample-01")

    def test_keep_current_and_never_reduce(self):
        def mutate(_, meta, __):
            meta["state_network"]["buffer_max_bytes"] = 33554432
        fixture(self.root, mutate, port=200, rtt=20000)
        up = self.result()["directions"][0]
        self.assertEqual(up["decision"], "KEEP_CURRENT_CEILING")
        self.assertEqual(up["candidate_buffer_max_bytes"], 33554432)

    def test_resource_limit(self):
        fixture(self.root, profile="debian12-1c512m")
        up = self.result()["directions"][0]
        self.assertEqual(up["decision"], "RESOURCE_LIMITED")
        self.assertEqual(up["candidate_buffer_max_bytes"], 16777216)

    def test_adaptive_profile_does_not_inherit_static_calibration_budget(self):
        fixture(self.root, profile="ubuntu2404-adaptive")
        with self.assertRaisesRegex(EvidenceError, "实际内存上限"):
            self.result()

    def test_missing_reverse_rtt_does_not_borrow_upload_rtt(self):
        def mutate(data, *_):
            for (sample, phase), (raw, _, __) in data.items():
                if phase == "download":
                    raw["end"]["streams"] = []
        fixture(self.root, mutate)
        up, down = self.result()["directions"]
        self.assertEqual(up["decision"], "EXPERIMENT_CANDIDATE")
        self.assertEqual(down["decision"], "INSUFFICIENT_EVIDENCE")
        self.assertIsNone(down["candidate_buffer_max_bytes"])

    def test_representativeness_is_explicit(self):
        fixture(self.root)
        result = analyze(self.root, "fixture-path", now=NOW)
        self.assertEqual(result["directions"][0]["decision"], "INSUFFICIENT_EVIDENCE")

    def test_stale_evidence(self):
        fixture(self.root, lambda _, meta, __: meta.update(utc="2026-09-20T00:00:00Z"))
        self.assertIn("EVIDENCE_TIME_OUTSIDE_POLICY", self.result()["directions"][0]["issues"])

    def test_semantic_withholding(self):
        def invalid_window(data, _, probe):
            data[1, "upload"][1]["measurement_window"]["valid"] = False
            data[1, "upload"][2]["measurement_window_valid"] = False
            probe["aggregates"]["upload"]["valid_windows"] = 2
            probe["status"] = "REVIEW_BLOCKED"

        cases = [
            (invalid_window, "INVALID_MEASUREMENT_WINDOW"),
            (lambda d, m, p: d[1, "upload"][0]["start"]["connected"][0].update(remote_host="192.0.2.2"), "PATH_CHANGED_WITHIN_DIRECTION"),
            (lambda d, m, p: d[1, "upload"][0]["end"]["streams"][0]["sender"].update(min_rtt=0), "SENDER_RTT_UNAVAILABLE"),
            (lambda d, m, p: p.update(status="REVIEW_BLOCKED"), "PROBE_REVIEW_BLOCKED"),
        ]
        for mutate, issue in cases:
            with self.subTest(issue=issue), tempfile.TemporaryDirectory() as folder:
                fixture(Path(folder), mutate)
                result = analyze(folder, "fixture", True, now=NOW)
                self.assertIn(issue, result["directions"][0]["issues"])
                self.assertIsNone(result["directions"][0]["candidate_buffer_max_bytes"])

    def test_invalid_contract_rejected(self):
        cases = [
            lambda d, m, p: d[1, "upload"][1]["sender"].update(bytes=1),
            lambda d, m, p: p["samples"].append(copy.deepcopy(p["samples"][0])),
            lambda d, m, p: p["samples"].pop(),
            lambda d, m, p: m["benchmark"].update(parallel=2),
            lambda d, m, p: m["benchmark"].update(family="6"),
            lambda d, m, p: m.update(state="APPLIED"),
            lambda d, m, p: m.update(script_version="0.1.0-rc.99"),
            lambda d, m, p: m["state_network"].update(buffer_target_numerator=99),
            lambda d, m, p: m["state_network"].update(buffer_max_bytes=True),
        ]
        for index, mutate in enumerate(cases):
            with self.subTest(case=index), tempfile.TemporaryDirectory() as folder:
                fixture(Path(folder), mutate)
                with self.assertRaises(EvidenceError):
                    analyze(folder, "fixture", True, now=NOW)

    def test_last_outlier_cannot_be_omitted_even_with_adjusted_counts(self):
        def outlier(data, _, probe):
            for phase in ("upload", "download"):
                data[3, phase][0]["end"]["streams"][0]["sender"].update(
                    min_rtt=600000, mean_rtt=601000, max_rtt=602000)

        fixture(self.root, outlier)
        for result in self.result()["directions"]:
            self.assertIn("RTT_OUTSIDE_SUPPORTED_RANGE", result["issues"])
            self.assertIsNone(result["candidate_buffer_max_bytes"])
        for adjust_counts in (False, True):
            def omit(data, meta, probe):
                outlier(data, meta, probe)
                probe["samples"] = [row for row in probe["samples"] if row["sample"] != 3]
                if adjust_counts:
                    for aggregate in probe["aggregates"].values():
                        aggregate.update(samples=2, valid_windows=2)
            with self.subTest(adjust_counts=adjust_counts), tempfile.TemporaryDirectory() as folder:
                fixture(Path(folder), omit)
                with self.assertRaisesRegex(EvidenceError, "清单样本集合与引用不一致"):
                    analyze(folder, "fixture", True, now=NOW)

    def test_manifest_sample_set_must_match_references(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "sample-04").mkdir()
            (root / "sample-04/orphan.txt").write_text("fixture")
            fixture(root)
            with self.assertRaisesRegex(EvidenceError, "清单样本集合与引用不一致"):
                analyze(root, "fixture", True, now=NOW)
        fixture(self.root, manifest_files=lambda files: [f for f in files if not f.startswith("sample-03/")])
        with self.assertRaisesRegex(EvidenceError, "清单样本集合与引用不一致"):
            self.result()

    def test_aggregate_counts_and_directions_rejected(self):
        cases = [
            lambda d, m, p: p["aggregates"]["upload"].update(samples=2),
            lambda d, m, p: p["aggregates"]["download"].update(valid_windows=2),
            lambda d, m, p: p["aggregates"]["upload"].update(samples=3.0),
            lambda d, m, p: p["aggregates"]["upload"].update(valid_windows=True),
            lambda d, m, p: p["aggregates"].pop("download"),
            lambda d, m, p: p["aggregates"].update(download=None),
            lambda d, m, p: p.pop("aggregates"),
        ]
        for index, mutate in enumerate(cases):
            with self.subTest(case=index), tempfile.TemporaryDirectory() as folder:
                fixture(Path(folder), mutate)
                with self.assertRaisesRegex(EvidenceError, "aggregate"):
                    analyze(folder, "fixture", True, now=NOW)

    def test_row_window_flag_must_match_summary(self):
        for value in (False, 1, None):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as folder:
                fixture(Path(folder), lambda d, m, p: d[1, "upload"][2].update(measurement_window_valid=value))
                with self.assertRaisesRegex(EvidenceError, "窗口标记"):
                    analyze(folder, "fixture", True, now=NOW)

    def test_duration_and_omit_contract(self):
        for source, field, values in (
            ("raw", "duration", (120, None, "10", True, 0)),
            ("raw", "omit", (10, None, "2", True, -1)),
            ("meta", "seconds", (None, "10", True, 121)),
            ("meta", "omit_seconds", (None, "2", True, -1, 11)),
        ):
            for value in values:
                def mutate(data, meta, _):
                    obj = data[1, "upload"][0]["start"]["test_start"] if source == "raw" else meta["benchmark"]
                    if value is None:
                        obj.pop(field)
                    else:
                        obj[field] = value
                with self.subTest(source=source, field=field, value=value), tempfile.TemporaryDirectory() as folder:
                    fixture(Path(folder), mutate)
                    with self.assertRaisesRegex(EvidenceError, "时长|预热|测量上下文"):
                        analyze(folder, "fixture", True, now=NOW)

    def test_repeated_measurement_context_must_match(self):
        for field, raw_field, value in (("seconds", "duration", 11), ("omit_seconds", "omit", 3),
                                      ("family", None, "auto")):
            def change_sample(sample, meta, data):
                if sample != 3:
                    return
                meta["benchmark"][field] = value
                if raw_field:
                    for phase in ("upload", "download"):
                        raw, summary, _ = data[sample, phase]
                        raw["start"]["test_start"][raw_field] = value
                        if field == "seconds":
                            for raw_side, side in (("sum_sent", "sender"), ("sum_received", "receiver")):
                                raw["end"][raw_side]["seconds"] = value
                                raw["end"][raw_side]["bytes"] = int(180e6 * value / 8)
                                summary[side].update(raw["end"][raw_side])
                            data[sample, phase][2]["sender_bytes"] = raw["end"]["sum_sent"]["bytes"]
                            data[sample, phase][2]["sender_retransmits_per_gib"] = (
                                2 * 1073741824 / raw["end"]["sum_sent"]["bytes"])
            with self.subTest(field=field), tempfile.TemporaryDirectory() as folder:
                fixture(Path(folder), mutate_sample=change_sample)
                with self.assertRaisesRegex(EvidenceError, "重复样本的测量参数不一致"):
                    analyze(folder, "fixture", True, now=NOW)

    def test_single_direction_and_zero_omit_supported(self):
        def zero_omit(data, meta, _):
            meta["benchmark"]["omit_seconds"] = 0
            for raw, _, _ in data.values():
                raw["start"]["test_start"]["omit"] = 0
        for direction in ("upload", "download"):
            with self.subTest(direction=direction), tempfile.TemporaryDirectory() as folder:
                fixture(Path(folder), zero_omit, direction=direction)
                result = analyze(folder, "fixture", True, now=NOW)["directions"]
                self.assertEqual(len(result), 1)
                self.assertEqual(result[0]["direction"], direction)
                self.assertEqual(result[0]["decision"], "EXPERIMENT_CANDIDATE")
        fixture(self.root, lambda d, m, p: p["aggregates"].update(download={"samples": 0, "valid_windows": 0}),
                direction="upload")
        with self.assertRaisesRegex(EvidenceError, "aggregate"):
            self.result()

    def test_actual_window_tolerance_is_separate_from_requested_duration(self):
        for measured_seconds, expected in ((10.2, "EXPERIMENT_CANDIDATE"), (11, "INSUFFICIENT_EVIDENCE")):
            def actual_window(data, _, probe):
                for raw, summary, row in data.values():
                    for raw_side, side in (("sum_sent", "sender"), ("sum_received", "receiver")):
                        measured = raw["end"][raw_side]
                        measured["seconds"] = measured_seconds
                        measured["bits_per_second"] = measured["bytes"] * 8 / measured_seconds
                        summary[side].update(measured, mbps=measured["bits_per_second"] / 1e6)
                        row[side + "_mbps"] = summary[side]["mbps"]
                for aggregate in probe["aggregates"].values():
                    aggregate.update(sender_mbps_median=1800 / measured_seconds,
                                     receiver_mbps_median=1800 / measured_seconds)
            with self.subTest(seconds=measured_seconds), tempfile.TemporaryDirectory() as folder:
                fixture(Path(folder), actual_window)
                result = analyze(folder, "fixture", True, now=NOW)
                for direction in result["directions"]:
                    self.assertEqual(direction["decision"], expected)
                    if expected == "INSUFFICIENT_EVIDENCE":
                        self.assertIn("INVALID_MEASUREMENT_WINDOW", direction["issues"])
                        self.assertIsNone(direction["candidate_buffer_max_bytes"])

    def test_cli_rejects_inconsistent_evidence_without_partial_report(self):
        cases = [
            (lambda d, m, p: p.update(samples=[r for r in p["samples"] if r["sample"] != 3]), "清单样本集合"),
            (lambda d, m, p: d[1, "upload"][0]["start"]["test_start"].update(duration=120, omit=10), "时长/预热"),
        ]
        for mutate, reason in cases:
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                fixture(root, mutate)
                before = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
                result = subprocess.run([sys.executable, "-X", "utf8", str(Path(__file__).resolve().parents[1] /
                    "tools/calibrate_probe.py"), "--evidence", folder, "--path-label", "fixture",
                    "--representative-path"], capture_output=True, text=True, encoding="utf-8", timeout=15)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertIn(reason, result.stderr)
                self.assertEqual(before, {p: p.read_bytes() for p in root.rglob("*") if p.is_file()})

    def test_cli_insufficient_evidence_is_success_with_null_candidate(self):
        fixture(self.root, lambda d, m, p: m.update(utc="2000-01-01T00:00:00Z"))
        result = subprocess.run([sys.executable, "-X", "utf8", str(Path(__file__).resolve().parents[1] /
            "tools/calibrate_probe.py"), "--evidence", str(self.root), "--path-label", "fixture",
            "--representative-path"], capture_output=True, text=True, encoding="utf-8", timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        for direction in json.loads(result.stdout)["directions"]:
            self.assertEqual(direction["decision"], "INSUFFICIENT_EVIDENCE")
            self.assertIsNone(direction["candidate_buffer_max_bytes"])

    def test_tampered_raw_rejected(self):
        fixture(self.root)
        (self.root / "sample-01/upload.iperf3.json").write_text("{}")
        with self.assertRaises(EvidenceError):
            self.result()

    def test_incomplete_rejected(self):
        fixture(self.root)
        (self.root / "INCOMPLETE").touch()
        with self.assertRaises(EvidenceError):
            self.result()

    def test_manifest_traversal_rejected_even_with_matching_marker(self):
        fixture(self.root)
        manifest = b"a" * 64 + b"  ../outside\n"
        (self.root / "SHA256SUMS").write_bytes(manifest)
        (self.root / "COMPLETED").write_text(f"status=COMPLETED\nevidence_manifest_sha256={sha(manifest)}\n")
        with self.assertRaises(EvidenceError):
            self.result()

    def test_invalid_labels_and_policy_rejected(self):
        fixture(self.root)
        for label, age in [("192.0.2.1", 24), ("path", 0), ("path", 169)]:
            with self.subTest(label=label, age=age), self.assertRaises(EvidenceError):
                analyze(self.root, label, True, age, NOW)


if __name__ == "__main__":
    unittest.main()
