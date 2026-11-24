"""真实 Shell 的多队列计数与预算下界回归，所有数据均为离线合成。"""
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
COUNTERS = (ROOT / 'tools/measurement_counters.sh.in').read_text(encoding='utf-8')


def function(source, name):
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S).group(0)


@unittest.skipUnless(BASH and JQ, 'Bash and jq are required')
class MeasurementCounters(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bridge = 'set -Eeuo pipefail\nPATH="/usr/bin:/bin:$PATH"\n' + (
            'jq() { ' + shlex.quote(JQ.replace('\\', '/')) +
            (' --binary' if os.name == 'nt' else '') + ' "$@"; }\n')
        self.source = self.bridge + '\n'.join(function(COUNTERS, name) for name in (
            'qdisc_counter_snapshot', 'counter_delta_json', 'benchmark_known_payload_bytes')) + '\n'

    def shell(self, code, expected=0):
        result = subprocess.run([BASH], input=(self.source + code).encode(),
                                cwd=self.directory, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stderr.decode(errors='replace'))
        return result.stdout.decode(errors='replace')

    def write_tc(self, name, parent=':2', count=100):
        text = ('qdisc mq 0: root\n Sent 0 bytes 0 pkt (dropped 0, overlimits 0 requeues 0)\n'
                'qdisc fq 0: parent :1 limit 10000p\n'
                f' Sent {count} bytes 1 pkt (dropped 0, overlimits 0 requeues 0)\n'
                f'qdisc fq 0: parent {parent} limit 10000p\n'
                f' Sent {count * 2} bytes 2 pkt (dropped 0, overlimits 0 requeues 0)\n')
        (self.directory / name).write_text(text, encoding='utf-8')

    def test_mq_anonymous_leaf_handles_have_distinct_counter_identity(self):
        self.write_tc('before.tc')
        self.write_tc('after.tc', count=200)
        value = self.shell('''
printf 'eth0\\n' >ifaces
tc() { cat "$TC_FIXTURE"; }
TC_FIXTURE=before.tc qdisc_counter_snapshot ifaces >before
TC_FIXTURE=after.tc qdisc_counter_snapshot ifaces >after
counter_delta_json before after
''')
        delta = json.loads(value)
        self.assertEqual(delta['eth0.root.mq.0:.bytes'], 0)
        self.assertEqual(delta['eth0.leaf.fq.0:.:1.bytes'], 100)
        self.assertEqual(delta['eth0.leaf.fq.0:.:2.bytes'], 200)
        self.assertEqual(len(delta), 15)

    def test_hex_parent_is_leaf_and_parent_change_invalidates_delta(self):
        self.write_tc('before.tc', parent='1:a')
        self.write_tc('after.tc', parent='1:b', count=200)
        text = self.shell('''
printf 'eth0\\n' >ifaces
tc() { cat "$TC_FIXTURE"; }
TC_FIXTURE=before.tc qdisc_counter_snapshot ifaces >before
cat before
''')
        self.assertIn('eth0.leaf.fq.0:.1:a.bytes', text)
        result = subprocess.run([BASH], input=(self.source + '''
printf 'eth0\\n' >ifaces
tc() { cat "$TC_FIXTURE"; }
TC_FIXTURE=before.tc qdisc_counter_snapshot ifaces >before
TC_FIXTURE=after.tc qdisc_counter_snapshot ifaces >after
counter_delta_json before after
''').encode(), cwd=self.directory, capture_output=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)

    def test_known_sender_lower_bound_keeps_valid_direction_when_other_json_is_partial(self):
        (self.directory / 'upload.iperf3.json').write_text('{"end":{"sum_sent":{"bytes":1234}}}')
        (self.directory / 'download.iperf3.json').write_text('{"end":')
        self.assertEqual(self.shell('benchmark_known_payload_bytes "$PWD"\n').strip(), '1234')
        (self.directory / 'download.iperf3.json').write_text('{"end":{"sum_sent":{"bytes":2345}}}')
        self.assertEqual(self.shell('benchmark_known_payload_bytes "$PWD"\n').strip(), '3579')


if __name__ == '__main__':
    unittest.main()
