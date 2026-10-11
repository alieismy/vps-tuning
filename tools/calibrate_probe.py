#!/usr/bin/env python3
"""从完整 DVT probe 证据生成离线缓冲实验建议；不测速、不应用配置。"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import math
from pathlib import Path, PurePosixPath
import re
import statistics
import sys

from render_profiles import PROFILES

VERSION = "0.1.2"


class EvidenceError(ValueError):
    """输入不满足受支持的证据契约。"""


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def number(value, low=0, high=1e18):
    return type(value) in (int, float) and low <= value <= high and math.isfinite(value)


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def digest(data):
    return hashlib.sha256(data).hexdigest()


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "JSON 含重复字段")
        result[key] = value
    return result


def decode(data):
    return json.loads(data, object_pairs_hook=object_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(EvidenceError("JSON 含非有限值")))


def marker(data):
    pairs = [line.split("=", 1) for line in data.decode("utf-8").splitlines() if line]
    require(all(len(pair) == 2 for pair in pairs), "完成标记格式无效")
    result = object_pairs(pairs)
    require(result.get("status") == "COMPLETED", "证据没有 COMPLETED 状态")
    return result


def manifest_entries(data):
    entries = {}
    for line in data.decode("utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64}) [ *](.+)", line)
        require(match is not None, "摘要清单格式无效")
        sha, name = match.groups()
        path = PurePosixPath(name)
        require(not path.is_absolute() and ".." not in path.parts and
                "\\" not in name and ":" not in name and str(path) == name,
                "摘要清单包含非规范或越界路径")
        require(name not in entries, "摘要清单包含重复路径")
        entries[name] = sha
    require(entries, "摘要清单为空")
    return entries


class ProbeEvidence:
    """测量内容解析顶层已验字节；子控制文件通过已验 result 绑定。"""

    def __init__(self, root):
        self.root = Path(root).resolve()
        self.bytes_read = 0
        require(self.root.is_dir(), "probe 证据目录不存在")
        require(not (self.root / "INCOMPLETE").exists(), "probe 仍有 INCOMPLETE")
        manifest = self.read("SHA256SUMS")
        completed = marker(self.read("COMPLETED"))
        require(completed.get("evidence_manifest_sha256") == digest(manifest), "probe 清单摘要不符")
        entries = manifest_entries(manifest)
        self.files = {}
        for name, sha in entries.items():
            data = self.read(name)
            require(digest(data) == sha, "probe 文件摘要不符")
            self.files[name] = data
        require(completed.get("result_sha256") == digest(self.get("probe-result.json")),
                "probe 结果摘要不符")
        self.sha256 = digest(manifest)

    def read(self, name):
        path = self.root
        for part in PurePosixPath(name).parts:
            path = path / part
            require(not path.is_symlink(), "证据不接受符号链接")
        require(path.resolve().is_relative_to(self.root), "证据路径越界")
        require(path.is_file() and path.stat().st_size <= 32 * 1024 * 1024,
                "证据文件缺失或超过 32 MiB")
        data = path.read_bytes()
        self.bytes_read += len(data)
        require(self.bytes_read <= 256 * 1024 * 1024, "证据超过离线工具的 256 MiB 输入上限")
        return data

    def get(self, name):
        require(name in self.files, "必要输入没有纳入 probe 摘要清单")
        return self.files[name]

    def json(self, name):
        return decode(self.get(name))

    def benchmark(self, prefix):
        require(not (self.root / prefix / "INCOMPLETE").exists(), "子样本仍有 INCOMPLETE")
        # probe 顶层清单排除各层控制文件；子清单通过顶层已验的 result 反向绑定。
        completed = marker(self.read(prefix + "/COMPLETED"))
        manifest = self.read(prefix + "/SHA256SUMS")
        sha = digest(manifest)
        require(completed.get("evidence_manifest_sha256") == sha, "子样本清单摘要不符")
        entries = manifest_entries(manifest)
        for name, expected in entries.items():
            require(digest(self.get(prefix + "/" + name)) == expected, "子样本摘要不符")
        result_data = self.get(prefix + "/benchmark-result.json")
        require(completed.get("result_sha256") == digest(result_data), "子样本结果摘要不符")
        result = decode(result_data)
        require(result.get("schema_version") == 1 and result.get("status") == "PASS" and
                result.get("exit_code") == 0 and result.get("evidence_manifest_sha256") == sha,
                "子样本未通过或结果没有绑定清单")
        meta = self.json(prefix + "/benchmark-meta.json")
        require("benchmark-meta.json" in entries and result.get("metadata") == meta,
                "子样本元数据不一致")
        return result, meta, entries


def stats(values):
    if not values:
        return None
    median = statistics.median(values)
    return {"n": len(values), "min": min(values), "max": max(values), "median": median,
            "mad": statistics.median(abs(value - median) for value in values)}


def utc_time(value):
    require(isinstance(value, str), "缺少 UTC 测量时间")
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(dt.tzinfo is not None, "测量时间缺少时区")
    return dt.astimezone(timezone.utc)


def address(value):
    parsed = ipaddress.ip_address(value)
    if isinstance(parsed, ipaddress.IPv6Address) and parsed.ipv4_mapped:
        parsed = parsed.ipv4_mapped
    return str(parsed), parsed.version


def sample_metrics(raw, summary, row, expected_seconds, expected_omit, phase):
    require(raw.get("error") is None and summary.get("schema_version") == 3 and
            summary.get("direction") == phase and summary.get("reverse") == (phase == "download"),
            "样本方向、错误或 summary schema 无效")
    test = raw["start"]["test_start"]
    require(test.get("protocol") == "TCP" and test.get("num_streams") == 1 and
            test.get("reverse") == (1 if phase == "download" else 0), "仅支持匹配方向的单流 TCP")
    require(integer(test.get("duration"), 5, 120) and integer(test.get("omit"), 0, 10) and
            test["duration"] == expected_seconds and test["omit"] == expected_omit,
            "原始测量时长/预热与 metadata 不一致或缺失")
    sent, received = raw["end"]["sum_sent"], raw["end"]["sum_received"]
    declared_valid = summary["measurement_window"].get("valid")
    require(type(declared_valid) is bool and row.get("measurement_window_valid") is declared_valid,
            "row 与 summary 的窗口标记不一致或无效")
    valid = declared_valid
    for side, observed in (("sender", sent), ("receiver", received)):
        require(integer(observed.get("bytes"), 1, 10**15) and number(observed.get("seconds"), 0.001, 3600)
                and number(observed.get("bits_per_second")), "iperf3 字节/时长/速率无效")
        require(all(summary[side].get(key) == observed.get(key) for key in
                    ("bytes", "seconds", "bits_per_second")), "summary 与原始测量不一致")
        require(summary[side].get("mbps") == observed["bits_per_second"] / 1e6 and
                row.get(side + "_mbps") == summary[side]["mbps"], "汇总吞吐与原始测量不一致")
        calculated = observed["bytes"] * 8 / observed["seconds"]
        valid = valid and abs(observed["bits_per_second"] - calculated) / calculated <= 0.01
        valid = valid and abs(observed["seconds"] - expected_seconds) <= max(0.25, expected_seconds * 0.05)
    require(integer(sent.get("retransmits"), 0, 10**12) and
            summary["sender"].get("retransmits") == sent["retransmits"] and
            row.get("sender_bytes") == sent["bytes"] and row.get("sender_retransmits") == sent["retransmits"],
            "重传或 sender 字节不一致")
    valid = valid and abs(sent["seconds"] - received["seconds"]) <= max(0.25, expected_seconds * 0.05)
    valid = valid and received["bytes"] <= sent["bytes"] + max(1048576, sent["bytes"] * 0.01)
    connections = raw["start"]["connected"]
    require(len(connections) == 1, "原始连接数不是 1")
    peer, family = address(connections[0]["remote_host"])
    streams = raw["end"].get("streams", [])
    sender = streams[0].get("sender", {}) if len(streams) == 1 else {}
    low, mean, high = (sender.get(key) for key in ("min_rtt", "mean_rtt", "max_rtt"))
    rtt_valid = all(number(value, 1, 60_000_000) for value in (low, mean, high))
    rtt_valid = rtt_valid and low <= mean <= high
    return {"window_valid": valid, "peer": peer, "family": family,
            "declared_window_valid": declared_valid,
            "sender_mbps": sent["bits_per_second"] / 1e6,
            "receiver_mbps": received["bits_per_second"] / 1e6,
            "retransmits_per_gib": sent["retransmits"] * 1073741824 / sent["bytes"],
            "loaded_min_rtt_ms": low / 1000 if rtt_valid else None,
            "loaded_mean_rtt_ms": mean / 1000 if rtt_valid else None}


def analyze(root, path_label, representative=False, max_age_hours=24, now=None):
    require(re.fullmatch(r"[A-Za-z0-9_-]{1,64}", path_label) is not None,
            "path-label 仅接受 1–64 位字母、数字、下划线和连字符")
    require(integer(max_age_hours, 1, 168), "max-age-hours 必须在 1–168 之间")
    evidence = ProbeEvidence(root)
    probe = evidence.json("probe-result.json")
    require(probe.get("schema_version") == 1 and probe.get("advisory_only") is True and
            probe.get("status") in ("REVIEW_REQUIRED", "REVIEW_BLOCKED"), "不支持的 probe 结果")
    profile = PROFILES.get(probe.get("profile", "") + "-vps-tuning.sh")
    require(profile is not None, "未知资源 profile")
    require(profile["RESOURCE_POLICY"] == "fixed",
            "自适应 profile 尚无此离线校准的资源预算契约；不能用静态封顶代替实际内存上限")
    control = probe["traffic_control"]
    require(control.get("enforced") is True and control.get("method") == "iperf3-bitrate" and
            integer(control.get("rate_cap_mbps"), 100, 1000), "probe 缺少受限测量契约")
    rows = probe["samples"]
    require(isinstance(rows, list) and 2 <= len(rows) <= 10, "不支持的样本数量")
    now = now or datetime.now(timezone.utc)
    grouped = {"upload": [], "download": []}
    seen, contexts, times, bindings, measurement_contexts = set(), [], [], [], []
    for row in rows:
        require(isinstance(row, dict), "样本行格式无效")
        phase, sample = row["direction"], row["sample"]
        require(phase in grouped and integer(sample, 1, 5) and (sample, phase) not in seen,
                "样本编号、方向或重复行无效")
        seen.add((sample, phase))
    # 摘要自洽不代表所有测量都被引用；先排除选择性遗漏，再消费子样本。
    manifest_samples = {name.split("/", 1)[0] for name in evidence.files if name.startswith("sample-")}
    require(manifest_samples == {f"sample-{sample:02d}" for sample, _ in seen},
            "清单样本集合与引用不一致")
    child_cache = {}
    for row in rows:
        phase, sample = row["direction"], row["sample"]
        prefix = f"sample-{sample:02d}"
        if prefix not in child_cache:
            child_cache[prefix] = evidence.benchmark(prefix)
        result, meta, entries = child_cache[prefix]
        require(meta.get("schema_version") == 1 and meta.get("profile") == probe["profile"], "profile 绑定不符")
        bench = meta["benchmark"]
        require(bench.get("host") == probe["endpoint"]["host"] and bench.get("port") == probe["endpoint"]["port"]
                and bench.get("rate_cap_enforced") is True and bench.get("rate_cap_method") == "iperf3-bitrate"
                and bench["traffic_estimate"].get("cap_mbps") == control["rate_cap_mbps"]
                and bench.get("parallel") == 1 and bench.get("family") in ("auto", "4", "6")
                and bench.get("direction") in (phase, "both") and integer(bench.get("seconds"), 5, 120)
                and integer(bench.get("omit_seconds"), 0, 10),
                "子样本测量上下文与 probe 不一致")
        measurement_contexts.append((bench["seconds"], bench["omit_seconds"], bench["family"], bench["direction"]))
        require({phase + ".iperf3.json", phase + ".summary.json"} <= entries.keys(),
                "原始测量或 summary 未纳入子样本清单")
        summary = evidence.json(prefix + "/" + phase + ".summary.json")
        require(result["phases"].get(phase) == summary, "子样本结果与 summary 不一致")
        raw = evidence.json(prefix + "/" + phase + ".iperf3.json")
        metrics = sample_metrics(raw, summary, row, bench["seconds"], bench["omit_seconds"], phase)
        require(bench["family"] == "auto" or bench["family"] == str(metrics["family"]), "实际协议族与请求不符")
        grouped[phase].append(metrics)
        contexts.append(meta.get("state_network"))
        times.append(utc_time(meta.get("utc")))
        bindings.append((meta.get("state"), meta.get("script_version"), meta.get("script_sha256"), meta.get("boot_id")))
    network = contexts[0]
    require(len(set(measurement_contexts)) == 1, "重复样本的测量参数不一致")
    require(all(item == network for item in contexts) and isinstance(network, dict), "资源/网络上下文发生变化")
    require(len(set(bindings)) == 1 and bindings[0][0] == "VERIFIED" and
            bindings[0][1] in ("0.1.0-rc.17", "0.1.0-rc.18", "0.1.0-rc.19", "0.2.0-rc.1", "0.2.0-rc.2") and isinstance(bindings[0][2], str) and
            re.fullmatch(r"[0-9a-f]{64}", bindings[0][2]) is not None and bindings[0][3],
            "需要同一 VERIFIED 版本、脚本与启动周期的证据")
    port, current = network.get("port_speed_mbps"), network.get("buffer_max_bytes")
    limit = int(profile["BUF_MAX_LIMIT"])
    numerator, denominator = int(profile["BUFFER_TARGET_NUMERATOR"]), int(profile["BUFFER_TARGET_DENOMINATOR"])
    require(integer(port, 100, 1000) and integer(current, 262144, limit) and
            integer(network.get("target_rtt_ms"), 20, 500) and
            network.get("buffer_target_numerator") == numerator and
            network.get("buffer_target_denominator") == denominator, "受管 buffer/BDP 参数无效")
    require(control["rate_cap_mbps"] <= port, "测量 cap 超过声明套餐上限")
    sample_ids = {sample for sample, _ in seen}
    require(sample_ids == set(range(1, len(sample_ids) + 1)), "样本编号不连续")
    directions = {phase for phase, values in grouped.items() if values}
    require(all({phase for s, phase in seen if s == sample} == directions for sample in sample_ids),
            "重复样本的方向不完整")
    for result, meta, _ in child_cache.values():
        expected = {"upload", "download"} if meta["benchmark"]["direction"] == "both" else {meta["benchmark"]["direction"]}
        require(directions == expected and {p for p, value in result["phases"].items() if value is not None} == expected,
                "probe 遗漏已声明的测量方向")
    aggregates = probe.get("aggregates")
    require(isinstance(aggregates, dict) and set(aggregates) == set(grouped), "probe aggregates 方向无效或缺失")
    for phase, values in grouped.items():
        aggregate = aggregates[phase]
        if not values:
            require(aggregate is None, "未测方向的 aggregate 必须为 null")
            continue
        # producer 的 valid_windows 统计声明标记；本工具重新计算的有效性仍用于暂停建议。
        require(isinstance(aggregate, dict) and integer(aggregate.get("samples"), 1, 5) and
                integer(aggregate.get("valid_windows"), 0, 5) and aggregate["samples"] == len(values) and
                aggregate["valid_windows"] == sum(value["declared_window_valid"] for value in values),
                "probe aggregate 样本数或有效窗口数不一致")
    common_issues = []
    if not representative:
        common_issues.append("PATH_REPRESENTATIVENESS_NOT_ACKNOWLEDGED")
    age_hours = (now - min(times)).total_seconds() / 3600
    if age_hours > max_age_hours or max(times) > now:
        common_issues.append("EVIDENCE_TIME_OUTSIDE_POLICY")
    if probe["status"] == "REVIEW_BLOCKED":
        common_issues.append("PROBE_REVIEW_BLOCKED")
    recommendations = []
    for phase, values in grouped.items():
        if not values:
            continue
        issues = list(common_issues)
        if len(values) < 2:
            issues.append("INSUFFICIENT_REPEATS")
        if len({(value["peer"], value["family"]) for value in values}) != 1:
            issues.append("PATH_CHANGED_WITHIN_DIRECTION")
        if not all(value["window_valid"] for value in values):
            issues.append("INVALID_MEASUREMENT_WINDOW")
        low = stats([value["loaded_min_rtt_ms"] for value in values if value["loaded_min_rtt_ms"] is not None])
        if low is None or low["n"] != len(values):
            issues.append("SENDER_RTT_UNAVAILABLE")
        elif low["mad"] > low["median"] * 0.25:
            issues.append("RTT_DISPERSION_EXCEEDS_POLICY")
        if low is not None and low["max"] > 500:
            issues.append("RTT_OUTSIDE_SUPPORTED_RANGE")
        sender = stats([value["sender_mbps"] for value in values])
        receiver = stats([value["receiver_mbps"] for value in values])
        if sender["max"] > control["rate_cap_mbps"] * 1.1:
            issues.append("OBSERVED_RATE_EXCEEDS_CAP_TOLERANCE")
        candidate, target_rtt, bdp = None, None, None
        decision = "INSUFFICIENT_EVIDENCE"
        if not issues:
            target_rtt = max(20, math.ceil(low["median"]))
            bdp = port * 125 * target_rtt
            target = math.ceil(bdp * numerator / denominator)
            tier = next((size for size in (16777216, 33554432, 67108864) if size >= target), 67108864)
            candidate = min(tier, limit)
            if target > limit:
                decision = "RESOURCE_LIMITED"
            elif candidate <= current:
                decision = "KEEP_CURRENT_CEILING"
                candidate = current  # 单一路径不能支持全局缩小 socket 上限。
            else:
                decision = "EXPERIMENT_CANDIDATE"
        recommendations.append({"direction": phase, "samples": len(values), "issues": issues,
            "observed_families": sorted({v["family"] for v in values}),
            "sender_mbps": sender, "receiver_mbps": receiver,
            "sender_retransmits_per_gib": stats([v["retransmits_per_gib"] for v in values]),
            "loaded_min_rtt_ms": low,
            "loaded_mean_rtt_ms": stats([v["loaded_mean_rtt_ms"] for v in values if v["loaded_mean_rtt_ms"] is not None]),
            "decision": decision, "candidate_target_rtt_ms": target_rtt,
            "declared_cap_bdp_bytes": bdp, "candidate_buffer_max_bytes": candidate})
    return {"schema_version": 1, "analyzer_version": VERSION,
        "status": "REVIEW_REQUIRED", "advisory_only": True, "configuration_changed": False,
        "path_label": path_label, "representative_path_acknowledged": representative,
        "source_manifest_sha256": evidence.sha256, "profile": probe["profile"],
        "source_script_version": bindings[0][1], "source_script_sha256": bindings[0][2],
        "observed_age_hours": age_hours, "policy": {"max_age_hours": max_age_hours,
            "maximum_min_rtt_relative_mad": 0.25, "rate_cap_overshoot_tolerance": 0.1},
        "provider_port_mbps": port, "probe_rate_cap_mbps": control["rate_cap_mbps"],
        "current_buffer_max_bytes": current, "resource_limit_bytes": limit,
        "directions": recommendations,
        "interpretation": {"rtt_source": "iperf3 end.streams.sender min/mean/max_rtt in microseconds",
            "idle_rtt_measured": False, "provider_capacity_discovered": False,
            "policer_identified": False, "performance_gain_proven": False,
            "buffer_basis": "declared provider cap times median per-run loaded minimum RTT, with existing profile multiplier and limits",
            "next_gate": "review path relevance and CPU/queue evidence; test buffer alone against baseline before any explicit application",
            "global_reduction_supported": False}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=Path, help="已完成的 probe 目录（不接受压缩包）")
    parser.add_argument("--path-label", required=True, help="不含地址的路径标签，例如 eu-client")
    parser.add_argument("--representative-path", action="store_true", help="确认端点可代表拟评估的业务路径；不等于业务验收")
    parser.add_argument("--max-age-hours", type=int, default=24, help="允许证据时效，1–168 小时，默认 24")
    args = parser.parse_args()
    try:
        result = analyze(args.evidence, args.path_label, args.representative_path, args.max_age_hours)
    except (EvidenceError, OSError, ValueError, KeyError, TypeError, IndexError, AttributeError, RecursionError) as exc:
        # 不回显原始 JSON、地址或本机路径。
        message = str(exc) if isinstance(exc, EvidenceError) else "证据格式或文件读取失败"
        print(f"[calibrate-probe] {message}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
