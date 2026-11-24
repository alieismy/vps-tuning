#!/usr/bin/env bash
# W0 只读盘点；不输出代理配置、地址或凭据，不证明恢复/业务验收通过。
set -Eeuo pipefail
state=/var/lib/proxy-vps-tuning/state.json
command -v jq >/dev/null
test -f "$state"
jq '{schema_version,script_version,state,profile,
     network,swap:{created_by_script:.swap.created_by_script,size_mib:.swap.size_mib},
     original_key_count:(.original_sysctls|length),
     tcp_originals_complete:(.original_sysctls|all(."net.ipv4.tcp_rmem",."net.ipv4.tcp_wmem";
       type=="string" and test("^[0-9]+[\\t ]+[0-9]+[\\t ]+[0-9]+$"))),
     recovery_approval_present:has("tcp_baseline_recovery"),
     reconfigure_pending:(.reconfigure!=null),
     updated:.timestamps.last_update}' "$state"
printf '\nstate_sha256: '
sha256sum "$state" | awk '{print $1}'
printf 'entry_version: '
if command -v dvt >/dev/null; then dvt --version; else printf 'not-installed\n'; fi
printf 'kernel: '; uname -r
printf 'boot_id: '; cat /proc/sys/kernel/random/boot_id
printf '\nfq service:\n'
systemctl show proxy-vps-fq.service -p LoadState -p UnitFileState -p ActiveState -p Result -p ExecMainStatus
printf '\nx-ui service (absence is not a failure):\n'
systemctl show x-ui.service -p LoadState -p ActiveState -p LimitNOFILE
printf '\nqdisc topology (no addresses):\n'
tc -j qdisc show | jq '[.[]|{dev,kind,root,parent,handle}]'
