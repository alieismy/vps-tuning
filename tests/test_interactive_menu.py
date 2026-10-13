"""通过真实 Linux PTY 执行菜单；隔离系统边界，不代表终端视觉或 VPS 验收。"""

from pathlib import Path
import errno
import os
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest

if sys.platform.startswith('linux'):
    import fcntl
    import pty
    import termios


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
RUNNER = r'''
source "$1"
fixture_version="$2"
[ "$fixture_version" != current ] || fixture_version="$CONTROLLER_VERSION"
fixture_state="$3"
home_facts_collect() {
  HOME_FACTS_READY=1 HOME_ROOT=1 HOME_PLATFORM_OK=1
  HOME_OS='Fixture OS' HOME_ARCH=x86_64 HOME_CPUS=1 HOME_MEMORY_MIB=1024
  HOME_PROFILE=debian13-1c1g HOME_RESOURCE_CLASS=1C1GB HOME_PLATFORM_REASON=''
  HOME_STATE="$fixture_state" HOME_STATE_VERSION="$fixture_version"
  HOME_STATE_PORT=200 HOME_STATE_UPDATED='' HOME_RUNTIME='fixture runtime'
}
# 保留 main、TTY 检查、菜单、输入、确认、分发与结果页；替换所有系统边界。
need_root() { :; }
need_command() { :; }
detect_environment() {
  DETECTED_PROFILE=debian13-1c1g DETECTED_LABEL='Fixture profile'
  DETECTED_PRETTY_NAME='Fixture OS' DETECTED_ARCH=x86_64
  DETECTED_CPUS=1 DETECTED_MEMORY_MIB=1024 DETECTED_RESOURCE_CLASS=1C1GB
}
read_existing_state() {
  STATE_PROFILE=debian13-1c1g STATE_VERSION="$fixture_version" STATE_PORT_SPEED_MBPS=200
}
resolve_profile_script() {
  PROFILE_FILE=fixture-profile PROFILE_PATH=/fixture/profile
  PROFILE_SHA256=fixture-digest PROFILE_SOURCE=fixture
}
resolve_companion_assets() { MEASUREMENT_PATH=/fixture/measurement; }
run_profile() { printf '\nFIXTURE_ACTION:%s\n' "$1"; }
run_update() { printf '\nFIXTURE_ACTION:update\n'; }
python3() {
  [ "$1" = /fixture/measurement ] && [ "$2" = diagnose ] || return 98
  printf '\nFIXTURE_ACTION:diagnose\n'
}
sysctl() { die 98 'FIXTURE_UNEXPECTED_SYSTEM_CALL:sysctl'; }
tc() { die 98 'FIXTURE_UNEXPECTED_SYSTEM_CALL:tc'; }
curl() { die 98 'FIXTURE_UNEXPECTED_SYSTEM_CALL:curl'; }
main
'''


@unittest.skipUnless(sys.platform.startswith('linux') and BASH,
                     'Real POSIX PTY menu tests require Linux and Bash; Windows skips explicitly')
class InteractiveMenuTest(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.tmp' / 'local' / 'menu-rc4'
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='pty-', dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.runner = self.work / 'runner.sh'
        self.runner.write_text(RUNNER, encoding='utf-8', newline='\n')

    def command(self, version, state):
        return [BASH, '--noprofile', '--norc', str(self.runner),
                str(ROOT / 'debian-vps-tuning.sh'), version, state]

    def menu(self, exchanges, version='current', state='VERIFIED', columns=80, term='xterm'):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, columns, 0, 0))

        def attach_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        env = dict(os.environ, TERM=term, NO_COLOR='1', DVT_ASCII='')
        # 子进程持有真正的 controlling terminal，stty 与 stdin/stdout TTY 检查均真实执行。
        process = subprocess.Popen(self.command(version, state), cwd=self.work, env=env,
                                   stdin=slave, stdout=slave, stderr=slave,
                                   preexec_fn=attach_terminal)
        os.close(slave)
        transcript = bytearray()
        cursor = 0
        deadline = time.monotonic() + 15

        def receive():
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, transcript.decode('utf-8', errors='replace'))
            ready, _, _ = select.select([master], [], [], min(remaining, 0.2))
            if not ready:
                return True
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    return False
                raise
            transcript.extend(chunk)
            return bool(chunk)

        try:
            for prompt, answer in exchanges:
                expected = prompt.encode('utf-8')
                while True:
                    found = transcript.find(expected, cursor)
                    if found >= 0:
                        cursor = found + len(expected)
                        break
                    self.assertTrue(receive(), transcript.decode('utf-8', errors='replace'))
                os.write(master, answer.encode('utf-8'))
            while receive():
                pass
            result = process.wait(timeout=5)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            os.close(master)
        output = transcript.decode('utf-8').replace('\r\n', '\n')
        self.assertNotIn('FIXTURE_UNEXPECTED_SYSTEM_CALL', output)
        self.assertEqual(result, 0, output)
        actions = re.findall(r'^FIXTURE_ACTION:([^\n]+)$', output, re.M)
        return output, actions

    def test_same_version_enter_dispatches_status(self):
        output, actions = self.menu([('Select [0-9,a] [6]: ', '\n')])
        self.assertEqual(actions, ['status'])
        self.assertIn('│', output)
        self.assertNotIn('\x1b', output)

    def test_same_version_applied_and_unmanaged_defaults(self):
        _, actions = self.menu([('Select [0-9,a] [5]: ', '\n')], state='APPLIED')
        self.assertEqual(actions, ['verify'])
        output, actions = self.menu([('Select [0-9,a] [1]: ', '\n'),
                                     ('请选择 [2]: ', '\n'),
                                     ('preflight 已通过。是否执行 apply？[y/N]：', '\n')],
                                    version='', state='UNMANAGED')
        self.assertEqual(actions, ['preflight'])
        self.assertIn('没有执行 apply', output)

    def test_invalid_input_reprompts_in_narrow_ascii_terminal(self):
        output, actions = self.menu([('Select [0-9,a] [6]: ', 'x\n'),
                                     ('Select [0-9,a] [6]: ', '6\n')], columns=50, term='dumb')
        self.assertEqual(actions, ['status'])
        self.assertIn('无效选择', output)
        self.assertNotIn('│', output)

    def test_rollback_default_no_and_explicit_yes(self):
        for answer, expected in (('\n', []), ('y\n', ['rollback'])):
            with self.subTest(answer=answer):
                output, actions = self.menu([('Select [0-9,a] [6]: ', '9\n'),
                                             ('是否执行 rollback？[y/N]：', answer)])
                self.assertEqual(actions, expected)
                if not expected:
                    self.assertIn('没有执行 rollback', output)

    def test_old_versions_enter_dispatches_diagnose_without_update(self):
        for version in ('0.2.0-rc.2', '0.2.0-rc.3'):
            with self.subTest(version=version):
                output, actions = self.menu([('Select [0-9,a] [7]: ', '\n')], version=version)
                self.assertEqual(actions, ['diagnose'])
                self.assertIn(version, output)
                self.assertIn('不一致', output)

    def test_old_version_explicit_update_is_available(self):
        _, actions = self.menu([('Select [0-9,a] [7]: ', '8\n')], version='0.2.0-rc.2')
        self.assertEqual(actions, ['update'])

    def test_old_version_managed_actions_and_htb_are_blocked(self):
        exchanges = []
        for key in ('1', '2', '3', '4', '5', '6', '9'):
            exchanges.append(('Select [0-9,a] [7]: ', key + '\n'))
        exchanges.extend([('Select [0-9,a] [7]: ', 'a\n'),
                          ('Select [0-1] [0]: ', '1\n'),
                          ('Select [0-1] [0]: ', '0\n'),
                          ('Select [0-9,a] [7]: ', '\n')])
        output, actions = self.menu(exchanges, version='0.2.0-rc.2')
        self.assertEqual(actions, ['diagnose'])
        self.assertEqual(output.count('该项当前不可用'), 8)

    def test_no_terminal_requires_explicit_action(self):
        result = subprocess.run(self.command('current', 'VERIFIED'), cwd=self.work,
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 2)
        self.assertIn('非交互环境必须明确指定 action', result.stderr.decode('utf-8'))
        self.assertNotIn(b'FIXTURE_ACTION:', result.stdout)


if __name__ == '__main__':
    unittest.main()
