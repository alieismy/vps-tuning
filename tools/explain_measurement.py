#!/usr/bin/env python3
"""离线解释已校验的路径测量：计数、暴露量与候选限制，不改变分类。"""
from __future__ import annotations

import argparse
from collections import Counter
import copy
from fractions import Fraction
import importlib.util
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
spec = importlib.util.spec_from_file_location('dvt_measure_explanation_source', ROOT / 'dvt-measure.py')
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)
VERSION = '0.1.1'
GIB = 1073741824


def require(condition, message):
    if not condition:
        raise ValueError(message)


def positive(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def explain(result):
    """只派生解释；源分类始终保留，不把字段不足解释为零重传。"""
    analysis = result['analysis']
    require(isinstance(analysis, dict), 'analysis 必须为对象')
    threshold = analysis.get('spike_threshold_retransmits_per_gib')
    require(threshold is None or positive(threshold), '重传阈值必须为有限正数或 null')
    raw_rows = result['samples']
    require(isinstance(raw_rows, list), 'samples 必须为列表')
    rows = []
    for raw in raw_rows:
        require(isinstance(raw, dict) and positive(raw.get('rate_mbps')), '样本速率无效')
        require(type(raw.get('eligible')) is bool, '样本 eligible 必须为布尔值')
        require(raw.get('role') in ('control-start', 'control-end', 'sweep', 'reference-start', 'reference-end'), '样本角色无效')
        row = {k: raw[k] for k in ('role', 'rate_mbps', 'eligible')}
        sender = raw.get('sender', {})
        require(isinstance(sender, dict), 'sender 必须为对象')
        size, count = sender.get('bytes'), sender.get('retransmits')
        for value, minimum, label in ((size, 1, 'bytes'), (count, 0, 'retransmits')):
            require(value is None or (type(value) is int and minimum <= value <= 10**18), label + ' 必须为范围内整数')
        row.update(payload_bytes=size, retransmits=count)
        if size is None or count is None:
            row.update(status='UNAVAILABLE', retransmits_per_gib=None, single_event_per_gib=None, events_at_threshold=None)
        else:
            normalized = count * GIB / size
            reported = sender.get('retransmits_per_gib')
            require(reported is None or (type(reported) in (int, float) and math.isfinite(reported) and
                    math.isclose(reported, normalized, rel_tol=1e-9, abs_tol=1e-9)), '归一化重传与字节/计数不一致')
            row.update(status='AVAILABLE', retransmits_per_gib=normalized, single_event_per_gib=GIB / size,
                       events_at_threshold=math.ceil(Fraction(str(threshold)) * size / GIB) if threshold else None)
        rows.append(row)
    candidate = analysis.get('candidate_interval')
    observation = None
    if candidate is not None:
        require(isinstance(candidate, dict) and positive(candidate.get('lower_mbps')) and
                positive(candidate.get('upper_mbps')) and candidate['lower_mbps'] < candidate['upper_mbps'], '候选区间无效')
        upper = candidate['upper_mbps']
        selected = [r for r in rows if r['role'] == 'sweep' and r['rate_mbps'] == upper]
        comparable = threshold is not None and bool(selected) and all(r['eligible'] and r['status'] == 'AVAILABLE' for r in selected)
        hits = [r for r in selected if comparable and r['retransmits'] >= r['events_at_threshold']]
        tested = analysis.get('tested_rates', [])
        require(isinstance(tested, list) and all(isinstance(g, dict) and positive(g.get('rate_mbps')) for g in tested), 'tested_rates 无效')
        higher = [g for g in tested if g['rate_mbps'] > upper]
        higher_sample_rates = {r['rate_mbps'] for r in rows if r['role'] == 'sweep' and r['rate_mbps'] > upper}
        higher_summary_rates = {g['rate_mbps'] for g in higher}
        if 'tested_rates' not in analysis or not higher_sample_rates.issubset(higher_summary_rates):
            higher_status = 'INCOMPLETE'
        elif not higher:
            higher_status = 'NOT_COVERED'
        elif any(g.get('eligible') is not True or g.get('status') not in ('RETRANSMISSION_RISE', 'NO_CONFIRMED_RISE') for g in higher):
            higher_status = 'INCOMPLETE'
        elif any(g['status'] == 'RETRANSMISSION_RISE' for g in higher):
            higher_status = 'RISE_OBSERVED'
        else:
            higher_status = 'NO_CONFIRMED_RISE'
        observation = dict(upper_mbps=upper, sample_count=len(selected),
                           threshold_hits=len(hits) if comparable else None,
                           single_event_hits=sum(r['retransmits'] == 1 for r in hits) if comparable else None,
                           higher_rate_observation=higher_status)
    return dict(schema='dvt.measurement-explanation/1', tool_version=VERSION,
                original_analysis=copy.deepcopy(analysis), original_stop_reason=result.get('stop_reason'),
                samples=rows, candidate_observation=observation,
                independent_replication='NOT_ASSESSED', htb_entry='NOT_ESTABLISHED_BY_SINGLE_REPORT')


def explain_directory(directory):
    directory = Path(directory)
    result = measurement.verify_report(directory)
    explanation = explain(result)
    explanation['source'] = dict(schema=result['schema'], version=result.get('version'),
                                report_sha256=measurement.sha(directory / 'measurement-result.json'),
                                manifest_sha256=measurement.sha(directory / 'SHA256SUMS'))
    return explanation


def _coverage_lines(data, plan):
    """仅为文本对照最终计划、样本数与原汇总，不重算分类或扩展 JSON 契约。"""
    unavailable = ['计划覆盖不可评估：归档计划或逐档汇总字段不足/不支持。']
    inconsistent = ['计划覆盖不可评估：计划、扫描样本与逐档汇总资料不一致。']
    def supported_rate(value):
        try:
            return positive(value)
        except OverflowError:
            return False
    if not isinstance(plan, dict) or not isinstance(plan.get('schedule'), list):
        return unavailable
    expected = Counter()
    for item in plan['schedule']:
        if (not isinstance(item, (list, tuple)) or len(item) != 2 or
                item[0] not in ('control-start', 'control-end', 'sweep', 'reference-start', 'reference-end') or
                not supported_rate(item[1])):
            return unavailable
        if item[0] == 'sweep':
            expected[item[1]] += 1

    # data 已由 explain() 校验；只检查新增展示依赖的计划与汇总边界。
    samples = [row for row in data['samples'] if row['role'] == 'sweep']
    observed = Counter(row['rate_mbps'] for row in samples)
    eligible = Counter(row['rate_mbps'] for row in samples if row['eligible'])
    tested = data['original_analysis'].get('tested_rates')
    if not isinstance(tested, list):
        return unavailable
    groups = {}
    for group in tested:
        if (not isinstance(group, dict) or not supported_rate(group.get('rate_mbps')) or
                type(group.get('samples')) is not int or group['samples'] < 0 or
                type(group.get('eligible')) is not bool or
                group.get('status') not in ('RETRANSMISSION_RISE', 'NO_CONFIRMED_RISE', 'INCONCLUSIVE')):
            return unavailable
        rate = group['rate_mbps']
        if rate in groups:
            return inconsistent
        groups[rate] = group
    if set(groups) != set(expected) or not set(observed) <= set(expected):
        return inconsistent

    complete, gaps = [], []
    for rate in sorted(expected):
        count, valid, wanted = observed[rate], eligible[rate], expected[rate]
        group = groups[rate]
        all_eligible = count == wanted and valid == wanted
        if (count > wanted or group['samples'] != count or group['eligible'] != all_eligible or
                group['eligible'] != (group['status'] != 'INCONCLUSIVE')):
            return inconsistent
        if all_eligible:
            complete.append(f'{rate:g} Mbps')
        else:
            reasons = []
            if count == 0:
                reasons.append('无扫描样本')
            elif count < wanted:
                reasons.append('样本不足')
            if valid < count:
                reasons.append('含无效样本')
            gaps.append(f'{rate:g} Mbps（{"、".join(reasons)}；已采 {count}/{wanted}，原标记有效 {valid}）')

    if not expected:
        return ['归档计划：无独立扫描档；控制/reference 不计入扫描覆盖。']
    planned = '、'.join(f'{rate:g} Mbps × {expected[rate]}' for rate in sorted(expected))
    return [f'归档计划扫描档（最终 schedule，含已追加细扫）：{planned}',
            '样本齐全且原汇总有效的档位：' + ('、'.join(complete) or '无'),
            '缺失/不足/无效的档位：' + ('；'.join(gaps) or '无'),
            '覆盖仅描述离散 sweep 档位；整体结论及控制/reference 约束保持原报告。']


def print_explanation(data, coverage=()):
    analysis = data['original_analysis']
    print('原报告状态：' + str(analysis.get('status')))
    print('原报告候选：' + str(analysis.get('candidate_interval')))
    if data['original_stop_reason']:
        print('原报告停止原因：' + str(data['original_stop_reason']))
    for line in coverage:
        print(line)
    print('逐样本：角色 / Mbps / 有效 / payload bytes / 重传次数 / 重传每 GiB / 单次重传每 GiB / 达阈值所需次数')
    def show(value):
        return '不可评估' if value is None else value
    for row in data['samples']:
        resolution = f"{row['single_event_per_gib']:.3f}" if row['status'] == 'AVAILABLE' else '不可评估'
        normalized = f"{row['retransmits_per_gib']:.3f}" if row['status'] == 'AVAILABLE' else '不可评估'
        print(f"  {row['role']} / {row['rate_mbps']} / {row['eligible']} / {show(row['payload_bytes'])} / "
              f"{show(row['retransmits'])} / {normalized} / {resolution} / {show(row['events_at_threshold'])}")
    candidate = data['candidate_observation']
    if candidate:
        if candidate['threshold_hits'] is None:
            print('候选档：计数、阈值或有效样本不足，不能评估触发强度。')
        else:
            print(f"候选档：{candidate['threshold_hits']} 个样本越阈值，其中 {candidate['single_event_hits']} 个样本只有一次重传。")
        descriptions = {'NOT_COVERED': '未覆盖更高速率，不能判断高档趋势',
                        'INCOMPLETE': '更高档证据不完整，不能判断高档趋势',
                        'RISE_OBSERVED': '更高档也观察到重复上升，仍不证明 policer',
                        'NO_CONFIRMED_RISE': '更高档未确认重复上升；原候选保留，不能据此确认可靠拐点'}
        print('高档观察：' + descriptions[candidate['higher_rate_observation']])
    print('解释边界：单报告未评估独立复现，不能单独确立 HTB 实验条件或业务收益。')
    print('计数按 sender bytes 归一化，不是丢包百分比；零重传也不证明网络健康。')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-dir', required=True)
    parser.add_argument('--json', action='store_true', help='输出派生解释 JSON，不写源目录')
    args = parser.parse_args(argv)
    try:
        data = explain_directory(args.input_dir)
        if args.json:
            print(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False))
        else:
            # 只在归档校验成功后读计划；旧计划不可解析不阻断既有解释。
            try:
                plan = json.loads((Path(args.input_dir) / 'plan.json').read_text(encoding='utf-8'))
            except (ValueError, RecursionError):
                plan = None
            print_explanation(data, _coverage_lines(data, plan))
    except (measurement.MeasurementError, ValueError, OSError, KeyError, TypeError, OverflowError) as exc:
        print('测量解释失败：' + str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
