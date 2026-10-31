"""合成边界场景只验证离线解释契约，不代表公网分类准确率。"""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('explanation', ROOT / 'tools/explain_measurement.py')
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)


def fixture(pattern='isolated', schema='dvt.path-measurement/1'):
    # 手工指定合成计数和原分类，不用本次实测的 12 Mbps 样本选择测试阈值。
    sequences = {'clean': ([0, 0, 0], [0, 0, 0]),
                 'isolated': ([1, 0, 1], [0, 0, 0]),
                 'sustained': ([8, 9, 8], [12, 10, 12]),
                 'highest': ([0, 0, 0], [8, 8, 0])}
    low, high = sequences[pattern]
    rows = []
    for role, rate, counts in (('control-start', 10, [0]*3), ('sweep', 20, low),
                               ('sweep', 40, high), ('control-end', 10, [0]*3)):
        for count in counts:
            rows.append(dict(role=role, rate_mbps=rate, eligible=True,
                             sender=dict(bytes=8*2**20, retransmits=count, retransmits_per_gib=count*128)))
    candidate = None if pattern == 'clean' else dict(lower_mbps=20 if pattern == 'highest' else 10,
                                                    upper_mbps=40 if pattern == 'highest' else 20)
    groups = [dict(rate_mbps=20, eligible=True, status='RETRANSMISSION_RISE' if pattern in ('isolated', 'sustained') else 'NO_CONFIRMED_RISE'),
              dict(rate_mbps=40, eligible=True, status='RETRANSMISSION_RISE' if pattern in ('sustained', 'highest') else 'NO_CONFIRMED_RISE')]
    return dict(schema=schema, version='fixture', stop_reason=None, endpoint=None, samples=rows,
                analysis=dict(status='RETRANSMISSION_RISE_OBSERVED' if candidate else 'NO_RISE_IN_TESTED_RANGE',
                              candidate_interval=candidate, tested_rates=groups, issues=[],
                              spike_threshold_retransmits_per_gib=100, policer_identified=False,
                              recommended_shaping_rate_mbps=None))


def coverage_fixture(pattern='clean', schema='dvt.path-measurement/1'):
    source = fixture(pattern, schema)
    for group in source['analysis']['tested_rates']:
        group['samples'] = 3
    plan = dict(rate_cap_mbps=40, rates_mbps=[10, 20, 40], samples_per_rate=3,
                schedule=[['control-start', 10]]*3 + [['sweep', 20]]*3 +
                         [['sweep', 40]]*3 + [['control-end', 10]]*3)
    return source, plan


class ExplanationTests(unittest.TestCase):
    def test_isolated_single_events_keep_original_candidate(self):
        source = fixture(); before = copy.deepcopy(source)
        result = e.explain(source)
        self.assertEqual(source, before)
        self.assertEqual(result['original_analysis'], before['analysis'])
        observed = result['candidate_observation']
        self.assertEqual((observed['threshold_hits'], observed['single_event_hits']), (2, 2))
        self.assertEqual(observed['higher_rate_observation'], 'NO_CONFIRMED_RISE')
        self.assertEqual(result['independent_replication'], 'NOT_ASSESSED')

    def test_sustained_rise_does_not_become_policer_proof(self):
        result = e.explain(fixture('sustained'))
        self.assertEqual(result['candidate_observation']['higher_rate_observation'], 'RISE_OBSERVED')
        self.assertEqual(result['candidate_observation']['single_event_hits'], 0)
        self.assertFalse(result['original_analysis']['policer_identified'])
        self.assertEqual(result['htb_entry'], 'NOT_ESTABLISHED_BY_SINGLE_REPORT')

    def test_highest_candidate_has_no_higher_counterevidence(self):
        result = e.explain(fixture('highest'))
        self.assertEqual(result['candidate_observation']['higher_rate_observation'], 'NOT_COVERED')

    def test_missing_high_rate_is_incomplete_not_clean(self):
        source = fixture(); source['analysis']['tested_rates'][1]['eligible'] = False
        self.assertEqual(e.explain(source)['candidate_observation']['higher_rate_observation'], 'INCOMPLETE')

    def test_missing_rate_summary_does_not_claim_no_coverage(self):
        for pattern in ('isolated', 'highest'):
            with self.subTest(pattern=pattern):
                source = fixture(pattern); del source['analysis']['tested_rates']
                self.assertEqual(e.explain(source)['candidate_observation']['higher_rate_observation'], 'INCOMPLETE')

    def test_omitted_higher_sample_rate_is_incomplete(self):
        source = fixture(); source['analysis']['tested_rates'].pop()
        self.assertEqual(e.explain(source)['candidate_observation']['higher_rate_observation'], 'INCOMPLETE')

    def test_no_candidate_and_partial_keep_original_refusal(self):
        for stop in (None, 'TIME_LIMIT', 'BUDGET_LIMIT'):
            source = fixture('clean'); source['stop_reason'] = stop
            if stop: source['analysis'].update(status='INSUFFICIENT_EVIDENCE', issues=['INCOMPLETE_SWEEP'])
            result = e.explain(source)
            self.assertIsNone(result['candidate_observation'])
            self.assertEqual(result['original_stop_reason'], stop)
            self.assertEqual(result['original_analysis'], source['analysis'])

    def test_no_endpoint_empty_report_can_be_explained(self):
        source = fixture('clean'); source['samples'] = []
        source['analysis'].update(status='INSUFFICIENT_EVIDENCE', spike_threshold_retransmits_per_gib=None, tested_rates=[])
        self.assertEqual(e.explain(source)['samples'], [])

    def test_missing_fields_remain_unknown_in_json_and_text(self):
        for field in ('bytes', 'retransmits', 'spike_threshold_retransmits_per_gib'):
            with self.subTest(field=field):
                source = fixture()
                if field == 'spike_threshold_retransmits_per_gib':
                    del source['analysis'][field]
                else:
                    del source['samples'][3]['sender'][field]
                result = e.explain(source)
                if field != 'spike_threshold_retransmits_per_gib':
                    self.assertEqual(result['samples'][3]['status'], 'UNAVAILABLE')
                self.assertIsNone(result['samples'][3]['events_at_threshold'])
                self.assertIsNone(result['candidate_observation']['threshold_hits'])
                with redirect_stdout(io.StringIO()) as out: e.print_explanation(result)
                self.assertIn('不能评估触发强度', out.getvalue())
                sample_lines = [line for line in out.getvalue().splitlines() if line.startswith('  ')]
                self.assertNotIn('None', '\n'.join(sample_lines))
                self.assertIn('不可评估', sample_lines[3])

    def test_integer_threshold_exact_and_just_above_boundary(self):
        for size, expected in ((2**30, 100), (2**30+1, 101)):
            source = fixture('clean'); source['samples'][0]['sender'] = dict(bytes=size, retransmits=0)
            self.assertEqual(e.explain(source)['samples'][0]['events_at_threshold'], expected)

    def test_invalid_counts_bytes_and_rates_are_rejected(self):
        for field, values in (('bytes', [True, 0, -1, 1.5, float('inf')]),
                              ('retransmits', [False, -1, 0.5, float('nan')])):
            for value in values:
                with self.subTest(field=field, value=value):
                    source = fixture(); source['samples'][0]['sender'][field] = value
                    with self.assertRaises(ValueError): e.explain(source)
        for value in (True, -1, float('nan'), float('inf')):
            source = fixture(); source['samples'][0]['rate_mbps'] = value
            with self.assertRaises(ValueError): e.explain(source)

    def test_conflicting_normalization_is_rejected(self):
        source = fixture(); source['samples'][0]['sender']['retransmits_per_gib'] = 100
        with self.assertRaises(ValueError): e.explain(source)

    def test_reference_samples_do_not_count_as_sweep(self):
        source = fixture(schema='dvt.htb-measurement/1')
        reference = copy.deepcopy(source['samples'][3]); reference['role'] = 'reference-start'
        source['samples'] += [reference]*3
        self.assertEqual(e.explain(source)['candidate_observation']['threshold_hits'], 2)

    def make_report(self, directory, source, plan=None):
        (directory / 'INCOMPLETE').write_text('fixture', encoding='utf-8')
        (directory / 'plan.json').write_text(json.dumps({} if plan is None else plan), encoding='utf-8')
        (directory / 'measurement-result.json').write_text(json.dumps(source), encoding='utf-8')
        e.measurement.finalize_evidence(directory)

    def test_cli_roundtrip_is_deterministic_and_read_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp); self.make_report(directory, fixture())
            before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.iterdir()}
            texts = []
            for _ in range(2):
                out = io.StringIO()
                with redirect_stdout(out): code = e.main(['--input-dir', tmp, '--json'])
                self.assertEqual(code, 0); texts.append(out.getvalue())
            self.assertEqual(texts[0], texts[1])
            self.assertEqual(json.loads(texts[0])['source']['schema'], 'dvt.path-measurement/1')
            with redirect_stdout(io.StringIO()) as out: self.assertEqual(e.main(['--input-dir', tmp]), 0)
            self.assertIn('原候选保留', out.getvalue())
            self.assertIn('计划覆盖不可评估', out.getvalue())
            self.assertEqual(before, {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.iterdir()})

    def test_complete_coverage_with_and_without_candidate_preserves_analysis(self):
        for pattern in ('clean', 'isolated', 'sustained', 'highest'):
            with self.subTest(pattern=pattern):
                source, plan = coverage_fixture(pattern)
                before = copy.deepcopy((source, plan))
                data = e.explain(source)
                lines = e._coverage_lines(data, plan)
                self.assertEqual(lines[0], '归档计划扫描档（最终 schedule，含已追加细扫）：20 Mbps × 3、40 Mbps × 3')
                self.assertEqual(lines[1], '样本齐全且原汇总有效的档位：20 Mbps、40 Mbps')
                self.assertEqual(lines[2], '缺失/不足/无效的档位：无')
                self.assertEqual((source, plan), before)
                self.assertEqual(data['original_analysis'], source['analysis'])

    def test_middle_gap_and_stop_do_not_become_continuous_coverage(self):
        for stop in ('TIME_LIMIT', 'BUDGET_LIMIT'):
            with self.subTest(stop=stop):
                source, plan = coverage_fixture()
                del source['samples'][3:5]
                source['analysis']['tested_rates'][0].update(samples=1, eligible=False, status='INCONCLUSIVE')
                source['analysis'].update(status='INSUFFICIENT_EVIDENCE', issues=['INCOMPLETE_SWEEP'])
                source['stop_reason'] = stop
                data = e.explain(source)
                lines = e._coverage_lines(data, plan)
                self.assertEqual(lines[1], '样本齐全且原汇总有效的档位：40 Mbps')
                self.assertEqual(lines[2], '缺失/不足/无效的档位：20 Mbps（样本不足；已采 1/3，原标记有效 1）')
                with redirect_stdout(io.StringIO()) as out: e.print_explanation(data, lines)
                self.assertIn('原报告停止原因：' + stop, out.getvalue())
                self.assertIn('原报告状态：INSUFFICIENT_EVIDENCE', out.getvalue())
                self.assertIn('仅描述离散 sweep 档位', out.getvalue())

    def test_missing_and_ineligible_samples_remain_distinct(self):
        source, plan = coverage_fixture()
        del source['samples'][3:6]
        source['samples'][3]['eligible'] = False
        source['analysis']['tested_rates'][0].update(samples=0, eligible=False, status='INCONCLUSIVE')
        source['analysis']['tested_rates'][1].update(eligible=False, status='INCONCLUSIVE')
        lines = e._coverage_lines(e.explain(source), plan)
        self.assertEqual(lines[1], '样本齐全且原汇总有效的档位：无')
        self.assertIn('20 Mbps（无扫描样本；已采 0/3，原标记有效 0）', lines[2])
        self.assertIn('40 Mbps（含无效样本；已采 3/3，原标记有效 2）', lines[2])

    def test_no_endpoint_reports_all_planned_sweeps_missing(self):
        source, plan = coverage_fixture()
        source['samples'] = []
        source['stop_reason'] = 'NO_USABLE_ENDPOINT'
        source['analysis'].update(status='INSUFFICIENT_EVIDENCE', spike_threshold_retransmits_per_gib=None)
        for group in source['analysis']['tested_rates']:
            group.update(samples=0, eligible=False, status='INCONCLUSIVE')
        data = e.explain(source)
        lines = e._coverage_lines(data, plan)
        self.assertEqual(lines[1], '样本齐全且原汇总有效的档位：无')
        self.assertEqual(lines[2].count('无扫描样本'), 2)
        self.assertEqual(data['original_stop_reason'], 'NO_USABLE_ENDPOINT')

    def test_htb_final_schedule_counts_fine_sweep_not_cap_or_reference(self):
        source, plan = coverage_fixture(schema='dvt.htb-measurement/1')
        plan.update(rate_cap_mbps=1000, rates_mbps=[10, 20, 30, 40], max_fine_rates=3)
        for role in ('reference-start', 'reference-end'):
            reference = copy.deepcopy(source['samples'][6]); reference['role'] = role
            source['samples'] += [reference]*3
            plan['schedule'] += [[role, 40]]*3
        fine = copy.deepcopy(source['samples'][3]); fine['rate_mbps'] = 30
        source['samples'] += [fine]*2
        plan['schedule'] += [['sweep', 30]]*3
        source['analysis']['tested_rates'].append(dict(rate_mbps=30, samples=2, eligible=False, status='INCONCLUSIVE'))
        lines = e._coverage_lines(e.explain(source), plan)
        self.assertEqual(lines[0], '归档计划扫描档（最终 schedule，含已追加细扫）：20 Mbps × 3、30 Mbps × 3、40 Mbps × 3')
        self.assertEqual(lines[1], '样本齐全且原汇总有效的档位：20 Mbps、40 Mbps')
        self.assertEqual(lines[2], '缺失/不足/无效的档位：30 Mbps（样本不足；已采 2/3，原标记有效 2）')

    def test_complete_sweeps_do_not_override_control_or_reference_refusal(self):
        for issue in ('CONTROL_DRIFT', 'INVALID_CONTROL', 'INVALID_REFERENCE'):
            with self.subTest(issue=issue):
                source, plan = coverage_fixture()
                source['analysis'].update(status='INSUFFICIENT_EVIDENCE', issues=[issue])
                data = e.explain(source)
                with redirect_stdout(io.StringIO()) as out: e.print_explanation(data, e._coverage_lines(data, plan))
                self.assertIn('原报告状态：INSUFFICIENT_EVIDENCE', out.getvalue())
                self.assertIn('样本齐全且原汇总有效的档位：20 Mbps、40 Mbps', out.getvalue())
                self.assertEqual(data['original_analysis']['issues'], [issue])

    def test_no_independent_sweep_does_not_claim_full_coverage(self):
        source, plan = coverage_fixture()
        source['samples'] = [r for r in source['samples'] if r['role'] != 'sweep']
        source['analysis']['tested_rates'] = []
        plan['schedule'] = [r for r in plan['schedule'] if r[0] != 'sweep']
        self.assertEqual(e._coverage_lines(e.explain(source), plan),
                         ['归档计划：无独立扫描档；控制/reference 不计入扫描覆盖。'])

    def test_unsupported_plan_only_downgrades_new_summary(self):
        source, _ = coverage_fixture()
        plans = ({}, [], {'schedule': None}, {'schedule': [None]}, {'schedule': [['sweep']]},
                 {'schedule': [['unknown', 20]]})
        plans += tuple({'schedule': [['sweep', rate]]} for rate in
                       (True, 0, -1, '20', float('nan'), float('inf'), 10**400))
        for plan in plans:
            with self.subTest(plan=plan), tempfile.TemporaryDirectory() as tmp:
                self.make_report(Path(tmp), source, plan)
                with redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(e.main(['--input-dir', tmp]), 0)
                self.assertIn('计划覆盖不可评估', out.getvalue())
                self.assertIn('原报告状态：NO_RISE_IN_TESTED_RANGE', out.getvalue())
                with redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(e.main(['--input-dir', tmp, '--json']), 0)
                self.assertEqual(json.loads(out.getvalue())['original_analysis'], source['analysis'])

    def test_unparseable_but_integrity_checked_plan_preserves_old_explanation(self):
        for payload in ('{', '['*1100 + '0' + ']'*1100):
            with self.subTest(length=len(payload)), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp); self.make_report(directory, fixture())
                (directory / 'plan.json').write_text(payload, encoding='utf-8')
                (directory / 'INCOMPLETE').write_text('fixture update', encoding='utf-8')
                e.measurement.finalize_evidence(directory)
                with redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(e.main(['--input-dir', tmp]), 0)
                self.assertIn('计划覆盖不可评估', out.getvalue())
                self.assertIn('原候选保留', out.getvalue())

    def test_missing_summary_fields_remain_unknown(self):
        for field in ('samples', 'eligible', 'status'):
            with self.subTest(field=field):
                source, plan = coverage_fixture()
                del source['analysis']['tested_rates'][0][field]
                lines = e._coverage_lines(e.explain(source), plan)
                self.assertEqual(lines, ['计划覆盖不可评估：归档计划或逐档汇总字段不足/不支持。'])

    def test_contradictory_plan_samples_or_summary_do_not_claim_coverage(self):
        for case in ('unplanned', 'extra-sample', 'duplicate', 'omitted', 'count', 'eligible', 'status'):
            with self.subTest(case=case):
                source, plan = coverage_fixture()
                groups = source['analysis']['tested_rates']
                if case == 'unplanned': plan['schedule'] = [r for r in plan['schedule'] if r != ['sweep', 20]]
                elif case == 'extra-sample': source['samples'].append(copy.deepcopy(source['samples'][3]))
                elif case == 'duplicate': groups.append(copy.deepcopy(groups[0]))
                elif case == 'omitted': groups.pop()
                elif case == 'count': groups[0]['samples'] = 2
                elif case == 'eligible': groups[0]['eligible'] = False
                elif case == 'status': groups[0]['status'] = 'INCONCLUSIVE'
                self.assertEqual(e._coverage_lines(e.explain(source), plan),
                                 ['计划覆盖不可评估：计划、扫描样本与逐档汇总资料不一致。'])

    def test_coverage_cli_is_read_only_and_does_not_expand_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp); source, plan = coverage_fixture('isolated')
            self.make_report(directory, source, plan)
            before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.iterdir()}
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(e.main(['--input-dir', tmp]), 0)
            self.assertIn('样本齐全且原汇总有效的档位：20 Mbps、40 Mbps', out.getvalue())
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(e.main(['--input-dir', tmp, '--json']), 0)
            data = json.loads(out.getvalue())
            self.assertEqual(set(data), {'schema', 'tool_version', 'original_analysis', 'original_stop_reason',
                                         'samples', 'candidate_observation', 'independent_replication', 'htb_entry', 'source'})
            self.assertEqual(data['schema'], 'dvt.measurement-explanation/1')
            self.assertEqual(data['tool_version'], '0.1.1')
            self.assertEqual(data['original_analysis'], source['analysis'])
            self.assertEqual(before, {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.iterdir()})

    def test_plan_tamper_refuses_text_and_json_before_any_explanation(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp); source, plan = coverage_fixture()
            self.make_report(directory, source, plan)
            (directory / 'plan.json').write_text('{}', encoding='utf-8')
            for flags in ([], ['--json']):
                with redirect_stdout(io.StringIO()) as out, redirect_stderr(io.StringIO()):
                    self.assertEqual(e.main(['--input-dir', tmp] + flags), 2)
                self.assertEqual(out.getvalue(), '')

    def test_tamper_and_incomplete_produce_no_json(self):
        for mode in ('tamper', 'incomplete'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp); self.make_report(directory, fixture())
                if mode == 'tamper': (directory / 'measurement-result.json').write_text('{}', encoding='utf-8')
                else: (directory / 'INCOMPLETE').write_text('interrupted', encoding='utf-8')
                with redirect_stdout(io.StringIO()) as out, redirect_stderr(io.StringIO()):
                    self.assertEqual(e.main(['--input-dir', tmp, '--json']), 2)
                self.assertEqual(out.getvalue(), '')

    def test_htb_recovery_requirement_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp); source = fixture(schema='dvt.htb-measurement/1'); source['endpoint'] = {'id': 'fixture'}
            self.make_report(directory, source)
            with redirect_stderr(io.StringIO()): self.assertEqual(e.main(['--input-dir', tmp]), 2)
            state = directory / 'htb-transaction/state.json'; state.parent.mkdir(); state.write_text('{"phase":"RESTORED"}', encoding='utf-8')
            (directory / 'INCOMPLETE').write_text('fixture update', encoding='utf-8')
            e.measurement.finalize_evidence(directory)
            self.assertEqual(e.explain_directory(directory)['source']['schema'], 'dvt.htb-measurement/1')


if __name__ == '__main__':
    unittest.main()
