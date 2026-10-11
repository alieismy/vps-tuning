#!/usr/bin/env python3
"""为已确认的旧 TCP 快照截断建立可撤销、带来源的恢复状态；不执行迁移。"""

import argparse
import contextlib
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

VERSION = '0.2.0-rc.2'
STATE = '/var/lib/proxy-vps-tuning/state.json'
LOCK = '/run/lock/proxy-vps-tuning.lock'
TCP = ('net.ipv4.tcp_rmem', 'net.ipv4.tcp_wmem')
KEYS = (
    'net.core.default_qdisc', 'net.ipv4.tcp_congestion_control',
    'net.core.rmem_max', 'net.core.wmem_max', 'net.core.rmem_default',
    'net.core.wmem_default', *TCP, 'net.core.netdev_max_backlog',
    'net.core.somaxconn', 'net.ipv4.tcp_max_syn_backlog', 'net.ipv4.tcp_fastopen',
    'net.ipv4.tcp_mtu_probing', 'net.ipv4.tcp_keepalive_time',
    'net.ipv4.tcp_keepalive_intvl', 'net.ipv4.tcp_keepalive_probes', 'vm.swappiness',
)
MANAGED = (
    '/etc/sysctl.d/90-proxy-vps.conf',
    '/etc/systemd/journald.conf.d/90-proxy-vps.conf',
    '/usr/local/sbin/proxy-vps-fq', '/etc/systemd/system/proxy-vps-fq.service',
    '/etc/systemd/system/x-ui.service.d/90-proxy-vps.conf',
)
BACKUPS = (
    '/var/lib/proxy-vps-tuning/qdisc-original.json',
    '/var/lib/proxy-vps-tuning/provider-sysctl.conf.original',
    '/etc/sysctl.conf', '/etc/fstab',
)
OWNER_UID = 0


class Refused(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Refused(message)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def encode(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def decode(raw):
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, 'JSON 含重复字段。')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def vector(value):
    require(isinstance(value, str) and re.fullmatch(r'[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+', value),
            'TCP 值必须为三个非负十进制整数。')
    values = [int(n) for n in value.split()]
    require(0 < values[0] <= values[1] <= values[2] <= 2147483647, 'TCP 三元组范围或顺序无效。')
    return ' '.join(map(str, values))


def secure(path, directory=False):
    """拒绝软链接、非 root 所有及可被其他用户修改的输入/父目录。"""
    path = Path(path)
    require(path.is_absolute() and '..' not in path.parts, '路径必须为无 .. 的绝对路径。')
    for item in (path, *path.parents):
        info = item.lstat()
        require(not stat.S_ISLNK(info.st_mode), '拒绝符号链接路径。')
        require(info.st_uid == OWNER_UID or (item != path and info.st_uid == 0), '路径必须由 root 所有。')
        sticky_parent = item != path and stat.S_ISDIR(info.st_mode) and info.st_mode & stat.S_ISVTX
        require(not info.st_mode & 0o022 or sticky_parent, '路径不能由 group/world 写入。')
    info = path.stat()
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode), '文件类型不符。')
    return path


def read_secure(path):
    return secure(path).read_bytes()


def sync_dir(path):
    if os.name == 'posix':
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def atomic_state(path, raw):
    # 临时文件和替换发生在同一目录；中断后磁盘上只能是旧文件或完整新文件。
    secure(path)
    fd, name = tempfile.mkstemp(prefix='.tcp-baseline-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            if hasattr(os, 'fchmod'):
                os.fchmod(stream.fileno(), 0o600)
            else:
                os.chmod(name, 0o600)
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        sync_dir(path.parent)
        require(path.read_bytes() == raw, 'state 原子替换后的读回不一致；保留归档。')
    finally:
        if os.path.exists(name):
            os.unlink(name)


def write_new(path, raw):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


class Host:
    """生产入口固定 root=/；测试使用隔离文件树，不修改宿主配置。"""

    def __init__(self, root=Path('/')):
        self.root = Path(root)

    def path(self, absolute):
        return self.root / absolute.lstrip('/')

    @contextlib.contextmanager
    def locked(self):
        import fcntl
        path = secure(self.path(LOCK))
        # 不创建锁文件、不截断、不改写 DVT 锁元数据。
        with path.open('rb') as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise Refused('DVT 锁正被使用；未修改状态。') from exc
            yield

    def observe(self):
        raw = read_secure(self.path(STATE))
        if os.name == 'posix':
            require(stat.S_IMODE(self.path(STATE).stat().st_mode) == 0o600, 'state 必须为 0600。')
        state = decode(raw)
        require(isinstance(state, dict), 'state 必须为单份 JSON 对象。')
        machine = self.path('/etc/machine-id').read_text().strip()
        require(re.fullmatch(r'[a-f0-9]{32}', machine), 'machine-id 无效。')
        os_release = self.path('/etc/os-release').read_text()
        require(re.search(r'^ID="?debian"?$', os_release, re.M) and
                re.search(r'^VERSION_ID="?13"?$', os_release, re.M), '仅支持 Debian 13。')
        files = {}
        for name in (*MANAGED, *BACKUPS):
            path = self.path(name)
            if path.exists() or path.is_symlink():
                data = read_secure(path)
                info = path.stat()
                files[name] = {'sha256': sha(data), 'mode': stat.S_IMODE(info.st_mode),
                               'uid': info.st_uid, 'gid': info.st_gid}
            else:
                files[name] = None
        current = {key: ' '.join(self.path('/proc/sys/' + key.replace('.', '/')).read_text().split())
                   for key in KEYS}
        for key in TCP:
            vector(current[key])
        qdisc = self.qdiscs()
        swaps = [line.split() for line in self.path('/proc/swaps').read_text().splitlines()[1:]]
        require(all(len(row) == 5 for row in swaps), 'swap 清单格式无效。')
        guard = {'files': files, 'sysctls': current, 'qdisc': qdisc,
                 'boot_id': self.path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                 'swaps': sorted([row[:3] + row[4:] for row in swaps])}
        binding = {'machine_id_sha256': sha(machine.encode()), 'state_sha256': sha(raw),
                   'script_version': state.get('script_version'), 'schema_version': state.get('schema_version'),
                   'profile_id': state.get('profile', {}).get('id'),
                   'port_speed_mbps': state.get('network', {}).get('port_speed_mbps'),
                   'timestamps': state.get('timestamps')}
        return raw, state, binding, guard

    def qdiscs(self):
        result = subprocess.run(['/usr/sbin/tc', '-j', 'qdisc', 'show'],
                                capture_output=True, timeout=15, check=True)
        return decode(result.stdout)

    def verify_source(self, profile):
        env = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
               'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8'}
        result = subprocess.run(['/bin/bash', str(profile), 'verify'], env=env,
                                capture_output=True, timeout=120, check=False)
        # 不回显可能含业务信息的来源输出；操作员可独立运行固定来源 verify。
        require(result.returncode == 0, '固定来源 profile verify 未通过。')


def validate_plan(plan, state, binding, guard):
    require(plan.get('schema_version') == 1 and plan.get('approved') is True, '计划未明确批准。')
    require(re.fullmatch(r'VPS-[0-9]{2}', plan.get('host_id', '')), '必须明确 VPS-两位数字编号。')
    require(plan.get('target_version') == VERSION, '目标必须为当前候选版本。')
    require(plan.get('binding') == binding, '主机、状态摘要、部署时间、档位或带宽与计划不一致。')
    require(plan.get('guard_sha256') == sha(encode(guard)), '运行配置与已审阅计划不一致。')
    require(binding['script_version'] in ('0.1.0-rc.11', '0.1.0-rc.12', '0.1.0-rc.16', '0.1.0-rc.17'),
            '不在本次已验证的来源版本集合内。')
    expected_schema = 3 if binding['script_version'] == '0.1.0-rc.11' else 4
    require(binding['schema_version'] == expected_schema and state.get('state') == 'VERIFIED',
            '来源必须为对应 schema 的 VERIFIED 状态。')
    require(binding['profile_id'] in ('debian13-1c1g', 'debian13-1c2g') and
            type(binding['port_speed_mbps']) is int and binding['port_speed_mbps'] in (100, 200, 500),
            '档位或带宽不在本次恢复范围内。')
    require(isinstance(binding['timestamps'], dict) and
            all(isinstance(binding['timestamps'].get(k), str) and binding['timestamps'][k]
                for k in ('prepared', 'last_update')), '缺少部署时间。')
    require('tcp_baseline_recovery' not in state and state.get('reconfigure') is None,
            '存在恢复记录或未完成事务；不能叠加恢复。')
    originals = state.get('original_sysctls', {})
    require(set(originals) == set(KEYS) and all(isinstance(v, str) and v for v in originals.values()),
            '其他原始 sysctl 快照缺失。')
    require(all(originals.get(key) == '4096' for key in TCP), '只处理两项原值均为 4096 的已知截断缺陷。')
    managed = state.get('managed_files', [])
    require(isinstance(managed, list) and len(managed) == len(MANAGED) and
            {item['path'] for item in managed} == set(MANAGED), '受管文件集合不符。')
    for item in managed:
        require(guard['files'][item['path']] and
                guard['files'][item['path']]['sha256'] == item['sha256'], '受管文件摘要漂移。')
    require(set(plan.get('vectors', {})) == set(TCP), '恢复计划必须且只能包含两项 TCP 三元组。')
    values = {key: vector(plan['vectors'][key]) for key in TCP}
    require(values == plan['vectors'], '计划三元组须使用无前导零、单空格分隔的十进制格式。')
    mode = plan.get('mode')
    require(mode in ('historical', 'replacement'), '必须选择 historical 或 replacement。')
    evidence = plan.get('evidence', {})
    if mode == 'historical':
        require(evidence.get('kind') == 'same-host-same-deployment' and
                evidence.get('host_deployment_confirmed') is True and
                evidence.get('timestamps') == binding['timestamps'], '历史证据未完成同主机、同部署关联确认。')
    else:
        require(plan.get('accept_new_baseline') is True, '未明确接受新的恢复基线。')
        require(evidence.get('kind') in ('reference', 'current-verified-runtime'), '替代值来源不明。')
    if evidence.get('kind') == 'current-verified-runtime':
        require(values == {key: vector(guard['sysctls'][key]) for key in TCP}, '替代值与当前运行值不符。')
        return values, None
    data = read_secure(Path(evidence['path']))
    require(sha(data) == evidence.get('sha256'), '证据文件摘要不符。')
    parsed = {}
    for line in data.decode('utf-8-sig').splitlines():
        match = re.fullmatch(r'\s*(net\.ipv4\.tcp_[rw]mem)\s*(?:=|\t)\s*([0-9]+[ \t]+[0-9]+[ \t]+[0-9]+)\s*', line)
        if match:
            require(match[1] not in parsed, '证据含重复 TCP 条目。')
            parsed[match[1]] = vector(match[2])
    require(parsed == values, '证据文件中的两项 TCP 值与计划不一致。')
    return values, data


def validate_source(plan):
    spec = plan['source_profile']
    profile = secure(Path(spec['path']))
    data = profile.read_bytes()
    require(sha(data) == spec.get('sha256'), '来源 profile 摘要不符。')
    text = data.decode('utf-8')
    for name, value in (('SCRIPT_VERSION', plan['binding']['script_version']),
                        ('PROFILE_ID', plan['binding']['profile_id'])):
        require(f"{name}='{value}'" in text.splitlines(), '来源 profile 版本或档位不符。')
    return profile, data


def prepare(host, plan_path, archive):
    plan_raw = read_secure(plan_path)
    plan = decode(plan_raw)
    before = host.observe()
    values, evidence = validate_plan(plan, before[1], before[2], before[3])
    profile, profile_raw = validate_source(plan)
    # verify 自行持 DVT 锁；随后再取锁并核对前后快照，避免重入死锁。
    host.verify_source(profile)
    with host.locked():
        current = host.observe()
        require(current == before, '来源 verify 期间状态或运行配置变化。')
        require(profile.read_bytes() == profile_raw, '来源 profile 在 verify 期间变化。')
        archive = Path(archive)
        secure(archive.parent, directory=True)
        require(archive.is_absolute() and '..' not in archive.parts and
                not archive.exists() and not archive.is_symlink(), '归档必须为新的绝对目录。')
        require(not archive.is_relative_to(host.path('/var/lib/proxy-vps-tuning')),
                '恢复归档不能放在旧版 rollback 会删除的状态目录内。')
        raw, state, binding, guard = current
        candidate = copy.deepcopy(state)
        candidate['original_sysctls'].update(values)
        candidate['tcp_baseline_recovery'] = {
            'schema_version': 1, 'host_id': plan['host_id'], 'mode': plan['mode'],
            'archive': str(archive), 'original_state_sha256': sha(raw),
            'plan_sha256': sha(plan_raw), 'target_version': VERSION,
            'historical_originals_recovered': plan['mode'] == 'historical',
        }
        payload = {'state.before.json': raw, 'state.proposed.json': encode(candidate),
                   'plan.json': plan_raw, 'guard.json': encode(guard), 'source-profile.sh': profile_raw}
        if evidence is not None:
            payload['evidence.txt'] = evidence
        for index, (name, info) in enumerate(guard['files'].items()):
            if info is not None:
                payload[f'file-{index:02d}.backup'] = read_secure(host.path(name))
                require(sha(payload[f'file-{index:02d}.backup']) == info['sha256'], '备份采集期间文件漂移。')
        receipt = {'schema_version': 1, 'tool_version': VERSION, 'host_id': plan['host_id'],
                   'mode': plan['mode'], 'binding': binding,
                   'created_utc': datetime.now(timezone.utc).isoformat(),
                   'files': {name: sha(data) for name, data in payload.items()},
                   'scope': 'state-only; not a complete machine or business backup'}
        archive.mkdir(mode=0o700)
        # receipt 最后落盘；部分写入留下的目录不能被 activate 当作完整归档。
        for name, data in payload.items():
            write_new(archive / name, data)
        write_new(archive / 'receipt.json', encode(receipt))
        sync_dir(archive)
        sync_dir(archive.parent)
        require(host.observe() == before, '准备期间主机状态变化；归档不可激活。')
    return {'host_id': plan['host_id'], 'phase': 'PREPARED', 'plan_sha256': sha(plan_raw),
            'state_changed': False, 'archive': str(archive)}


def load_archive(archive, expected_plan):
    archive = secure(archive, directory=True)
    if os.name == 'posix':
        require(stat.S_IMODE(archive.stat().st_mode) == 0o700, '恢复归档必须为 0700。')
    receipt = decode(read_secure(archive / 'receipt.json'))
    require(receipt.get('schema_version') == 1 and receipt.get('tool_version') == VERSION, '归档契约不符。')
    entries = receipt.get('files', {})
    require(isinstance(entries, dict) and
            {'plan.json', 'state.before.json', 'state.proposed.json', 'guard.json', 'source-profile.sh'} <= entries.keys(),
            '归档缺少必要文件。')
    payload = {}
    for name, digest in entries.items():
        require(name in ('plan.json', 'state.before.json', 'state.proposed.json', 'guard.json',
                         'source-profile.sh', 'evidence.txt') or re.fullmatch(r'file-[0-9]{2}\.backup', name),
                '归档包含未知文件名。')
        payload[name] = read_secure(archive / name)
        require(sha(payload[name]) == digest, '归档文件摘要漂移。')
    require(re.fullmatch(r'[a-f0-9]{64}', expected_plan or '') and
            sha(payload['plan.json']) == expected_plan, '计划摘要与明确选择的计划不符。')
    plan = decode(payload['plan.json'])
    original = decode(payload['state.before.json'])
    candidate = decode(payload['state.proposed.json'])
    metadata = candidate.pop('tcp_baseline_recovery')
    require({key: candidate['original_sysctls'][key] for key in TCP} ==
            {key: vector(plan['vectors'][key]) for key in TCP}, '候选 TCP 值与计划不符。')
    require(metadata == {'schema_version': 1, 'host_id': plan['host_id'], 'mode': plan['mode'],
                         'archive': str(archive), 'original_state_sha256': sha(payload['state.before.json']),
                         'plan_sha256': expected_plan, 'target_version': VERSION,
                         'historical_originals_recovered': plan['mode'] == 'historical'}, '恢复来源记录不符。')
    candidate['original_sysctls'].update({key: original['original_sysctls'][key] for key in TCP})
    require(candidate == original, '候选状态改动超过两项 TCP 与来源记录。')
    require(receipt['host_id'] == plan['host_id'] and receipt['mode'] == plan['mode'] and
            receipt['binding'] == plan['binding'], '归档绑定不一致。')
    return receipt, payload, plan


def transition(host, archive, expected_plan, action):
    receipt, payload, plan = load_archive(archive, expected_plan)
    with host.locked():
        raw, state, binding, guard = host.observe()
        require(binding['machine_id_sha256'] == receipt['binding']['machine_id_sha256'], '归档属于另一台主机。')
        require(guard == decode(payload['guard.json']), '运行配置、文件、swap 或 boot ID 已变化；停止自动恢复。')
        before, after = payload['state.before.json'], payload['state.proposed.json']
        require(raw in (before, after), 'state 已变化；不能覆盖或撤销后续迁移。')
        # 验证候选内容和批准记录；证据来自固定归档，不依赖可变的外部路径。
        checked_plan = copy.deepcopy(plan)
        if checked_plan['evidence']['kind'] != 'current-verified-runtime':
            checked_plan['evidence']['path'] = str(Path(archive) / 'evidence.txt')
        validate_plan(checked_plan, decode(before), receipt['binding'], guard)
        if action == 'status':
            return {'host_id': plan['host_id'], 'phase': 'ACTIVATED' if raw == after else 'PREPARED',
                    'mode': plan['mode'], 'system_configuration_changed': False}
        target = after if action == 'activate' else before
        if raw != target:
            atomic_state(host.path(STATE), target)
        return {'host_id': plan['host_id'], 'phase': 'ACTIVATED' if action == 'activate' else 'UNDONE',
                'mode': plan['mode'], 'only_state_metadata_changed': True,
                'migration_executed': False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    inspect = sub.add_parser('inspect', help='只读输出逐台计划绑定材料；不推断批准或证据来源')
    inspect.add_argument('--host-id', required=True)
    create = sub.add_parser('prepare', help='核验已批准计划与来源 verify，建立私有归档；不改 state')
    create.add_argument('--plan', type=Path, required=True)
    create.add_argument('--archive', type=Path, required=True)
    for name in ('activate', 'undo', 'status'):
        command = sub.add_parser(name)
        command.add_argument('--archive', type=Path, required=True)
        command.add_argument('--expect-plan-sha256', required=True)
    args = parser.parse_args(argv)
    try:
        require(sys.platform.startswith('linux') and os.geteuid() == 0, '生产入口要求 Linux root。')
        host = Host()
        if args.action == 'inspect':
            require(re.fullmatch(r'VPS-[0-9]{2}', args.host_id), '编号格式必须为 VPS-两位数字。')
            with host.locked():
                raw, state, binding, guard = host.observe()
            result = {'host_id': args.host_id, 'binding': binding, 'guard_sha256': sha(encode(guard)),
                      'current_tcp': {key: guard['sysctls'][key] for key in TCP},
                      'original_tcp': {key: state['original_sysctls'].get(key) for key in TCP},
                      'target_version': VERSION, 'approved': False}
        elif args.action == 'prepare':
            result = prepare(host, args.plan, args.archive)
        else:
            result = transition(host, args.archive, args.expect_plan_sha256, args.action)
        print(encode(result).decode(), end='')
        return 0
    except (Refused, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        print(f'[tcp-baseline][REFUSED] {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
