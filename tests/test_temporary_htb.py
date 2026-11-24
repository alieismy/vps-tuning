"""临时整形的计划、恢复参数和所有权边界；不启动真实 tc 或公网流量。"""
import copy
from contextlib import nullcontext
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import Mock, patch

import dvt_htb_transaction as h

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('measure_htb_test', ROOT / 'dvt-measure.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

OPTIONS = dict(limit=1234, flow_limit=50, buckets=1024, orphan_mask=1023, quantum=1600,
               initial_quantum=6400, pacing=False, low_rate_threshold=68750,
               refill_delay=40000, timer_slack=10000, horizon=10000000, horizon_drop=None)
ORIGINAL = dict(qdiscs=[dict(kind='fq', root=True, handle='0:', options=OPTIONS)], classes=[], filters=[])


def args(**changes):
    values = dict(rate_cap=20, samples=3, seconds=5, max_attempts=2, host=None, max_duration=300,
                  budget_mib=600, family='4', interface='test0', lower=2, upper=18, fine_step=1,
                  output_dir='', ledger='/unused', window_id='fixture')
    values.update(changes)
    return type('Args', (), values)()


def row(role, rate, retrans=0, eligible=True):
    return dict(role=role, rate_mbps=rate, eligible=eligible, issues=[] if eligible else ['UNDERDRIVEN'],
                sender=dict(retransmits_per_gib=retrans), receiver=dict(mbps=rate),
                endpoint={'ip': '192.0.2.1'}, route={'dev': 'test0'})


class TemporaryHTBTests(unittest.TestCase):
    def test_watch_restores_if_owner_exits_before_term(self):
        state = dict(phase='ACTIVE', owner_pid=42, owner_token='owner', deadline_monotonic=0)
        with tempfile.TemporaryDirectory() as temp, patch.object(h, 'load', return_value=(state, {})), \
                patch.object(h, 'owner_token', return_value='owner'), \
                patch.object(h.os, 'kill', side_effect=ProcessLookupError), \
                patch.object(h, 'restore') as restore:
            checkpoint = Path(temp)
            h.watch(checkpoint)
            restore.assert_called_once_with(checkpoint)

    def test_watch_restores_if_owner_exits_before_kill(self):
        state = dict(phase='ACTIVE', owner_pid=42, owner_token='owner', deadline_monotonic=0)
        with tempfile.TemporaryDirectory() as temp, patch.object(h, 'load', return_value=(state, {})), \
                patch.object(h, 'owner_token', return_value='owner'), \
                patch.object(h.time, 'monotonic', side_effect=[1, 1, 10]), \
                patch.object(h.signal, 'SIGKILL', 9, create=True), \
                patch.object(h.os, 'kill', side_effect=[None, ProcessLookupError]), \
                patch.object(h, 'restore') as restore:
            checkpoint = Path(temp)
            h.watch(checkpoint)
            restore.assert_called_once_with(checkpoint)

    def test_watch_preserves_other_signal_errors(self):
        state = dict(phase='ACTIVE', owner_pid=42, owner_token='owner', deadline_monotonic=0)
        with tempfile.TemporaryDirectory() as temp, patch.object(h, 'load', return_value=(state, {})), \
                patch.object(h, 'owner_token', return_value='owner'), \
                patch.object(h.os, 'kill', side_effect=PermissionError), \
                patch.object(h, 'restore') as restore, self.assertRaises(PermissionError):
            h.watch(Path(temp))
        restore.assert_not_called()

    def test_fq_restore_units_flags_and_bands(self):
        options = dict(OPTIONS, bands=3, **{'priomap ': [1] * 16, 'weights ': [589824, 196608, 65536]}, maxrate=125000)
        normalized, argv = h.fq_options(options)
        for pair in (('maxrate', '1000000bit'), ('low_rate_threshold', '550000bit'),
                     ('refill_delay', '40000us'), ('timer_slack', '10000ns')):
            self.assertEqual(argv[argv.index(pair[0]) + 1], pair[1])
        self.assertIn('nopacing', argv)
        self.assertIn('horizon_drop', argv)
        self.assertEqual(normalized['priomap'], [1] * 16)

    def test_restore_parser_uses_standard_syntax_when_supported(self):
        help_result = subprocess.CompletedProcess([], 1, '', 'Usage: ... fq [ limit PACKETS ]\n')
        with patch.object(h.subprocess, 'run', return_value=help_result) as run:
            argv = h.validated_fq_restore_args(OPTIONS)
        self.assertEqual(argv, h.fq_options(OPTIONS)[1])
        for call in run.call_args_list:
            command = call.args[0]
            self.assertEqual(command[:5], ['tc', 'qdisc', 'add', 'root', 'fq'])
            self.assertNotIn('dev', command)  # 无接口，绝不向真实 qdisc 写入。
            self.assertEqual(command[-1], 'help')

    def test_restore_parser_handles_iproute2_weights_skip_token(self):
        options = dict(OPTIONS, **{'weights ': [589824, 196608, 65536]})
        help_result = subprocess.CompletedProcess([], 1, '', 'Usage: ... fq [ limit PACKETS ]\n')
        # 6.15 的额外 NEXT_ARG 跳过首个权重，将末尾 help 当成第三个数字。
        failure = subprocess.CompletedProcess([], 1, '', 'Illegal "weights" element, positive number expected\n')
        with patch.object(h.subprocess, 'run', side_effect=[help_result, failure, help_result]):
            argv = h.validated_fq_restore_args(options)
        self.assertEqual(argv[argv.index('weights') + 1:], ['0', '589824', '196608', '65536'])
        self.assertEqual(h.fq_options(options)[0]['weights'], [589824, 196608, 65536])

    def test_restore_parser_refuses_unrecognized_or_failed_syntax(self):
        options = dict(OPTIONS, weights=[589824, 196608, 65536])
        help_result = subprocess.CompletedProcess([], 1, '', 'Usage: ... fq [ limit PACKETS ]\n')
        unknown = subprocess.CompletedProcess([], 1, '', 'What is "weights"?\n')
        malformed = subprocess.CompletedProcess([], 1, '', 'Illegal "weights" element, positive number expected\n')
        for responses in ([unknown], [help_result, unknown], [help_result, malformed, unknown]):
            with patch.object(h.subprocess, 'run', side_effect=responses), self.assertRaises(h.HTBError):
                h.validated_fq_restore_args(options)

    def test_restore_syntax_failure_blocks_transaction_before_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            checkpoint = Path(temp) / 'checkpoint'
            transaction = h.Transaction('test0', checkpoint, 30)
            with patch.object(h.os, 'geteuid', return_value=0, create=True), patch.object(h, 'secure'), \
                    patch.dict('sys.modules', {'fcntl': Mock()}), \
                    patch.object(h, 'preflight', return_value=({}, ORIGINAL)), \
                    patch.object(h, 'validated_fq_restore_args', side_effect=h.HTBError('restore syntax')), \
                    patch.object(h, 'execute') as execute, self.assertRaisesRegex(h.HTBError, 'restore syntax'):
                transaction.begin()
            execute.assert_not_called()
            self.assertFalse(checkpoint.exists())

    def test_restore_replays_validated_weights_arguments(self):
        original = copy.deepcopy(ORIGINAL)
        original['qdiscs'][0]['options']['weights'] = [589824, 196608, 65536]
        argv = h.fq_restore_arg_variants(original['qdiscs'][0]['options'])[1]
        current = dict(qdiscs=[dict(root=True, kind='htb', handle='1234:')], classes=[], filters=[])
        state = dict(phase='ACTIVE', interface='test0', root_handle='1234:', leaf_handle='9234:',
                     active_snapshot=current, restore_fq_argv=argv)
        with tempfile.TemporaryDirectory() as temp, patch.object(h, 'locked', return_value=nullcontext()), \
                patch.object(h, 'load', return_value=(state, original)), \
                patch.object(h, 'snapshot', side_effect=[current, original]), \
                patch.object(h, 'clear_registry'), patch.object(h, 'execute') as execute:
            h.restore(Path(temp))
        execute.assert_called_once_with(['tc', 'qdisc', 'replace', 'dev', 'test0', 'root', 'fq', *argv])
        self.assertEqual(state['phase'], 'RESTORED')

    def test_checkpoint_rejects_restore_args_unrelated_to_snapshot(self):
        with tempfile.TemporaryDirectory() as temp:
            checkpoint = Path(temp)
            h.save(checkpoint / 'original.json', ORIGINAL)
            (checkpoint / 'recovery.py').write_text('fixture')
            state = dict(schema=h.SCHEMA, phase='PREPARED', interface='test0', identity={},
                         original_sha256=h.digest(checkpoint / 'original.json'),
                         recovery_sha256=h.digest(checkpoint / 'recovery.py'),
                         restore_fq_argv=['limit', '9999'])
            h.save(checkpoint / 'state.json', state)
            with patch.object(h, 'secure'), patch.object(h, 'identity', return_value={}), \
                    self.assertRaisesRegex(h.HTBError, '恢复参数与原快照不符'):
                h.load(checkpoint)

    def test_unknown_and_ambiguous_options_rejected(self):
        for addition in ({'new_kernel_option': 1}, {'quantum': True}, {'priomap': [1]},
                         {'horizon_cap': None}, {'pacing': 1}, {'weights': [1, 2]},
                         {'bands': 3, 'priomap ': [1] * 16, 'priomap': [1] * 16}):
            with self.subTest(addition=addition), self.assertRaises(h.HTBError):
                h.fq_options(dict(OPTIONS, **addition))

    def test_only_zero_root_handle_is_semantically_normalized(self):
        current = copy.deepcopy(ORIGINAL)
        current['qdiscs'][0]['handle'] = '8001:'
        self.assertTrue(h.equivalent(ORIGINAL, current))
        explicit = copy.deepcopy(ORIGINAL)
        explicit['qdiscs'][0]['handle'] = '100:'
        self.assertFalse(h.equivalent(explicit, current))
        current['qdiscs'][0]['options']['quantum'] += 1
        self.assertFalse(h.equivalent(ORIGINAL, current))

    def test_topology_preflight_refuses_foreign_objects_before_writes(self):
        cases = [dict(ORIGINAL, filters=[{'kind': 'flower'}]),
                 dict(ORIGINAL, classes=[{'kind': 'htb'}]),
                 dict(ORIGINAL, qdiscs=ORIGINAL['qdiscs'] + [{'kind': 'clsact'}]),
                 dict(ORIGINAL, qdiscs=[{'kind': 'mq', 'root': True, 'handle': '0:'}])]
        for data in cases:
            with patch.object(h, 'identity', return_value={}), patch.object(h, 'execute', return_value='[{"flags":["UP"]}]'), patch.object(h, 'snapshot', return_value=data), self.assertRaises(h.HTBError):
                h.preflight('test0')

    def test_partial_owned_tree_and_external_leaf(self):
        state = dict(phase='MUTATING', root_handle='1234:', leaf_handle='9234:')
        root = dict(root=True, kind='htb', handle='1234:')
        data = dict(qdiscs=[root], classes=[], filters=[])
        self.assertTrue(h.owned(state, data))
        data['classes'] = [dict(kind='htb', handle='1234:1')]
        data['qdiscs'].append(dict(kind='fq_codel', handle='0:', parent='1234:1'))
        self.assertTrue(h.owned(state, data))
        state['phase'] = 'ACTIVE'
        self.assertFalse(h.owned(state, data))
        data['qdiscs'][1].update(kind='fq', handle='9234:')
        self.assertTrue(h.owned(state, data))
        data['qdiscs'].append(dict(kind='ingress', handle='ffff:'))
        self.assertFalse(h.owned(state, data))

    def test_empty_tc_objects_are_only_accepted_after_command_success(self):
        with patch.object(h, 'execute', side_effect=['\n', '', json.dumps(ORIGINAL['qdiscs'])]):
            self.assertEqual(h.snapshot('test0'), ORIGINAL)
        with patch.object(h, 'execute', side_effect=h.HTBError('tc failed')), self.assertRaises(h.HTBError):
            h.snapshot('test0')

    def test_legacy_class_rate_units_and_full_parameter_observation(self):
        raw = 'class htb 1234:1 root leaf 9234: prio 0 quantum 15140 rate 2Mbit ceil 2000Kbit burst 256Kb/8 mpu 0b cburst 32Kb/8 mpu 0b level 0'
        cls = h.parse_classes(raw)[0]
        self.assertEqual(cls['options'], dict(rate=250000, ceil=250000))
        self.assertEqual(cls['raw_parameters'], raw)
        self.assertNotEqual(h.parse_classes(raw.replace('quantum 15140', 'quantum 1000')), [cls])
        for invalid in (raw.replace('htb', 'hfsc'), raw.replace('2Mbit', 'unknown'),
                        raw + ' rate 3Mbit', '{"kind":"htb"}'):
            with self.assertRaises(h.HTBError):
                h.parse_classes(invalid)

    def test_plan_separates_offered_cap_and_shaping_range(self):
        p = m.make_htb_plan(args(), [])
        self.assertEqual(p['rates_mbps'], [2, 6, 10, 14, 18])
        self.assertEqual(p['schema'], m.HTB_SCHEMA)
        self.assertTrue(p['configuration_changed'])
        self.assertEqual(sum(role == 'reference-start' for role, _ in p['schedule']), 3)
        self.assertEqual(sum(role == 'reference-end' for role, _ in p['schedule']), 3)
        self.assertEqual(p['worst_case_reservations_bytes'], 2 * m.reservation_bytes(1, 5) +
                         (len(p['schedule']) + 9) * m.reservation_bytes(20, 5))
        for bad in (args(lower=18, upper=2), args(upper=20), args(interface='bad;cmd')):
            with self.assertRaises(m.MeasurementError):
                m.make_htb_plan(bad, [])

    def test_reference_drift_blocks_candidate(self):
        a = args()
        plan = m.make_htb_plan(a, [])
        run = m.HTBMeasurementRun(a, plan)
        run.rows = [row(role, rate, 1000 if role == 'sweep' and rate >= 14 else 0) for role, rate in plan['schedule']]
        result = run.analyze_result(None)
        self.assertEqual(result['candidate_interval'], dict(lower_mbps=10, upper_mbps=14))
        for r in run.rows:
            if r['role'] == 'reference-end':
                r['receiver']['mbps'] *= .5
        result = run.analyze_result(None)
        self.assertIn('REFERENCE_DRIFT', result['issues'])
        self.assertIsNone(result['candidate_interval'])

    def test_insufficient_load_prevents_fine_scan(self):
        a = args()
        run = m.HTBMeasurementRun(a, m.make_htb_plan(a, []))
        run.rows = [row(role, rate, 1000 if rate >= 14 else 0) for role, rate in run.plan['schedule']]
        self.assertEqual(run.bracket(), (10, 14))
        next(r for r in run.rows if r['role'] == 'sweep')['eligible'] = False
        self.assertIsNone(run.bracket())

    def test_recovery_failure_propagates_instead_of_completing(self):
        with tempfile.TemporaryDirectory() as temp:
            a = args(output_dir=temp)
            run = m.HTBMeasurementRun(a, m.make_htb_plan(a, []))
            transaction = Mock()
            transaction.close.side_effect = h.HTBError('restore failed')
            run.take = Mock(side_effect=m.StopMeasurement('BUDGET_LIMIT'))
            with patch.object(h, 'Transaction', return_value=transaction), self.assertRaisesRegex(h.HTBError, 'restore failed'):
                run.run_schedule({}, {'dev': 'test0'})
            transaction.close.assert_called_once()
            self.assertFalse((Path(temp) / 'COMPLETED').exists())

    def test_route_interface_mismatch_has_no_htb_writes(self):
        a = args()
        run = m.HTBMeasurementRun(a, m.make_htb_plan(a, []))
        with patch.object(h, 'Transaction') as factory, self.assertRaises(m.MeasurementError):
            run.run_schedule({}, {'dev': 'other0'})
        factory.assert_not_called()

    def test_coarse_fine_scan_preserves_reference_and_restores(self):
        with tempfile.TemporaryDirectory() as temp:
            a = args(output_dir=temp)
            run = m.HTBMeasurementRun(a, m.make_htb_plan(a, []))
            def take(_selected, _route, role, rate):
                run.rows.append(row(role, rate, 1000 if rate >= 13 else 0))
            run.take = take
            with patch.object(h, 'Transaction') as factory:
                run.run_schedule({}, {'dev': 'test0'})
                factory.return_value.close.assert_called_once()
            result = run.analyze_result(None)
            self.assertEqual(result['candidate_interval'], dict(lower_mbps=12, upper_mbps=13))
            self.assertEqual(len(run.rows), 30)
            self.assertEqual([r['role'] for r in run.rows[-6:]], ['reference-end'] * 3 + ['control-end'] * 3)

    def test_budget_stop_restores_and_has_no_candidate(self):
        with tempfile.TemporaryDirectory() as temp:
            a = args(output_dir=temp)
            run = m.HTBMeasurementRun(a, m.make_htb_plan(a, []))
            run.take = Mock(side_effect=m.StopMeasurement('BUDGET_LIMIT'))
            with patch.object(h, 'Transaction') as factory, self.assertRaises(m.StopMeasurement):
                run.run_schedule({}, {'dev': 'test0'})
            factory.return_value.close.assert_called_once()
            result = run.analyze_result('BUDGET_LIMIT')
            self.assertEqual(result['status'], 'INSUFFICIENT_EVIDENCE')
            self.assertIsNone(result['candidate_interval'])

    def test_report_requires_restored_checkpoint(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            m.write_json(root / 'plan.json', {})
            m.write_json(root / 'measurement-result.json', dict(schema=m.HTB_SCHEMA, endpoint={'ip': '192.0.2.1'}))
            (root / 'INCOMPLETE').write_text('fixture')
            m.finalize_evidence(root)
            with self.assertRaisesRegex(m.MeasurementError, '恢复证据'):
                m.verify_report(root)

    def test_no_endpoint_does_not_claim_temporary_configuration_change(self):
        with tempfile.TemporaryDirectory() as temp:
            a = args(output_dir=str(Path(temp) / 'output'))
            run = m.HTBMeasurementRun(a, m.make_htb_plan(a, []))
            run.budget = Mock(return_value={})
            with patch.object(m, 'diagnose', return_value={}), patch.object(m, 'bounded', return_value={}), patch.object(m, 'candidates_from', return_value=[]):
                result = run.run()
            self.assertEqual(result['stop_reason'], 'NO_USABLE_ENDPOINT')
            self.assertFalse(result['configuration_changed'])
            self.assertIsNone(run.transaction)
            self.assertTrue(run.plan['configuration_changed'])


if __name__ == '__main__':
    unittest.main()
