#!/usr/bin/env bash
# 仅供隔离、可丢弃的 CI 虚拟机；不在用户 VPS 上自动执行。
set -Eeuo pipefail
export LC_ALL=C
cd /root/dvt-bundle
evidence=/root/dvt-evidence
state=/var/lib/proxy-vps-tuning/state.json
mkdir -p "$evidence"
initial_port=1
# 新平台以用户关注的2000Mbps输入验证；既有平台仍保留1Mbps下界。
# shellcheck disable=SC1091
. /etc/os-release
if [ "$ID:$VERSION_ID" = ubuntu:26.04 ]; then initial_port=2000; fi

snapshot() {
  python3 - "$1" <<'PY'
import json, pathlib, re, subprocess, sys
source = pathlib.Path('debian13-1c1g-vps-tuning.sh').read_text()
keys = re.search(r'PROFILE_SYSCTL_KEYS=\((.*?)\n\)', source, re.S)[1].split()
values = {k: ' '.join(subprocess.check_output(['sysctl', '-n', k], text=True).split()) for k in keys}
pathlib.Path('/root/dvt-evidence/' + sys.argv[1] + '.sysctl.json').write_text(json.dumps(values, sort_keys=True))
qdiscs = json.loads(subprocess.check_output(['tc', '-j', 'qdisc', 'show'], text=True))
pathlib.Path('/root/dvt-evidence/' + sys.argv[1] + '.qdisc.json').write_text(json.dumps(qdiscs, sort_keys=True))
PY
}

case "$1" in
  apply)
    # 模块加载是 VM 的测试前置；没有伪造内核能力或替换系统识别。
    modprobe tcp_bbr
    modprobe sch_fq
    cat /etc/os-release >"$evidence/os-release"
    dpkg-query -W -f='${binary:Package} ${Version}\n' >"$evidence/package-versions.txt"
    {
      systemctl --version
      for utility in stat readlink install chmod chown sha256sum cp mv; do
        command -v "$utility"
        "$utility" --version | sed -n '1p'
      done
    } >"$evidence/system-utilities.txt"
    uname -a >"$evidence/uname.txt"
    getconf PAGESIZE >"$evidence/page-size.txt"
    cat /proc/meminfo >"$evidence/meminfo.txt"
    cat /proc/sys/kernel/random/boot_id >"$evidence/boot-before"
    test ! -e "$state"
    snapshot before
    bash install.sh --source-dir /root/dvt-bundle --no-launch
    bash install.sh --source-dir /root/dvt-bundle --no-launch
    dvt preflight --port "$initial_port"
    dvt apply --port "$initial_port"
    dvt verify
    jq -e --argjson port "$initial_port" '.network.port_speed_mbps==$port' "$state" >/dev/null
    cp "$state" "$evidence/initial-state.json"
    dvt apply --port "$initial_port"
    # 第二次 apply 应只验证，不重写状态或受管文件。
    cmp "$state" "$evidence/initial-state.json"
    dvt reconfigure --port 10000
    dvt verify
    cp "$state" "$evidence/high-port-state.json"
    dvt reconfigure --port "$initial_port"
    dvt verify
    cp "$state" "$evidence/before-reboot-state.json"
    python3 tests/platform-htb-native.py
    ;;
  after-reboot)
    test "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$evidence/boot-before")"
    cat /proc/sys/kernel/random/boot_id >"$evidence/boot-after"
    dvt verify
    dvt apply --port "$initial_port"
    cp "$state" "$evidence/after-reboot-state.json"
    jq -e '.schema_version==4 and .state=="VERIFIED" and
      (.profile.os_id=="debian" or .profile.os_id=="ubuntu") and
      (.profile.architecture=="x86_64" or .profile.architecture=="aarch64") and
      (if .profile.os_id=="ubuntu" then .profile.debian_version==null else true end)' "$state" >/dev/null
    PURGE_CREATED_SWAP=1 dvt rollback
    test ! -e "$state"
    snapshot rollback
    cmp "$evidence/before.sysctl.json" "$evidence/rollback.sysctl.json"
    # managed_files 来自真实应用状态；逐个核对回滚后没有遗留。
    jq -r '.managed_files[].path' "$evidence/before-reboot-state.json" |
      while IFS= read -r path; do test ! -e "$path"; done
    test ! -e /swapfile-proxy
    if [ "$ID:$VERSION_ID" = ubuntu:26.04 ]; then
      # tcp_init()按启动时可用缓冲页计算tcp_rmem上限，跨启动可有微小变化。
      # 只读记录本次内核默认值；不写sysctl，不放宽即时回滚的17项精确比较。
      cat >/etc/systemd/system/dvt-ci-kernel-baseline.service <<'EOF_BASELINE'
[Unit]
Description=Read-only CI kernel TCP baseline
DefaultDependencies=no
After=systemd-modules-load.service
Before=systemd-sysctl.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'cat /proc/sys/kernel/random/boot_id /proc/sys/net/ipv4/tcp_rmem'
StandardOutput=file:/run/dvt-ci-kernel-tcp-rmem
[Install]
WantedBy=sysinit.target
EOF_BASELINE
      cp /etc/systemd/system/dvt-ci-kernel-baseline.service "$evidence/"
      systemctl daemon-reload
      systemctl enable dvt-ci-kernel-baseline.service
    fi
    cat /proc/sys/kernel/random/boot_id >"$evidence/rollback-boot-before"
    ;;
  after-rollback-reboot)
    test "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$evidence/rollback-boot-before")"
    cat /proc/sys/kernel/random/boot_id >"$evidence/rollback-boot-after"
    test ! -e "$state"
    snapshot final
    if [ "$ID:$VERSION_ID" = ubuntu:26.04 ]; then
      test "$(systemctl show dvt-ci-kernel-baseline.service -p Result --value)" = success
      cp /run/dvt-ci-kernel-tcp-rmem "$evidence/kernel-tcp-rmem-after-rollback.txt"
    fi
    python3 - <<'PY'
import json, pathlib
p = pathlib.Path('/root/dvt-evidence')
before_sysctl = json.loads((p / 'before.sysctl.json').read_text())
final_sysctl = json.loads((p / 'final.sysctl.json').read_text())
if 'VERSION_ID="26.04"' in (p / 'os-release').read_text():
    boot, kernel_rmem = (p / 'kernel-tcp-rmem-after-rollback.txt').read_text().splitlines()
    assert boot == (p / 'rollback-boot-after').read_text().strip()
    # 只允许恢复到同次启动、systemd-sysctl之前实际读回的内核默认值。
    assert final_sysctl['net.ipv4.tcp_rmem'] == ' '.join(kernel_rmem.split())
    before_sysctl['net.ipv4.tcp_rmem'] = final_sysctl['net.ipv4.tcp_rmem']
assert before_sysctl == final_sysctl, ('post-reboot sysctl mismatch', before_sysctl, final_sysctl)
def roots(name):
    return {q['dev']: q for q in json.loads((p / (name + '.qdisc.json')).read_text()) if q.get('root')}
before = roots('before')
for name in ('rollback', 'final'):
    after = roots(name)
    assert before.keys() == after.keys(), (name, 'interfaces changed')
    for dev, saved in before.items():
        current = after[dev]
        assert saved['kind'] == current['kind'], (name, dev, 'root kind changed')
        if saved.get('handle') != '0:':
            assert saved.get('handle') == current.get('handle'), (name, dev, 'explicit handle changed')
        old_options, new_options = saved.get('options', {}), current.get('options', {})
        assert old_options.keys() == new_options.keys(), (name, dev, 'option set changed')
        for key, value in old_options.items():
            observed = new_options[key]
            # fq_codel 的内核 tick↔微秒换算存在 1 us 量化差；与受管恢复契约一致。
            if saved['kind'] == 'fq_codel' and key in ('target', 'interval', 'ce_threshold'):
                assert abs(value - observed) <= 1, (name, dev, key, value, observed)
            else:
                assert value == observed, (name, dev, key, value, observed)
print('PASS install/apply/idempotence/reconfigure/reboot/verify/rollback/reboot')
(p / 'COMPLETED').write_text('Functional VM lifecycle; no proxy business or performance acceptance\n')
PY
    ;;
  *) exit 2 ;;
esac
