#!/usr/bin/env bash
# 仅在 platform-vm.py 创建的可丢弃客体执行；包含真实来源安装和三次真实重启。
set -Eeuo pipefail
export LC_ALL=C
cd /root/dvt-bundle
evidence=/root/dvt-evidence
state=/var/lib/proxy-vps-tuning/state.json
checkpoint=/root/dvt-migration
mkdir -p "$evidence"
resource="${2:?migration resource profile required}"
case "$resource" in
  legacy) port=5000; rtt=100; enable_swap=1 ;;
  adaptive) port=1000; rtt=200; enable_swap=0 ;;
  *) exit 2 ;;
esac

assert_no_swap() {
  [ "$resource" = adaptive ] || return 0
  test -z "$(swapon --show=NAME --noheadings)"
  test "$(awk '$1=="SwapTotal:" {print $2}' /proc/meminfo)" = 0
  test ! -e /swapfile-proxy && test ! -L /swapfile-proxy
  test -z "$(awk '$1 !~ /^#/ && ($3=="swap" || $1=="/swapfile-proxy") {print}' /etc/fstab)"
  if [ -e "$state" ]; then
    jq -e '.swap.created_by_script==false and .swap.size_mib==0 and .swap.active==false' "$state" >/dev/null
  fi
  printf 'PASS no active swap, project swap file or fstab entry: %s\n' "$1" >>"$evidence/no-swap-checks.txt"
}

assert_no_swap "$1-before"

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
    env BUFFER_TARGET_RTT_MS="$rtt" BUF_MAX="$buffer" ENABLE_SWAP="$enable_swap" SWAP_MB=1024 dvt apply --port "$port"
    if [ "$resource" = adaptive ]; then
      test "$source_version" = 0.2.0-rc.4
      test "$(nproc)" = 2
      jq -e '.profile.id=="debian13-adaptive" and .network.port_speed_mbps==1000 and
        .network.target_rtt_ms==200 and .network.buffer_mode=="auto-clamped"' "$state" >/dev/null
      cat /proc/meminfo >"$evidence/source-meminfo.txt"
    else
      jq -e '.swap.created_by_script==true and .swap.size_mib==1024' "$state" >/dev/null
    fi
    dvt verify
    cp "$state" "$evidence/source-state.json"
    ;;
  source-verified)
    test "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$evidence/source-boot")"
    dvt verify
    swap_options=()
    if [ "$resource" = adaptive ]; then swap_options=(--swap-policy disabled); fi
    bash debian-vps-tuning.sh migrate prepare --checkpoint "$checkpoint" "${swap_options[@]}"
    if [ "$resource" = adaptive ]; then
      jq -e '.intent.swap_policy=="disabled" and .profile_id=="debian13-adaptive"' "$checkpoint/migration.json" >/dev/null
    fi
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
      .profile.id==$source[0].profile.id and
      .swap.created_by_script==$source[0].swap.created_by_script and
      .swap.size_mib==$source[0].swap.size_mib
    ' "$state" >/dev/null
    assert_no_swap target-verified-before-rollback
    # 使用目标自己的恢复路径，校验来源完整原值仍能恢复。
    PURGE_CREATED_SWAP=1 dvt rollback
    test ! -e "$state"
    python3 - <<'PY'
import json, pathlib, subprocess
evidence = pathlib.Path('/root/dvt-evidence')
source = json.loads((evidence / 'source-state.json').read_text())
target = json.loads((evidence / 'target-state.json').read_text())
checkpoint = json.loads((evidence / 'complete.json').read_text())
normalize = lambda values: {key: value.split() for key, value in values.items()}
assert len(source['original_sysctls']) == 17
assert normalize(source['original_sysctls']) == normalize(target['original_sysctls']) == normalize(checkpoint['post_reboot_sysctls'])
for key, expected in source['original_sysctls'].items():
    actual = subprocess.check_output(['sysctl', '-n', key], text=True)
    assert actual.split() == expected.split(), (key, actual, expected)
PY
    ;;
  *) exit 2 ;;
esac

assert_no_swap "$1-after"
