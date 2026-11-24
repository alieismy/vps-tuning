#!/usr/bin/env bash
# 仅在 platform-vm.py 创建的可丢弃客体执行；包含真实来源安装和三次真实重启。
set -Eeuo pipefail
export LC_ALL=C
cd /root/dvt-bundle
evidence=/root/dvt-evidence
state=/var/lib/proxy-vps-tuning/state.json
checkpoint=/root/dvt-migration
mkdir -p "$evidence"

case "$1" in
  source-apply)
    modprobe tcp_bbr
    modprobe sch_fq
    cat /proc/sys/kernel/random/boot_id >"$evidence/source-boot"
    # rc.4 覆盖 auto-clamped，rc.5 覆盖 explicit；5000 只是配置输入，无公网测速。
    source_version="$(cat /root/dvt-source/VERSION)"
    buffer=auto
    [ "$source_version" != 0.2.0-rc.5 ] || buffer=16777216
    bash /root/dvt-source/install.sh --source-dir /root/dvt-source --no-launch
    env BUFFER_TARGET_RTT_MS=100 BUF_MAX="$buffer" ENABLE_SWAP=1 SWAP_MB=1024 dvt apply --port 5000
    dvt verify
    cp "$state" "$evidence/source-state.json"
    ;;
  source-verified)
    test "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$evidence/source-boot")"
    dvt verify
    bash debian-vps-tuning.sh migrate prepare --checkpoint "$checkpoint"
    cp "$checkpoint/migration.json" "$evidence/prepared.json"
    bash "$checkpoint/dvt-migrate.sh" rollback --checkpoint "$checkpoint"
    if bash "$checkpoint/dvt-migrate.sh" continue --checkpoint "$checkpoint"; then exit 1; fi
    ;;
  target-apply)
    bash "$checkpoint/dvt-migrate.sh" continue --checkpoint "$checkpoint"
    jq -e '.phase=="TARGET_APPLIED_REBOOT_REQUIRED"' "$checkpoint/migration.json" >/dev/null
    if bash "$checkpoint/dvt-migrate.sh" continue --checkpoint "$checkpoint"; then exit 1; fi
    ;;
  target-verified)
    bash "$checkpoint/dvt-migrate.sh" continue --checkpoint "$checkpoint"
    bash "$checkpoint/dvt-migrate.sh" continue --checkpoint "$checkpoint"
    jq -e '.phase=="COMPLETE"' "$checkpoint/migration.json" >/dev/null
    test ! -e /var/lib/debian-vps-tuning-migrations/active
    bash install.sh --source-dir /root/dvt-bundle --no-launch
    dvt verify
    cp "$state" "$evidence/target-state.json"
    cp "$checkpoint/migration.json" "$evidence/complete.json"
    jq -e --slurpfile source "$evidence/source-state.json" '
      .network.port_speed_mbps==$source[0].network.port_speed_mbps and
      .network.target_rtt_ms==$source[0].network.target_rtt_ms and
      .network.buffer_mode==$source[0].network.buffer_mode and
      .network.buffer_max_bytes==$source[0].network.buffer_max_bytes and
      .swap.created_by_script==true and .swap.size_mib==$source[0].swap.size_mib
    ' "$state" >/dev/null
    # 使用目标自己的恢复路径，校验来源完整原值仍能恢复。
    PURGE_CREATED_SWAP=1 dvt rollback
    test ! -e "$state"
    python3 - <<'PY'
import json, pathlib, subprocess
source = json.loads(pathlib.Path('/root/dvt-evidence/source-state.json').read_text())
for key, expected in source['original_sysctls'].items():
    actual = subprocess.check_output(['sysctl', '-n', key], text=True)
    assert actual.split() == expected.split(), (key, actual, expected)
PY
    ;;
  *) exit 2 ;;
esac
