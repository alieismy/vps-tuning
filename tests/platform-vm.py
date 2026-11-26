#!/usr/bin/env python3
"""在 CI runner 内创建隔离 QEMU 客体，验证原生平台与两次真实重启。"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=['debian12', 'debian13', 'ubuntu2404', 'ubuntu2604'], required=True)
    parser.add_argument('--arch', choices=['amd64', 'arm64'], required=True)
    parser.add_argument('--resource-profile', choices=['adaptive', 'legacy'], default='adaptive')
    parser.add_argument('--migration-source', choices=['0.2.0-rc.4', '0.2.0-rc.5'])
    args = parser.parse_args()
    if args.migration_source:
        if args.platform not in ('debian12', 'debian13') or args.arch != 'amd64':
            parser.error('migration fixture requires Debian amd64')
        if args.resource_profile == 'adaptive' and (args.platform != 'debian13' or args.migration_source != '0.2.0-rc.4'):
            parser.error('adaptive no-swap migration fixture requires Debian 13 rc.4')
    work = ROOT / '.tmp/platform-vm'
    work.mkdir(parents=True, exist_ok=False)
    evidence = work / 'evidence'
    evidence.mkdir()
    os.chmod(work, 0o700)
    spec = json.loads((ROOT / 'tests/platform-images.json').read_text())[args.platform][args.arch]
    (evidence / 'image.json').write_text(json.dumps(spec, indent=2))
    image = work / 'base.qcow2'
    urllib.request.urlretrieve(spec['url'], image)
    with image.open('rb') as f:
        digest = hashlib.file_digest(f, spec['algorithm']).hexdigest()
    assert digest == spec['digest'], 'official image checksum mismatch'
    run(['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(image), str(work / 'disk.qcow2'), '12G'])
    for name in ('client', 'host'):
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(work / name)])
    user_data = {
        'disable_root': False, 'ssh_pwauth': False,
        'users': [{'name': 'root', 'lock_passwd': True,
                   'ssh_authorized_keys': [(work / 'client.pub').read_text().strip()]}],
        'ssh_keys': {'ed25519_private': (work / 'host').read_text(),
                     'ed25519_public': (work / 'host.pub').read_text().strip()},
        'package_update': True,
        'packages': ['jq', 'iproute2', 'procps', 'kmod', 'util-linux', 'python3', 'curl'],
        'runcmd': [['touch', '/root/dvt-cloud-ready']],
    }
    if args.platform == 'ubuntu2604':
        # 固定26.04镜像manifest已含全部依赖；验证镜像原生工具，不借用24.04包。
        user_data.update(package_update=False, package_upgrade=False, packages=[])
        user_data['runcmd'] = [['bash', '-ec', 'for tool in jq ip tc sysctl modprobe swapon python3 curl; do command -v "$tool"; done\ntouch /root/dvt-cloud-ready']]
    if args.platform == 'ubuntu2404' and args.arch == 'arm64':
        # Ubuntu 的 universe/翻译/DEP-11 索引在 TCG 下使准备阶段超过 25 分钟。
        # runner 与客体同为 Ubuntu 24.04 ARM64；仅提前取得 jq 的三个官方 deb，
        # 不替换客体内核、用户态或项目生命周期行为。
        runner_os = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
        assert runner_os.get('ID', '').strip('"') == 'ubuntu'
        assert runner_os.get('VERSION_ID', '').strip('"') == '24.04'
        dependencies = work / 'guest-dependencies'
        dependencies.mkdir()
        try:
            run(['apt-get', 'download', 'jq:arm64', 'libjq1:arm64', 'libonig5:arm64'],
                cwd=dependencies, timeout=120)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError('Ubuntu ARM guest dependency download exceeded 120 seconds') from error
        packages = sorted(dependencies.glob('*.deb'))
        assert len(packages) == 3, 'unexpected Ubuntu jq dependency set'
        records = []
        user_data.update(package_update=False, package_upgrade=False, packages=[], write_files=[])
        for package in packages:
            arch = subprocess.check_output(['dpkg-deb', '-f', str(package), 'Architecture'], text=True).strip()
            assert arch == 'arm64', 'guest dependency architecture mismatch'
            content = package.read_bytes()
            records.append({'file': package.name, 'arch': arch, 'sha256': hashlib.sha256(content).hexdigest()})
            user_data['write_files'].append({'path': '/root/dvt-dependencies/' + package.name,
                                             'permissions': '0600', 'encoding': 'b64',
                                             'content': base64.b64encode(content).decode('ascii')})
        (evidence / 'guest-dependencies.json').write_text(json.dumps(records, indent=2))
        user_data['runcmd'] = [['bash', '-ec', '''dpkg -i /root/dvt-dependencies/*.deb
for tool in jq ip tc sysctl modprobe swapon python3 curl; do command -v "$tool"; done
touch /root/dvt-cloud-ready''']]
    (work / 'user-data').write_text('#cloud-config\n' + json.dumps(user_data))
    (work / 'meta-data').write_text('instance-id: dvt-lifecycle\nlocal-hostname: dvt-ci\n')
    run(['cloud-localds', str(work / 'seed.img'), str(work / 'user-data'), str(work / 'meta-data')])
    (work / 'known-hosts').write_text('[127.0.0.1]:2222 ' + (work / 'host.pub').read_text())
    ssh = ['ssh', '-i', str(work / 'client'), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
           '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + str(work / 'known-hosts'),
           '-o', 'ConnectTimeout=5', '-p', '2222', 'root@127.0.0.1']
    qemu = ['qemu-system-' + ('x86_64' if args.arch == 'amd64' else 'aarch64')]
    kvm = os.access('/dev/kvm', os.R_OK | os.W_OK)
    cpu = 'host' if kvm else ('max' if args.arch == 'arm64' else 'qemu64')
    if not kvm and args.platform in ('ubuntu2404', 'ubuntu2604') and args.arch == 'arm64':
        # Ubuntu 的 PAC 指令在 TCG 默认 QARMA5 下使启动与生命周期超时。
        # 只在隔离功能客体使用 QEMU 的快速实现，保留 PAuth 能力和所有断言；
        # 不据此证明硬件性能或指针认证的密码强度。
        # https://github.com/qemu/qemu/blob/v8.2.2/docs/system/arm/cpu-features.rst
        cpu = 'max,pauth-impdef=on'
    qemu += ['-accel', 'kvm' if kvm else 'tcg', '-cpu', cpu]
    if args.arch == 'arm64':
        qemu += ['-machine', 'virt', '-bios', '/usr/share/qemu-efi-aarch64/QEMU_EFI.fd']
    # KVM 覆盖 4C4G；TCG 的 ARM 客体用 2C1.5G 降低软件模拟内存初始化开销。
    # 两者都超出旧组合表；更大 RAM 的封顶另有架构无关的边界回归。
    vcpus, ram_mib = (4, 4096) if kvm else (2, 1536)
    if args.resource_profile == 'legacy':
        vcpus, ram_mib = 1, 1024
    elif args.migration_source:
        # 对应首台只读样本的 2C/约 1G adaptive + 无 swap；不模拟云厂商硬件。
        vcpus, ram_mib = 2, 1024
    qemu += ['-smp', str(vcpus), '-m', str(ram_mib), '-nographic',
             '-drive', f'file={work / "disk.qcow2"},if=virtio,format=qcow2',
             '-drive', f'file={work / "seed.img"},if=virtio,format=raw',
             '-nic', 'user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22']
    (evidence / 'hypervisor.json').write_text(json.dumps({'arch': args.arch, 'acceleration': 'kvm' if kvm else 'tcg',
                                                       'vcpus': vcpus, 'ram_mib': ram_mib,
                                                       'resource_profile': args.resource_profile, 'cpu': cpu}))
    serial = (evidence / 'serial.log').open('wb')
    vm = subprocess.Popen(qemu, stdout=serial, stderr=subprocess.STDOUT)

    def wait_guest(command, timeout=1500):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if vm.poll() is not None:
                raise RuntimeError('QEMU exited; see serial.log')
            try:
                result = subprocess.run(ssh + [command], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
            except subprocess.TimeoutExpired:
                # TCG 冷启动可能在建立连接后长时间等待 CPU；仍受整轮期限约束。
                continue
            if b'REMOTE HOST IDENTIFICATION HAS CHANGED' in result.stderr:
                raise RuntimeError('guest host key mismatch')
            if result.returncode == 0:
                return result.stdout.decode().strip()
            time.sleep(5)
        raise TimeoutError('guest readiness timeout; see serial.log')

    def phase(name):
        print('START guest phase', name, flush=True)
        path = evidence / (name + '.log')
        try:
            with path.open('wb') as log:
                guest_command = 'bash /root/dvt-bundle/tests/' + ('migration-guest.sh' if args.migration_source else 'platform-guest.sh') + ' ' + name
                if args.migration_source:
                    guest_command += ' ' + args.resource_profile
                run(ssh + [guest_command], stdout=log, stderr=subprocess.STDOUT, timeout=600)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            print(path.read_text(errors='replace'), flush=True)
            raise
        print('PASS guest phase', name, flush=True)

    def reboot():
        old_boot = wait_guest('cat /proc/sys/kernel/random/boot_id')
        run(ssh + ['systemctl reboot'], timeout=20)
        wait_guest('test "$(cat /proc/sys/kernel/random/boot_id)" != ' + old_boot + ' && systemctl is-active ssh', timeout=600)

    try:
        print('Waiting for cloud-init and required guest dependencies', flush=True)
        wait_guest('test -f /root/dvt-cloud-ready')
        print('PASS guest readiness', flush=True)
        # tar stdin 只传固定资产和客体用例，避免复制私有临时材料。
        names = [line.split('  ', 1)[1] for line in (ROOT / 'SHA256SUMS').read_text().splitlines()]
        bundle = work / 'bundle.tar'
        run(['tar', '-cf', str(bundle), 'install.sh', 'SHA256SUMS', 'tests/platform-guest.sh',
             'tests/platform-htb-native.py', 'tests/migration-guest.sh', *names], cwd=ROOT)
        with bundle.open('rb') as f:
            run(ssh + ['mkdir /root/dvt-bundle && tar --no-same-owner -xf - -C /root/dvt-bundle'], stdin=f)
        if args.migration_source:
            source_dir = work / 'source'
            source_dir.mkdir()
            pins = json.loads((ROOT / 'tests/migration-sources.json').read_text())[args.migration_source]
            base_url = 'https://github.com/alieismy/vps-tuning/releases/download/v' + args.migration_source + '/'
            def download(name, expected):
                target = source_dir / name
                target.parent.mkdir(parents=True, exist_ok=True)
                urllib.request.urlretrieve(base_url + Path(name).name, target)
                assert hashlib.sha256(target.read_bytes()).hexdigest() == expected, ('source checksum', name)
            for name, digest in pins.items():
                download(name, digest)
            for line in (source_dir / 'SHA256SUMS').read_text().splitlines():
                digest, name = line.split('  ', 1)
                assert not Path(name).is_absolute() and '..' not in Path(name).parts
                download(name, digest)
            (source_dir / 'VERSION').write_text(args.migration_source)
            (evidence / 'source-pins.json').write_text(json.dumps(pins, indent=2))
            source_bundle = work / 'source.tar'
            run(['tar', '-cf', str(source_bundle), '-C', str(source_dir), '.'])
            with source_bundle.open('rb') as f:
                run(ssh + ['mkdir /root/dvt-source && tar --no-same-owner -xf - -C /root/dvt-source'], stdin=f)
            phase('source-apply')
            reboot()
            phase('source-verified')
            reboot()
            phase('target-apply')
            reboot()
            phase('target-verified')
            result_label = 'fixed-source migration, three real guest reboots and target rollback'
        else:
            phase('apply')
            reboot()
            phase('after-reboot')
            reboot()
            phase('after-rollback-reboot')
            result_label = 'native lifecycle, two real guest reboots'
        (evidence / 'COMPLETED').write_text('PASS ' + result_label + '\n')
    finally:
        try:
            with (evidence / 'guest-evidence.tar').open('wb') as f:
                subprocess.run(ssh + ['tar -cf - -C /root dvt-evidence'], stdout=f, stderr=subprocess.DEVNULL, timeout=30)
        finally:
            vm.terminate()
            try:
                vm.wait(timeout=20)
            except subprocess.TimeoutExpired:
                vm.kill()
                vm.wait()
            serial.close()
    print('PASS', args.platform, args.arch, result_label, flush=True)


if __name__ == '__main__':
    main()
