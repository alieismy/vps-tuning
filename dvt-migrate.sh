#!/usr/bin/env bash
# Persistent checkpoint/resume migration across DVT Release versions and reboots.

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

TOOL_VERSION='0.3.0-rc.1'
STATE_FILE="${DVT_STATE_FILE:-/var/lib/proxy-vps-tuning/state.json}"

action=''
checkpoint=''
source_profile=''
target_profile=''
source_version=''
target_version=''
profile_id=''
port_mbps=''
state_sha256=''
swap_policy=''
swap_mib=''
proxy_unit=''
intent=''
MIGRATION_ROOT="${DVT_MIGRATION_ROOT:-/var/lib/debian-vps-tuning-migrations}"

die() { printf '[dvt-migrate][FAIL] %s\n' "$*" >&2; exit 2; }
info() { printf '[dvt-migrate] %s\n' "$*"; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
boot_id() { awk 'NR==1 {print; exit}' "${DVT_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"; }

usage() {
  cat <<'EOF'
Usage:
  dvt-migrate.sh prepare --checkpoint /absolute/new/path
    --source-profile PATH --target-profile PATH --source-version VERSION
    --target-version VERSION --profile-id ID --port MBPS --state-sha256 HEX
    [--swap-policy disabled|create --swap-mib MIB] [--proxy-unit UNIT]
  dvt-migrate.sh rollback --checkpoint PATH
  dvt-migrate.sh continue --checkpoint PATH
  dvt-migrate.sh status --checkpoint PATH
  dvt-migrate.sh cancel --checkpoint PATH

prepare writes checkpoint/ownership evidence, not system configuration. rollback runs the pinned old profile with
PURGE_CREATED_SWAP=1 and stops at the first reboot gate. continue checks that
the boot ID changed, applies the pinned target profile, stops at the second
reboot gate, and finally runs strict verify after another boot-ID change.
No command reboots the host or claims console/business-path acceptance.
EOF
}

parse_args() {
  [ "$#" -gt 0 ] || { usage >&2; exit 2; }
  action="$1"; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --checkpoint) [ "$#" -ge 2 ] || die '--checkpoint 缺少参数。'; checkpoint="$2"; shift 2 ;;
      --source-profile) [ "$#" -ge 2 ] || die '--source-profile 缺少参数。'; source_profile="$2"; shift 2 ;;
      --target-profile) [ "$#" -ge 2 ] || die '--target-profile 缺少参数。'; target_profile="$2"; shift 2 ;;
      --source-version) [ "$#" -ge 2 ] || die '--source-version 缺少参数。'; source_version="$2"; shift 2 ;;
      --target-version) [ "$#" -ge 2 ] || die '--target-version 缺少参数。'; target_version="$2"; shift 2 ;;
      --profile-id) [ "$#" -ge 2 ] || die '--profile-id 缺少参数。'; profile_id="$2"; shift 2 ;;
      --port) [ "$#" -ge 2 ] || die '--port 缺少参数。'; port_mbps="$2"; shift 2 ;;
      --state-sha256) [ "$#" -ge 2 ] || die '--state-sha256 缺少参数。'; state_sha256="$2"; shift 2 ;;
      --swap-policy) [ "$#" -ge 2 ] || die '--swap-policy 缺少参数。'; swap_policy="$2"; shift 2 ;;
      --swap-mib) [ "$#" -ge 2 ] || die '--swap-mib 缺少参数。'; swap_mib="$2"; shift 2 ;;
      --proxy-unit) [ "$#" -ge 2 ] || die '--proxy-unit 缺少参数。'; proxy_unit="$2"; shift 2 ;;
      -h | --help | help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

validate_migration_edge() {
  [[ "$target_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] || die 'target version 格式无效。'
  [ "$target_version" = "$TOOL_VERSION" ] || die '目标必须与迁移器版本一致。'
  case "$source_version:$target_version" in
    0.2.0-rc.[45]:0.2.0-rc.6 | 0.2.0-rc.[456]:0.2.0 | 0.2.0-rc.[456]:0.3.0-rc.1) ;;
    *) die '本版迁移器仅接受明确支持的 rc.4/rc.5→rc.6 或 rc.4/rc.5/rc.6→0.2.0/0.3.0-rc.1；不接受 Ubuntu 跨OS迁移或0.2.0已受管状态。' ;;
  esac
}

freeze_intent() {
  local created size expected_keys
  expected_keys="$(sed -n '/^PROFILE_SYSCTL_KEYS=(/,/^)/p' "$target_profile" | sed '1d;$d' | awk '{$1=$1;print}' | jq -Rsc 'split("\n")|map(select(length>0))|sort')"
  jq -e --arg source "$source_version" --arg profile "$profile_id" --argjson port "$port_mbps" --argjson keys "$expected_keys" '
    def uint: type=="number" and .==floor;
    .schema_version==4 and .state=="VERIFIED" and .reconfigure==null and .script_version==$source and .profile.id==$profile and
    .network.port_speed_mbps==$port and
    (.network.target_rtt_ms | uint and .>=20 and .<=500) and
    (.network.buffer_mode | IN("auto","auto-clamped","explicit")) and
    (.network.buffer_max_bytes | uint and .>=262144 and .<=268435456) and
    (.swap.created_by_script|type=="boolean") and
    (.original_sysctls|type=="object" and length==17 and (keys==$keys)) and
    (.original_sysctls|to_entries|all(.[]; (.key|test("^(net|vm)\\.[a-zA-Z0-9_.]+$")) and (.value|type=="string")))
  ' "$STATE_FILE" >/dev/null || die '来源状态或配置意图不完整；保留现场。'
  created="$(jq -r '.swap.created_by_script' "$STATE_FILE")"
  if [ "$created" = true ]; then
    size="$(jq -r '.swap.size_mib' "$STATE_FILE")"
    [ -z "$swap_policy" ] || [ "$swap_policy" = create ] || die '迁移不关闭来源已创建的 swap。'
    [ -z "$swap_mib" ] || [ "$swap_mib" = "$size" ] || die '迁移不改变来源 swap 大小。'
    swap_policy=create; swap_mib="$size"
  fi
  case "$swap_policy" in
    disabled) [ -z "$swap_mib" ] || die 'disabled 不接受 swap-mib。'; swap_mib=1024 ;;
    create) [[ "$swap_mib" =~ ^[0-9]+$ ]] && [ "$swap_mib" -ge 512 ] && [ "$swap_mib" -le 4096 ] || die 'create 需要明确的 swap-mib（512–4096），目标 profile 另作资源校验。' ;;
    *) die '未创建项目 swap 的来源不能推断意图；显式选择 --swap-policy disabled 或 create --swap-mib N。' ;;
  esac
  if [ -z "$proxy_unit" ] && [ "$(systemctl show -p LoadState --value x-ui.service 2>/dev/null || true)" = loaded ]; then proxy_unit=x-ui.service; fi
  [ -z "$proxy_unit" ] || [[ "$proxy_unit" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || die 'proxy-unit 必须为单个有效 service 名。'
  intent="$(jq -c --arg policy "$swap_policy" --argjson size "$swap_mib" --arg unit "$proxy_unit" '
    {port:.network.port_speed_mbps,rtt:.network.target_rtt_ms,
     buffer:(if .network.buffer_mode=="explicit" then (.network.buffer_max_bytes|tostring) else "auto" end),
     swap_policy:$policy,swap_mib:$size,proxy_unit:$unit}' "$STATE_FILE")"
}

run_profile_clean() {
  local script="$1" operation="$2" strict="${3:-0}" update="${4:-0}" config="$intent" enabled=0
  [ -n "$config" ] || config="$(jq -c '.intent' "${checkpoint}/migration.json")"
  [ "$(jq -r '.swap_policy' <<<"$config")" != create ] || enabled=1
  local -a options=("PATH=$PATH" 'LC_ALL=C' 'HOME=/root' "DVT_STATE_FILE=$STATE_FILE"
    "PORT_SPEED_MBPS=$(jq -r '.port' <<<"$config")" "BUFFER_TARGET_RTT_MS=$(jq -r '.rtt' <<<"$config")"
    "BUF_MAX=$(jq -r '.buffer' <<<"$config")" "ENABLE_SWAP=$enabled" "SWAP_MB=$(jq -r '.swap_mib' <<<"$config")"
    "UPDATE_PREFLIGHT=$update")
  if [ "$operation" = rollback ]; then options+=('PURGE_CREATED_SWAP=1'); fi
  proxy_unit="$(jq -r '.proxy_unit' <<<"$config")"
  if [ "$strict" = 1 ] && [ -n "$proxy_unit" ]; then options+=('REQUIRE_PROXY_SERVICE=1' "PROXY_SERVICE_UNITS=$proxy_unit"); fi
  env -i "${options[@]}" bash "$script" "$operation"
}

acquire_migration() {
  local registered
  [ -n "$checkpoint" ] && [[ "$checkpoint" = /* ]] && [ ! -L "$checkpoint" ] || die 'checkpoint 必须为绝对非符号链接路径。'
  validate_checkpoint_location
  checkpoint="$(readlink -m -- "$checkpoint")"
  [[ "$MIGRATION_ROOT" = /* ]] || die 'migration root 必须为绝对路径。'
  [ ! -L "$MIGRATION_ROOT" ] || die 'migration root 不接受符号链接。'
  MIGRATION_ROOT="$(readlink -m -- "$MIGRATION_ROOT")"
  case "$MIGRATION_ROOT" in "$(dirname "$STATE_FILE")" | "$(dirname "$STATE_FILE")"/*) die 'migration root 必须在受管树外。';; esac
  if [ ! -e "$MIGRATION_ROOT" ]; then install -d -o root -g root -m 0700 "$MIGRATION_ROOT"; fi
  [ "$(stat -c '%u:%a' "$MIGRATION_ROOT")" = 0:700 ] || die 'migration root 必须为 root/0700。'
  [ ! -L "$MIGRATION_ROOT/lock" ] || die 'migration lock 类型无效。'
  exec 8>>"$MIGRATION_ROOT/lock"
  flock -n 8 || die '另一个迁移命令正在运行。'
  if [ -e "$MIGRATION_ROOT/active" ] || [ -L "$MIGRATION_ROOT/active" ]; then
    validate_file active "$MIGRATION_ROOT/active"
    registered="$(cat "$MIGRATION_ROOT/active")"
    [ "$registered" = "$checkpoint" ] || die '存在另一未完成 checkpoint；先接续或撤销原任务。'
  elif [ "$action" != prepare ] && [ "$(jq -r '.phase // empty' "${checkpoint}/migration.json" 2>/dev/null)" != COMPLETE ] &&
       [ "$(jq -r '.phase // empty' "${checkpoint}/migration.json" 2>/dev/null)" != CANCELLED ]; then
    die '缺少活动迁移登记；保留 checkpoint，不猜测任务归属。'
  fi
}

release_migration() {
  [ -e "$MIGRATION_ROOT/active" ] || return 0
  [ "$(cat "$MIGRATION_ROOT/active")" = "$checkpoint" ] || die '活动迁移归属不匹配。'
  rm -- "$MIGRATION_ROOT/active"
}

archive_source() {
  local path
  validate_source_state_directory
  install -d -o root -g root -m 0700 "${checkpoint}/recovery"
  for path in "$(dirname "$STATE_FILE")"/*; do
    [ -f "$path" ] || continue
    install -o root -g root -m 0600 "$path" "${checkpoint}/recovery/${path##*/}"
  done
  install -o root -g root -m 0600 "$STATE_FILE" "${checkpoint}/source-state.json"
  (cd "${checkpoint}/recovery"; sha256sum -- ./* >SHA256SUMS)
}

verify_frozen_state() {
  jq -e --slurpfile m "${checkpoint}/migration.json" --slurpfile source "${checkpoint}/source-state.json" '
    .network as $n | $m[0].intent as $i |
    $n.port_speed_mbps==$i.port and $n.target_rtt_ms==$i.rtt and
    (if $i.buffer=="auto" then ($n.buffer_mode|IN("auto","auto-clamped"))
     else $n.buffer_mode=="explicit" and $n.buffer_max_bytes==($i.buffer|tonumber) end) and
    (if $i.swap_policy=="disabled" then .swap.created_by_script==false
     elif .swap.created_by_script then .swap.size_mib==$i.swap_mib
     else $source[0].swap.created_by_script==false end)
  ' "$STATE_FILE" >/dev/null || die '目标配置与冻结意图不一致；保留现场。'
}

record_baseline() {
  local key value baseline='{}' tmp
  while IFS= read -r key; do
    value="$(sysctl -n "$key")" || die '无法读取重启后基线。'
    value="$(awk '{$1=$1;print}' <<<"$value")"
    baseline="$(jq -c --arg key "$key" --arg value "$value" '.+{($key):$value}' <<<"$baseline")"
  done < <(jq -r '.original_sysctls|keys[]' "${checkpoint}/source-state.json")
  jq -e --argjson actual "$baseline" '.original_sysctls|with_entries(.value|=gsub("[\\t ]+";" "))|.==$actual' \
    "${checkpoint}/source-state.json" >/dev/null || die '重启后的系统基线与来源原值不同；停止，不猜原值。'
  if jq -e 'has("post_reboot_sysctls")' "${checkpoint}/migration.json" >/dev/null; then
    jq -e --argjson baseline "$baseline" '.post_reboot_sysctls==$baseline' "${checkpoint}/migration.json" >/dev/null || die '重试前基线漂移。'
    return 0
  fi
  tmp="$(mktemp "${checkpoint}/baseline.XXXXXX")"
  jq --argjson baseline "$baseline" '.post_reboot_sysctls=$baseline' "${checkpoint}/migration.json" >"$tmp"
  mv -f -- "$tmp" "${checkpoint}/migration.json"
}

validate_file() {
  local label="$1" path="$2"
  [[ "$path" = /* ]] && [ -f "$path" ] && [ ! -L "$path" ] || die "${label} 必须是绝对路径普通文件且不能是符号链接。"
  [ "$(stat -c '%u' "$path")" = 0 ] && [ $((8#$(stat -c '%a' "$path") & 0022)) -eq 0 ] ||
    die "${label} 必须由 root 所有且不能被 group/world 写入。"
}

verify_target_baseline() {
  jq -e --slurpfile migration "${checkpoint}/migration.json" '
    (.original_sysctls|with_entries(.value|=gsub("[\\t ]+";" "))) == $migration[0].post_reboot_sysctls
  ' "$STATE_FILE" >/dev/null || die '目标未保存已核验的完整恢复基线；保留现场。'
}

validate_checkpoint_location() {
  local canonical managed
  canonical="$(readlink -m -- "$checkpoint")" || die '无法规范化 checkpoint 路径。'
  managed="$(readlink -m -- "$(dirname "${STATE_FILE:-/var/lib/proxy-vps-tuning/state.json}")")" || die '无法规范化受管状态路径。'
  case "$canonical" in
    "$managed" | "$managed"/*)
      die 'checkpoint 必须放在受管状态目录树之外；先保留并外移既有恢复材料。'
      ;;
  esac
}

validate_checkpoint() {
  validate_checkpoint_location
  [ -n "$checkpoint" ] && [[ "$checkpoint" = /* ]] && [ -d "$checkpoint" ] && [ ! -L "$checkpoint" ] ||
    die 'checkpoint 必须是已存在的绝对路径目录且不能是符号链接。'
  [ "$(stat -c '%u' "$checkpoint")" = 0 ] && [ $((8#$(stat -c '%a' "$checkpoint") & 0022)) -eq 0 ] ||
    die 'checkpoint 必须由 root 所有且不能被 group/world 写入。'
  [ -f "${checkpoint}/migration.json" ] && [ ! -L "${checkpoint}/migration.json" ] || die 'checkpoint 缺少 migration.json。'
  jq -e --arg version "$TOOL_VERSION" '
    .schema_version == 2 and .tool_version == $version and
    (.intent.port|type=="number" and .==floor and .>=1 and .<=10000) and
    (.intent.rtt|type=="number" and .==floor and .>=20 and .<=500) and
    .target_version==$version and .intent.port==.port_speed_mbps and
    (.intent.buffer|type=="string" and (.=="auto" or test("^[0-9]{6,9}$"))) and (.intent.swap_policy|IN("disabled","create")) and
    (.intent.swap_mib|type=="number" and .==floor and .>=512 and .<=4096) and
    (.intent.proxy_unit|type=="string" and (.=="" or test("^[A-Za-z0-9_.@-]+\\.service$"))) and
    (.phase | type=="string") and (.assets.source_profile.sha256|type=="string") and
    (.assets.target_profile.sha256|type=="string") and (.assets.migration_tool.sha256|type=="string")
  ' "${checkpoint}/migration.json" >/dev/null || die 'migration.json schema 或工具版本无效。'
  local name
  validate_file metadata "${checkpoint}/migration.json"
  [ -d "${checkpoint}/recovery" ] && [ ! -L "${checkpoint}/recovery" ] || die '恢复目录类型无效。'
  validate_file source-state "${checkpoint}/source-state.json"
  [ "$(sha256sum "${checkpoint}/source-state.json" | awk '{print $1}')" = "$(jq -r '.source_state_sha256' "${checkpoint}/migration.json")" ] || die '来源归档摘要漂移。'
  validate_file recovery-manifest "${checkpoint}/recovery/SHA256SUMS"
  [ "$(sha256sum "${checkpoint}/recovery/SHA256SUMS" | awk '{print $1}')" = "$(jq -r '.recovery_manifest_sha256' "${checkpoint}/migration.json")" ] || die '恢复清单摘要漂移。'
  (cd "${checkpoint}/recovery"; sha256sum -c SHA256SUMS >/dev/null) || die '恢复材料摘要漂移。'
  for name in source-profile.sh target-profile.sh dvt-migrate.sh; do validate_file "$name" "${checkpoint}/${name}"; done
  [ "$(sha256sum "${checkpoint}/source-profile.sh" | awk '{print $1}')" = "$(jq -r '.assets.source_profile.sha256' "${checkpoint}/migration.json")" ] || die 'source profile hash 漂移。'
  [ "$(sha256sum "${checkpoint}/target-profile.sh" | awk '{print $1}')" = "$(jq -r '.assets.target_profile.sha256' "${checkpoint}/migration.json")" ] || die 'target profile hash 漂移。'
  [ "$(sha256sum "${checkpoint}/dvt-migrate.sh" | awk '{print $1}')" = "$(jq -r '.assets.migration_tool.sha256' "${checkpoint}/migration.json")" ] || die 'migration tool hash 漂移。'
}

update_phase() {
  local phase="$1" gate_boot="${2:-}" temp="${checkpoint}/migration.json.tmp"
  jq --arg phase "$phase" --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg gate "$gate_boot" '
    .phase=$phase | .updated_utc=$utc |
    (if $gate != "" then .reboot_gate_boot_id=$gate else . end) |
    .history += [{phase:$phase,utc:$utc,boot_id:(if $gate!="" then $gate else null end)}]
  ' "${checkpoint}/migration.json" >"$temp"
  chmod 0600 "$temp"; mv -f "$temp" "${checkpoint}/migration.json"
}

prepare() {
  local parent name source_hash target_hash tool_hash now current_boot initial_phase=PREPARED
  [ -n "$checkpoint" ] && [[ "$checkpoint" = /* ]] || die 'prepare 必须指定绝对 --checkpoint。'
  validate_checkpoint_location
  [ ! -e "$checkpoint" ] && [ ! -L "$checkpoint" ] || die 'checkpoint 已存在，拒绝覆盖。'
  validate_file source-profile "$source_profile"; validate_file target-profile "$target_profile"
  validate_migration_edge
  [[ "$profile_id" =~ ^debian1[23]-(1c512m|1c1g|1c2g|adaptive)$ ]] || die 'profile-id 不在当前 Debian 迁移范围。'
  [[ "$port_mbps" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$port_mbps))" -ge 1 ] && [ "$((10#$port_mbps))" -le 10000 ] || die 'port 必须是 1..10000。'
  port_mbps="$((10#$port_mbps))"
  [[ "$state_sha256" =~ ^[0-9a-f]{64}$ ]] || die 'state-sha256 格式无效。'
  [ -f "$STATE_FILE" ] && [ "$(sha256sum "$STATE_FILE" | awk '{print $1}')" = "$state_sha256" ] || die '当前 managed state 与准备输入不一致。'
  jq -e '.original_sysctls | all(."net.ipv4.tcp_rmem", ."net.ipv4.tcp_wmem";
    type == "string" and test("^[0-9]+[\\t ]+[0-9]+[\\t ]+[0-9]+$"))' "$STATE_FILE" >/dev/null ||
    die '来源状态缺少完整 TCP buffer 三元组；无法证明旧版回滚可恢复原值，拒绝创建迁移 checkpoint。'
  grep -Fq "SCRIPT_VERSION='${source_version}'" "$source_profile" || die 'source profile 版本契约不匹配。'
  grep -Fq "SCRIPT_VERSION='${target_version}'" "$target_profile" || die 'target profile 版本契约不匹配。'
  if ! grep -Fq "PROFILE_ID='${profile_id}'" "$source_profile" ||
    ! grep -Fq "PROFILE_ID='${profile_id}'" "$target_profile"; then
    die 'profile-id 契约不匹配。'
  fi
  if jq -e 'has("tcp_baseline_recovery")' "$STATE_FILE" >/dev/null; then
    die '来源仍带旧目标恢复审批；先用固定原工具完成原任务，不能跨目标复用。'
  fi
  freeze_intent
  validate_source_state_directory
  run_profile_clean "$source_profile" verify >/dev/null
  run_profile_clean "$target_profile" preflight 0 1 >/dev/null
  [ "$(sha256sum "$STATE_FILE" | awk '{print $1}')" = "$state_sha256" ] || die 'verify/preflight 期间来源状态漂移。'
  parent="$(dirname "$checkpoint")"; name="$(basename "$checkpoint")"
  [ -d "$parent" ] || install -d -o root -g root -m 0700 "$parent"
  [ ! -L "$parent" ] && [ "$(stat -c '%u' "$parent")" = 0 ] && [ $((8#$(stat -c '%a' "$parent") & 0022)) -eq 0 ] || die 'checkpoint 父目录不安全。'
  checkpoint="$(readlink -f "$parent")/${name}"
  mkdir -m 0700 -- "$checkpoint" || die 'checkpoint 已存在或无法独占创建。'
  printf '%s\n' "$checkpoint" >"$MIGRATION_ROOT/active.tmp"
  chmod 0600 "$MIGRATION_ROOT/active.tmp"
  mv -f "$MIGRATION_ROOT/active.tmp" "$MIGRATION_ROOT/active"
  archive_source
  install -o root -g root -m 0700 "$source_profile" "${checkpoint}/source-profile.sh"
  install -o root -g root -m 0700 "$target_profile" "${checkpoint}/target-profile.sh"
  install -o root -g root -m 0700 "${BASH_SOURCE[0]}" "${checkpoint}/dvt-migrate.sh"
  source_hash="$(sha256sum "${checkpoint}/source-profile.sh" | awk '{print $1}')"; target_hash="$(sha256sum "${checkpoint}/target-profile.sh" | awk '{print $1}')"; tool_hash="$(sha256sum "${checkpoint}/dvt-migrate.sh" | awk '{print $1}')"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; current_boot="$(boot_id)"
  jq -n --arg version "$TOOL_VERSION" --arg utc "$now" --arg source "$source_version" --arg target "$target_version" \
    --arg phase "$initial_phase" --argjson intent "$intent" \
    --arg recovery "$(sha256sum "${checkpoint}/recovery/SHA256SUMS" | awk '{print $1}')" \
    --arg profile "$profile_id" --argjson port "$port_mbps" --arg state "$state_sha256" --arg boot "$current_boot" \
    --arg source_hash "$source_hash" --arg target_hash "$target_hash" --arg tool_hash "$tool_hash" \
    '{schema_version:2,intent:$intent,recovery_manifest_sha256:$recovery,tool_version:$version,phase:$phase,created_utc:$utc,updated_utc:$utc,source_version:$source,target_version:$target,profile_id:$profile,port_speed_mbps:$port,source_state_sha256:$state,prepare_boot_id:$boot,reboot_gate_boot_id:null,assets:{source_profile:{file:"source-profile.sh",sha256:$source_hash},target_profile:{file:"target-profile.sh",sha256:$target_hash},migration_tool:{file:"dvt-migrate.sh",sha256:$tool_hash}},history:[{phase:$phase,utc:$utc,boot_id:$boot}]}' >"${checkpoint}/migration.json.tmp"
  jq -e '.schema_version==2' "${checkpoint}/migration.json.tmp" >/dev/null
  chmod 0600 "${checkpoint}/migration.json.tmp"
  mv -f "${checkpoint}/migration.json.tmp" "${checkpoint}/migration.json"
  [ "$(sha256sum "$STATE_FILE" | awk '{print $1}')" = "$state_sha256" ] || die '归档期间来源状态漂移。'
  validate_checkpoint
  info "冻结配置：${intent}"
  info "checkpoint 已准备且未修改系统：${checkpoint}"
  info "下一步：bash ${checkpoint}/dvt-migrate.sh rollback --checkpoint ${checkpoint}"
}

validate_source_state_directory() {
  local directory path name
  directory="$(dirname -- "$STATE_FILE")"
  [ -d "$directory" ] && [ ! -L "$directory" ] && [ "$(stat -c '%u' "$directory")" = 0 ] ||
    die '来源状态目录类型或所有权异常；保留现场。'
  for path in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    name="${path##*/}"
    if [ "$name" != "${STATE_FILE##*/}" ]; then
      case "$name" in
        state.json | qdisc-original.json | provider-sysctl.conf.original | \
        reconfigure-state.previous.json | reconfigure-sysctl.previous.conf | reconfigure-last-failure.json) ;;
        *) die "来源状态目录含非事务材料，先核验并迁出账本或恢复材料；保留现场：${path}" ;;
      esac
    fi
    [ -f "$path" ] && [ ! -L "$path" ] && [ "$(stat -c '%u' "$path")" = 0 ] ||
      die "来源状态条目必须为 root 所有的普通文件；保留现场：${path}"
  done
}

rollback_stage() {
  local phase current_hash
  validate_checkpoint; phase="$(jq -r '.phase' "${checkpoint}/migration.json")"
  case "$phase" in
    PREPARED)
      current_hash="$(sha256sum "$STATE_FILE" 2>/dev/null | awk '{print $1}')"
      [ "$current_hash" = "$(jq -r '.source_state_sha256' "${checkpoint}/migration.json")" ] || die 'rollback 前 managed state 已漂移。'
      validate_source_state_directory
      update_phase ROLLBACK_RUNNING
      run_profile_clean "${checkpoint}/source-profile.sh" rollback
      ;;
    ROLLBACK_RUNNING)
      if [ -e "$STATE_FILE" ]; then
        validate_source_state_directory
        run_profile_clean "${checkpoint}/source-profile.sh" rollback
      fi
      ;;
    *) die "当前 phase=${phase} 不能执行 rollback。" ;;
  esac
  [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || die '旧版 rollback 后 managed state 仍存在；停止迁移。'
  update_phase ROLLED_BACK_REBOOT_REQUIRED "$(boot_id)"
  info '旧版已按选定恢复基线回退。现在必须重启；重启前不得执行 continue。'
}

continue_stage() {
  local phase gate current target_version profile state_version state_phase
  validate_checkpoint; phase="$(jq -r '.phase' "${checkpoint}/migration.json")"; current="$(boot_id)"
  target_version="$(jq -r '.target_version' "${checkpoint}/migration.json")"; profile="$(jq -r '.profile_id' "${checkpoint}/migration.json")"
  case "$phase" in
    ROLLED_BACK_REBOOT_REQUIRED)
      gate="$(jq -r '.reboot_gate_boot_id' "${checkpoint}/migration.json")"; [ "$current" != "$gate" ] || die '第一次重启尚未发生；boot ID 未变化。'
      [ ! -e "$STATE_FILE" ] || die '第一次重启后出现非预期 managed state。'
      record_baseline
      update_phase APPLY_RUNNING
      run_profile_clean "${checkpoint}/target-profile.sh" preflight
      run_profile_clean "${checkpoint}/target-profile.sh" apply
      ;;
    APPLY_RUNNING)
      if [ ! -e "$STATE_FILE" ]; then
        record_baseline
        run_profile_clean "${checkpoint}/target-profile.sh" preflight
        run_profile_clean "${checkpoint}/target-profile.sh" apply
      fi
      ;;
    TARGET_APPLIED_REBOOT_REQUIRED) ;;
    VERIFY_RUNNING) ;;
    *) die "当前 phase=${phase} 不能执行 continue。" ;;
  esac
  if [ "$phase" = ROLLED_BACK_REBOOT_REQUIRED ] || [ "$phase" = APPLY_RUNNING ]; then
    state_version="$(jq -r '.script_version // empty' "$STATE_FILE")"; state_phase="$(jq -r '.state // empty' "$STATE_FILE")"
    if [ "$state_version" != "$target_version" ] ||
      [ "$(jq -r '.profile.id // empty' "$STATE_FILE")" != "$profile" ] ||
      { [ "$state_phase" != APPLIED ] && [ "$state_phase" != VERIFIED ]; }; then
      die '目标 apply 后 managed state 契约不匹配。'
    fi
    [ "$state_phase" = VERIFIED ] ||
      die '目标 apply 留下 APPLIED，尚未完成配置验证；保留现场，按目标版本恢复说明处理后再 continue，当前无需重启。'
    verify_target_baseline
    verify_frozen_state
    update_phase TARGET_APPLIED_REBOOT_REQUIRED "$current"
    info '目标版已 apply。现在必须第二次重启；重启前不得再次执行 continue。'
    return 0
  fi
  if [ "$phase" = TARGET_APPLIED_REBOOT_REQUIRED ]; then
    gate="$(jq -r '.reboot_gate_boot_id' "${checkpoint}/migration.json")"; [ "$current" != "$gate" ] || die '第二次重启尚未发生；boot ID 未变化。'
    update_phase VERIFY_RUNNING
  fi
  run_profile_clean "${checkpoint}/target-profile.sh" verify 1
  verify_frozen_state
  verify_target_baseline
  state_version="$(jq -r '.script_version // empty' "$STATE_FILE")"; state_phase="$(jq -r '.state // empty' "$STATE_FILE")"
  [ "$state_version" = "$target_version" ] && [ "$state_phase" = VERIFIED ] || die '最终 verify 未形成目标版本 VERIFIED 状态。'
  update_phase COMPLETE
  release_migration
  info '迁移 checkpoint 已完成。目标 VPS 的控制台可达性和真实业务链路仍需独立验收。'
}

main() {
  umask 077
  parse_args "$@"
  case "$action" in prepare|rollback|continue|status|cancel) ;; *) die "未知 action：$action";; esac
  [ "$(id -u)" -eq 0 ] || die '必须以 root 运行。'
  for command in awk bash chmod date dirname grep id install jq mv readlink sha256sum stat sysctl flock cat rm mkdir mktemp sed env systemctl; do need_command "$command"; done
  if [ "$action" != status ]; then acquire_migration; fi
  if [ "$action" = continue ] || [ "$action" = cancel ]; then
    validate_checkpoint
    if [ "$(jq -r '.phase' "${checkpoint}/migration.json")" = COMPLETE ] ||
       { [ "$action" = cancel ] && [ "$(jq -r '.phase' "${checkpoint}/migration.json")" = CANCELLED ]; }; then
      release_migration; info '任务已结束；未重新应用。'; return
    fi
  fi
  case "$action" in
    prepare) prepare ;;
    rollback) rollback_stage ;;
    continue) continue_stage ;;
    cancel)
      validate_checkpoint
      [ "$(jq -r '.phase' "${checkpoint}/migration.json")" = PREPARED ] || die '仅可撤销 PREPARED；其他阶段先恢复。'
      [ "$(sha256sum "$STATE_FILE" | awk '{print $1}')" = "$(jq -r '.source_state_sha256' "${checkpoint}/migration.json")" ] || die '来源状态已漂移。'
      update_phase CANCELLED; release_migration; info '已撤销准备；恢复材料保留。'
      ;;
    status) validate_checkpoint; jq '.'  "${checkpoint}/migration.json" ;;
    *) usage >&2; die "未知 action：$action" ;;
  esac
}

main "$@"
