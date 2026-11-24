#!/usr/bin/env python3
"""临时 HTB 事务：严格拓扑、完整 fq 恢复、独立看护；不安装持久策略。"""
from contextlib import contextmanager
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

SCHEMA = 'dvt.temporary-htb/1'
PHASES = {'PREPARED', 'MUTATING', 'ACTIVE', 'RESTORING', 'RESTORED', 'RECOVERY_REQUIRED'}
BURST = 262144
CBURST = 32768
QUANTUM = 15140


class HTBError(Exception):
    pass


def require(ok, message):
    if not ok:
        raise HTBError(message)


def execute(argv):
    p = subprocess.run(argv, capture_output=True, text=True, timeout=5)
    require(p.returncode == 0, '命令失败：' + ' '.join(argv) + ': ' + p.stderr.strip())
    return p.stdout


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, data):
    temp = path.with_name(path.name + '.tmp')
    with temp.open('w', encoding='utf-8') as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temp.replace(path)


def secure(path):
    path = Path(path)
    require(path.is_absolute() and path.exists() and not path.is_symlink(), '需要现有绝对非符号链接路径')
    for part in (path, *path.parents):
        stat = part.lstat()
        require(not part.is_symlink() and stat.st_uid == 0, '恢复路径必须由 root 控制')
        # /tmp 的 sticky 位保护 root 所有的私有子目录；其他可写祖先拒绝。
        require(stat.st_mode & 0o022 == 0 or (part != path and stat.st_mode & 0o1000),
                '恢复路径不能被 group/world 替换')


def owner_token(pid):
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        return None if fields[0] == 'Z' else fields[19]
    except (FileNotFoundError, ProcessLookupError):
        return None


def identity(iface):
    links = json.loads(execute(['ip', '-j', 'link', 'show', 'dev', iface]))
    require(len(links) == 1, '接口不存在')
    return {'ifindex': links[0]['ifindex'], 'netns': os.stat('/proc/self/ns/net').st_ino,
            'boot_id': Path('/proc/sys/kernel/random/boot_id').read_text().strip()}


def parse_classes(raw):
    """旧 iproute2 的 class 命令忽略 -j；保留完整文本以核对参数漂移。"""
    raw = raw.strip()
    if not raw or raw.startswith('['):
        rows = json.loads(raw or '[]')
        require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows), '未知 tc class 格式')
        return rows
    rows = []
    for line in raw.splitlines():
        match = re.match(r'^class htb ([0-9a-fA-F]+:[0-9a-fA-F]+) (?:root|parent\s+[0-9a-fA-F]+:)\s', line)
        require(match is not None, '无法核验旧版 tc class 文本')
        options = {}
        for key in ('rate', 'ceil'):
            rates = re.findall(r'\b' + key + r'\s+([0-9]+(?:\.[0-9]+)?)([KMGT]?bit)\b', line)
            require(len(rates) == 1, '旧版 tc class 缺少唯一 rate/ceil')
            value, unit = rates[0]
            number = Decimal(value) * {'bit': 1, 'Kbit': 10**3, 'Mbit': 10**6,
                                      'Gbit': 10**9, 'Tbit': 10**12}[unit] / 8
            require(number == int(number) and number > 0, '旧版 tc class rate 无法精确换算')
            options[key] = int(number)
        rows.append({'kind': 'htb', 'handle': match[1], 'options': options, 'raw_parameters': line})
    return rows


def snapshot(iface):
    # 一些 iproute2 版本在没有 class/filter 时成功返回空文本而不是 []。
    def objects(argv):
        rows = json.loads(execute(argv).strip() or '[]')
        require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows), '未知 tc 对象格式')
        return rows
    classes = parse_classes(execute(['tc', '-j', '-d', 'class', 'show', 'dev', iface]))
    filters = objects(['tc', '-j', 'filter', 'show', 'dev', iface, 'root'])
    for cls in classes:
        parent = cls.get('handle', cls.get('classid'))
        require(isinstance(parent, str), '无法核验 class filter')
        filters.extend(objects(['tc', '-j', 'filter', 'show', 'dev', iface, 'parent', parent]))
    return {'qdiscs': json.loads(execute(['tc', '-j', '-d', 'qdisc', 'show', 'dev', iface])),
            'classes': classes, 'filters': filters}


def fq_options(options):
    """iproute2 JSON: rate 为 bytes/s，普通时间为 us，timer_slack 为 ns。"""
    require(isinstance(options, dict), '缺少 fq options')
    normalized = {key.strip(): value for key, value in options.items()}
    require(len(normalized) == len(options), 'fq 选项规范化后重复')
    integers = {'limit', 'flow_limit', 'buckets', 'orphan_mask', 'quantum', 'initial_quantum'}
    rates = {'maxrate', 'defrate', 'low_rate_threshold'}
    times = {'refill_delay', 'ce_threshold', 'horizon', 'offload_horizon'}
    supported = integers | rates | times | {'timer_slack', 'pacing', 'horizon_drop', 'horizon_cap', 'bands', 'priomap', 'weights'}
    require(set(normalized) <= supported, 'fq 包含无法完整恢复的选项')
    require({'limit', 'flow_limit', 'quantum', 'initial_quantum'} <= set(normalized), 'fq 核心参数不可读')
    args = []
    for key in sorted(integers | rates | times | {'timer_slack'}):
        if key not in normalized:
            continue
        value = normalized[key]
        require(type(value) is int and 0 <= value <= 4294967295, 'fq 数值超出已支持范围')
        suffix = 'bit' if key in rates else 'us' if key in times else 'ns' if key == 'timer_slack' else ''
        args.extend([key, str(value * 8 if key in rates else value) + suffix])
    if 'pacing' in normalized:
        require(type(normalized['pacing']) is bool, '无效 pacing')
    args.append('pacing' if normalized.get('pacing', True) else 'nopacing')
    flags = set(normalized) & {'horizon_drop', 'horizon_cap'}
    require(len(flags) <= 1 and all(normalized[key] is None for key in flags), '无效 horizon 模式')
    args.extend(sorted(flags))
    if 'bands' in normalized or 'priomap' in normalized:
        mapping = normalized.get('priomap')
        require(normalized.get('bands') == 3 and isinstance(mapping, list) and len(mapping) == 16 and
                all(type(value) is int and 0 <= value < 3 for value in mapping), '无效 fq bands/priomap')
        args.extend(['bands', '3', 'priomap', *map(str, mapping)])
    if 'weights' in normalized:
        weights = normalized['weights']
        require(isinstance(weights, list) and len(weights) == 3 and
                all(type(value) is int and 0 < value <= 2147483647 for value in weights), '无效 fq weights')
        args.extend(['weights', *map(str, weights)])
    return normalized, args


def fq_restore_arg_variants(options):
    args = fq_options(options)[1]
    variants = [args]
    if 'weights' in args:
        compatibility = args.copy()
        # iproute2 6.15 q_fq.c 的 weights 分支多调用一次 NEXT_ARG。
        # 只有现场 parser 验证接受时才选择这个被跳过的 token。
        compatibility.insert(compatibility.index('weights') + 1, '0')
        variants.append(compatibility)
    return variants


def validated_fq_restore_args(options):
    def parse(args):
        # 不提供 dev，末尾 help 使 parser 退出；即使解析异常也无法修改接口。
        result = subprocess.run(['tc', 'qdisc', 'add', 'root', 'fq', *args, 'help'],
                                capture_output=True, text=True, timeout=5,
                                env={**os.environ, 'LC_ALL': 'C'})
        return result.returncode, result.stdout, result.stderr

    expected = parse([])
    require(expected[0] != 0 and 'Usage:' in expected[1] + expected[2] and
            re.search(r'\bfq\b', expected[1] + expected[2]), '无法验证 tc fq 恢复语法')
    for index, args in enumerate(fq_restore_arg_variants(options)):
        observed = parse(args)
        if observed == expected:
            return args
        error = observed[1] + observed[2]
        require(index == 0 and ('Illegal "weights" element' in error or
                               'Not enough elements in weights' in error),
                'tc 不接受完整 fq 恢复参数；未修改 qdisc：' + error.strip())
    raise HTBError('tc 不接受 fq weights 恢复语法；未修改 qdisc')


def preflight(iface):
    require(re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', iface), '无效接口名')
    ident = identity(iface)
    links = json.loads(execute(['ip', '-j', 'link', 'show', 'dev', iface]))
    require('UP' in links[0].get('flags', []), '开始实验需要 UP 接口')
    data = snapshot(iface)
    require(not data['classes'] and not data['filters'] and len(data['qdiscs']) == 1,
            '只支持无 class/filter 的单一根 fq；mq/clsact/ingress 保持不动')
    root = data['qdiscs'][0]
    require(root.get('root') is True and root.get('kind') == 'fq', '需要可完整恢复的单一根 fq')
    require(set(root) <= {'kind', 'handle', 'root', 'refcnt', 'options'}, '存在无法恢复的根 qdisc 元数据')
    require(re.fullmatch(r'[0-9a-fA-F]{1,4}:', root.get('handle', '')), '未知根 handle')
    fq_options(root.get('options'))
    return ident, data


def equivalent(original, current):
    if current['classes'] or current['filters'] or len(current['qdiscs']) != 1:
        return False
    a, b = original['qdiscs'][0], current['qdiscs'][0]
    return (b.get('root') is True and b.get('kind') == 'fq' and
            (int(a['handle'][:-1], 16) == 0 or a['handle'] == b.get('handle')) and
            fq_options(a['options'])[0] == fq_options(b.get('options'))[0])


def owned(state, current):
    """只接受本事务的完整或部分子树；额外对象/过滤器不能被恢复覆盖。"""
    if current['filters'] or not current['qdiscs']:
        return False
    root_handle, leaf_handle = state['root_handle'], state['leaf_handle']
    roots = [q for q in current['qdiscs'] if q.get('root')]
    if len(roots) != 1 or roots[0].get('kind') != 'htb' or roots[0].get('handle') != root_handle:
        return False
    for q in current['qdiscs']:
        if q in roots:
            continue
        explicit = q.get('kind') == 'fq' and q.get('handle') == leaf_handle
        # class 创建后、显式叶子创建前，内核会自动挂接 handle 0: 的默认叶子。
        automatic = (state.get('recovery_phase', state['phase']) == 'MUTATING' and q.get('handle') == '0:' and
                     q.get('kind') in ('fq', 'fq_codel', 'pfifo', 'pfifo_fast'))
        if not ((explicit or automatic) and q.get('parent') == root_handle + '1'):
            return False
    for c in current['classes']:
        if (c.get('kind', c.get('class')) != 'htb' or c.get('handle', c.get('classid')) != root_handle + '1'):
            return False
    return len(current['qdiscs']) <= 2 and len(current['classes']) <= 1


def normalized(data):
    return {key: [{k: v for k, v in row.items() if k != 'refcnt'} for row in rows]
            for key, rows in data.items()}


def clear_registry(state, checkpoint):
    ident = state['identity']
    pointer = Path('/run/dvt-temporary-htb') / f"{ident['netns']}-{ident['ifindex']}.json"
    if pointer.exists() and json.loads(pointer.read_text()).get('checkpoint') == str(checkpoint):
        pointer.unlink()


@contextmanager
def locked(checkpoint):
    import fcntl
    with (checkpoint / 'transaction.lock').open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def load(checkpoint):
    secure(checkpoint)
    for name in ('state.json', 'original.json', 'recovery.py'):
        secure(checkpoint / name)
    state = json.loads((checkpoint / 'state.json').read_text())
    require(state.get('schema') == SCHEMA and state.get('phase') in PHASES, '未知 HTB 状态')
    require(state['original_sha256'] == digest(checkpoint / 'original.json') and
            state['recovery_sha256'] == digest(checkpoint / 'recovery.py'), '恢复材料摘要不一致')
    require(identity(state['interface']) == state['identity'], '接口/命名空间/boot 身份变化')
    original = json.loads((checkpoint / 'original.json').read_text())
    variants = fq_restore_arg_variants(original['qdiscs'][0]['options'])
    require(state.get('restore_fq_argv', variants[0]) in variants, '保存的 fq 恢复参数与原快照不符')
    return state, original


def restore(checkpoint):
    with locked(checkpoint):
        state, original = load(checkpoint)
        recovery_phase = state.get('recovery_phase', state['phase'])
        try:
            current = snapshot(state['interface'])
            if not equivalent(original, current):
                require(owned(state, current), '当前 tc 对象已不属于本事务；拒绝覆盖，需人工恢复')
                if recovery_phase == 'ACTIVE':
                    require(normalized(current) == state['active_snapshot'], '活动 tc 参数被外部修改；拒绝覆盖')
                state['recovery_phase'] = recovery_phase
                state['phase'] = 'RESTORING'
                save(checkpoint / 'state.json', state)
                root = original['qdiscs'][0]
                args = ['tc', 'qdisc', 'replace', 'dev', state['interface'], 'root']
                if int(root['handle'][:-1], 16):
                    args += ['handle', root['handle']]
                execute(args + ['fq', *state.get('restore_fq_argv', fq_options(root['options'])[1])])
                require(equivalent(original, snapshot(state['interface'])), 'fq 恢复后语义复核失败')
            state['phase'] = 'RESTORED'
            save(checkpoint / 'state.json', state)
            clear_registry(state, checkpoint)
        except BaseException:
            state['recovery_phase'] = recovery_phase
            state['phase'] = 'RECOVERY_REQUIRED'
            save(checkpoint / 'state.json', state)
            raise


class Transaction:
    def __init__(self, iface, checkpoint, lifetime):
        self.iface, self.checkpoint = iface, Path(checkpoint)
        self.lifetime = lifetime
        self.guard = None
        self.watchdog = None

    def begin(self):
        import fcntl
        require(os.geteuid() == 0, '临时 HTB 需要 root')
        require(isinstance(self.lifetime, (int, float)) and 0 < self.lifetime <= 1830, '无效恢复期限')
        secure(self.checkpoint.parent)
        secure(Path(__file__).resolve())
        require(not self.checkpoint.exists(), 'checkpoint 必须是新目录')
        ident, original = preflight(self.iface)
        restore_fq_argv = validated_fq_restore_args(original['qdiscs'][0]['options'])
        require(not Path('/run/htb-aggregate-experiment/active.json').exists(), '旧 HTB 实验尚未关闭')
        lock_dir = Path('/run/dvt-temporary-htb')
        lock_dir.mkdir(mode=0o700, exist_ok=True)
        secure(lock_dir)
        key = f"{ident['netns']}-{ident['ifindex']}"
        lock_path = lock_dir / (key + '.lock')
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        self.guard = os.fdopen(fd, 'a+')
        created = False
        try:
            fcntl.flock(self.guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
            pointer = lock_dir / (key + '.json')
            if pointer.exists():
                old = Path(json.loads(pointer.read_text())['checkpoint'])
                old_state, _ = load(old)
                require(old_state['phase'] == 'RESTORED', '前一个 HTB checkpoint 尚未恢复')
            # 取得接口锁后重读，拒绝与最初观察不同的拓扑。
            require(preflight(self.iface) == (ident, original), '准备期间 tc 拓扑变化')
            self.checkpoint.mkdir(mode=0o700)
            created = True
            save(self.checkpoint / 'original.json', original)
            source = Path(__file__).read_bytes()
            (self.checkpoint / 'recovery.py').write_bytes(source)
            (self.checkpoint / 'recovery.py').chmod(0o600)
            nonce = uuid.uuid4().int
            # 保持与共享计数器的十进制字符 parent 分类兼容；tc 自身仍按十六进制解释。
            root_major = 1000 + nonce % 4000
            if f'{root_major}:' == original['qdiscs'][0]['handle']:
                root_major = 1000 + (root_major - 999) % 4000
            state = {'schema': SCHEMA, 'phase': 'PREPARED', 'interface': self.iface, 'identity': ident,
                     'root_handle': f'{root_major}:',
                     'leaf_handle': f'{6000 + nonce % 3000}:', 'rate_mbps': None,
                     'restore_fq_argv': restore_fq_argv,
                     'original_sha256': digest(self.checkpoint / 'original.json'),
                     'recovery_sha256': digest(self.checkpoint / 'recovery.py'),
                     'owner_pid': os.getpid(), 'owner_token': owner_token(os.getpid()),
                     'deadline_monotonic': time.monotonic() + self.lifetime}
            save(self.checkpoint / 'state.json', state)
            save(pointer, {'checkpoint': str(self.checkpoint)})
            with (self.checkpoint / 'watchdog.log').open('w') as log:
                self.watchdog = subprocess.Popen([sys.executable, str(self.checkpoint / 'recovery.py'),
                                                  '_watch', str(self.checkpoint)], stdout=log,
                                                 stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 5
            while not (self.checkpoint / 'READY').exists():
                require(self.watchdog.poll() is None and time.monotonic() < deadline, '独立恢复进程未就绪')
                time.sleep(0.05)
        except BaseException:
            try:
                if created and (self.checkpoint / 'state.json').exists():
                    restore(self.checkpoint)
            finally:
                self.release()
            raise

    def set_rate(self, rate):
        require(type(rate) is int and 1 <= rate <= 10000, 'HTB 速率必须为 1..10000 Mbps')
        with locked(self.checkpoint):
            state, original = load(self.checkpoint)
            require(state['phase'] in ('PREPARED', 'ACTIVE') and time.monotonic() < state['deadline_monotonic'],
                    'HTB 事务不再允许采样')
            require(self.watchdog is not None and self.watchdog.poll() is None, '恢复进程已退出')
            current = snapshot(self.iface)
            if state['phase'] == 'PREPARED':
                require(equivalent(original, current), '原 tc 拓扑已变化')
            else:
                require(owned(state, current), '活动 tc 所有权变化')
                require(normalized(current) == state['active_snapshot'], '活动 tc 参数发生外部变化')
            first = state['phase'] == 'PREPARED'
            state.update(phase='MUTATING', rate_mbps=rate)
            save(self.checkpoint / 'state.json', state)
            root = state['root_handle']
            if first:
                execute(['tc', 'qdisc', 'replace', 'dev', self.iface, 'root', 'handle', root, 'htb', 'default', '1'])
            execute(['tc', 'class', 'replace', 'dev', self.iface, 'parent', root, 'classid', root + '1', 'htb',
                     'rate', f'{rate}mbit', 'ceil', f'{rate}mbit', 'burst', f'{BURST}b', 'cburst', f'{CBURST}b',
                     'quantum', str(QUANTUM)])
            if first:
                execute(['tc', 'qdisc', 'replace', 'dev', self.iface, 'parent', root + '1',
                         'handle', state['leaf_handle'], 'fq'])
            state['phase'] = 'ACTIVE'
            state['active_snapshot'] = normalized(snapshot(self.iface))
            save(self.checkpoint / 'state.json', state)
        self.assert_active(rate)

    def assert_active(self, rate):
        with locked(self.checkpoint):
            state, _ = load(self.checkpoint)
            data = snapshot(self.iface)
            require(state['phase'] == 'ACTIVE' and state['rate_mbps'] == rate and
                    time.monotonic() < state['deadline_monotonic'] and self.watchdog.poll() is None,
                    'HTB 状态或恢复看护失效')
            require(owned(state, data) and len(data['qdiscs']) == 2 and len(data['classes']) == 1,
                    'HTB 拓扑不完整或有外部对象')
            require(normalized(data) == state['active_snapshot'], '活动 HTB 参数漂移')
            cls = data['classes'][0]
            options = cls.get('options', cls)
            require(options.get('rate') == options.get('ceil') == rate * 125000, 'HTB rate/ceil 不匹配')
            root = next(q for q in data['qdiscs'] if q.get('root'))
            require(root.get('options', {}).get('default') in (1, '1', '0x1'), 'HTB 默认 class 不匹配')
            return data

    def release(self):
        if self.guard is not None:
            self.guard.close()
            self.guard = None

    def close(self):
        try:
            restore(self.checkpoint)
            if self.watchdog:
                self.watchdog.wait(timeout=5)
        finally:
            self.release()


def watch(checkpoint):
    state, _ = load(checkpoint)
    (checkpoint / 'READY').write_text('independent recovery ready\n')
    while True:
        state, _ = load(checkpoint)
        if state['phase'] in ('RESTORED', 'RECOVERY_REQUIRED'):
            return
        alive = owner_token(state['owner_pid']) == state['owner_token']
        if not alive or time.monotonic() >= state['deadline_monotonic']:
            if alive:
                try:
                    os.kill(state['owner_pid'], signal.SIGTERM)
                except ProcessLookupError:
                    restore(checkpoint)
                    return
                # 先让采集器回收其隔离进程组；仍未恢复则由本进程接手。
                grace = time.monotonic() + 8
                while time.monotonic() < grace:
                    current, _ = load(checkpoint)
                    if current['phase'] in ('RESTORED', 'RECOVERY_REQUIRED'):
                        return
                    time.sleep(.2)
                if owner_token(state['owner_pid']) == state['owner_token']:
                    try:
                        os.kill(state['owner_pid'], signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            restore(checkpoint)
            return
        time.sleep(0.2)


if __name__ == '__main__':
    try:
        require(os.geteuid() == 0 and len(sys.argv) == 3 and sys.argv[1] in ('_watch', 'recover'),
                'usage: python3 dvt_htb_transaction.py recover /absolute/checkpoint')
        checkpoint = Path(sys.argv[2])
        if sys.argv[1] == '_watch':
            watch(checkpoint)
        else:
            state, _ = load(checkpoint)
            require(owner_token(state['owner_pid']) != state['owner_token'] or state['phase'] == 'RESTORED',
                    '拥有该事务的进程仍在运行；先停止原测量')
            restore(checkpoint)
    except (HTBError, OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print('[temporary-htb][FAIL] ' + str(exc), file=sys.stderr)
        sys.exit(2)
