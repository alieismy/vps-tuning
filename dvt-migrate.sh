#!/usr/bin/env bash
# Persistent checkpoint/resume migration across DVT Release versions and reboots.

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

TOOL_VERSION='0.2.0-rc.2'
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
baseline_archive=''

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
  dvt-migrate.sh rollback --checkpoint PATH
  dvt-migrate.sh continue --checkpoint PATH
  dvt-migrate.sh status --checkpoint PATH

prepare is read-only. rollback runs the pinned old profile with
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
      -h | --help | help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

validate_file() {
  local label="$1" path="$2"
  [[ "$path" = /* ]] && [ -f "$path" ] && [ ! -L "$path" ] || die "${label} 必须是绝对路径普通文件且不能是符号链接。"
  [ "$(stat -c '%u' "$path")" = 0 ] && [ $((8#$(stat -c '%a' "$path") & 0022)) -eq 0 ] ||
    die "${label} 必须由 root 所有且不能被 group/world 写入。"
}

validate_baseline_archive() {
  local archive="$1" name expected
  [[ "$archive" = /* ]] && [ -d "$archive" ] && [ ! -L "$archive" ] || die '基线恢复归档路径无效。'
  [ "$(stat -c '%u' "$archive")" = 0 ] && [ "$(stat -c '%a' "$archive")" = 700 ] || die '基线恢复归档必须为 root/0700。'
  validate_file baseline-receipt "${archive}/receipt.json"
  jq -e '.schema_version==1 and .tool_version=="0.2.0-rc.2" and
    (.host_id | test("^VPS-[0-9]{2}$")) and
    (.mode=="historical" or .mode=="replacement") and
    (.files|type=="object") and
    (.files | has("plan.json") and has("state.before.json") and has("state.proposed.json") and has("guard.json") and has("source-profile.sh")) and
    (.files | to_entries | all(.[]; (.value|test("^[a-f0-9]{64}$")) and
      (.key|test("^(plan\\.json|state\\.(before|proposed)\\.json|guard\\.json|source-profile\\.sh|evidence\\.txt|file-[0-9]{2}\\.backup)$"))))' \
    "${archive}/receipt.json" >/dev/null || die '基线恢复归档契约无效。'
  while IFS=$'\t' read -r name expected; do
    validate_file baseline-asset "${archive}/${name}"
    [ "$(sha256sum "${archive}/${name}" | awk '{print $1}')" = "$expected" ] || die '基线恢复归档摘要漂移。'
  done < <(jq -r '.files | to_entries[] | [.key,.value] | @tsv' "${archive}/receipt.json")
}

resolve_baseline_archive() {
  local mode host_id machine_digest
  jq -e 'has("tcp_baseline_recovery")' "$STATE_FILE" >/dev/null || return 0
  baseline_archive="$(jq -r '.tcp_baseline_recovery.archive' "$STATE_FILE")"
  validate_baseline_archive "$baseline_archive"
  machine_digest="$(awk 'NR==1 {printf "%s",$0;exit}' /etc/machine-id | sha256sum | awk '{print $1}')"
  [ "$machine_digest" = "$(jq -r '.binding.machine_id_sha256' "${baseline_archive}/receipt.json")" ] ||
    die '基线恢复归档绑定的是另一台主机。'
  [ "$(sha256sum "$STATE_FILE" | awk '{print $1}')" = "$(jq -r '.files["state.proposed.json"]' "${baseline_archive}/receipt.json")" ] ||
    die '当前状态不是归档中的已核验恢复候选。'
  [ "$(sha256sum "$source_profile" | awk '{print $1}')" = "$(jq -r '.files["source-profile.sh"]' "${baseline_archive}/receipt.json")" ] ||
    die '基线恢复与迁移来源 profile 不一致。'
  jq -e --slurpfile plan "${baseline_archive}/plan.json" \
    --slurpfile before "${baseline_archive}/state.before.json" \
    --slurpfile receipt "${baseline_archive}/receipt.json" '
    .tcp_baseline_recovery as $r | $plan[0] as $p | $before[0] as $b | $receipt[0] as $a |
    $r.schema_version==1 and $p.schema_version==1 and $p.approved==true and
    $r.target_version=="0.2.0-rc.2" and $p.target_version==$r.target_version and
    $r.host_id==$p.host_id and $r.host_id==$a.host_id and $r.mode==$p.mode and $r.mode==$a.mode and
    $r.original_state_sha256==$a.files["state.before.json"] and
    $r.plan_sha256==$a.files["plan.json"] and $p.binding==$a.binding and
    $r.historical_originals_recovered==($r.mode=="historical") and
    (if $r.mode=="replacement" then $p.accept_new_baseline==true
     else $p.evidence.kind=="same-host-same-deployment" and
       $p.evidence.host_deployment_confirmed==true and $p.evidence.timestamps==$p.binding.timestamps end) and
    (.original_sysctls["net.ipv4.tcp_rmem"]==($p.vectors["net.ipv4.tcp_rmem"]|gsub("[\\t ]+";" "))) and
    (.original_sysctls["net.ipv4.tcp_wmem"]==($p.vectors["net.ipv4.tcp_wmem"]|gsub("[\\t ]+";" "))) and
    ((del(.tcp_baseline_recovery) |
      .original_sysctls["net.ipv4.tcp_rmem"]=$b.original_sysctls["net.ipv4.tcp_rmem"] |
      .original_sysctls["net.ipv4.tcp_wmem"]=$b.original_sysctls["net.ipv4.tcp_wmem"]) == $b)
  ' "$STATE_FILE" >/dev/null || die '恢复状态、批准计划与原始状态不一致。'
  mode="$(jq -r '.mode' "${baseline_archive}/receipt.json")"
  host_id="$(jq -r '.host_id' "${baseline_archive}/receipt.json")"
  info "${host_id}：使用已记录的 ${mode} TCP 恢复基线；保留原始状态与来源证据。"
}

record_post_reboot_tcp() {
  local rmem wmem temp="${checkpoint}/migration.json.tmp"
  jq -e '.baseline_recovery != null' "${checkpoint}/migration.json" >/dev/null || return 0
  rmem="$(sysctl -n net.ipv4.tcp_rmem)"; wmem="$(sysctl -n net.ipv4.tcp_wmem)"
  jq --arg rmem "$rmem" --arg wmem "$wmem" '
    .post_reboot_tcp={"net.ipv4.tcp_rmem":$rmem,"net.ipv4.tcp_wmem":$wmem} |
    if (.post_reboot_tcp | all(.[]; test("^[0-9]+[\\t ]+[0-9]+[\\t ]+[0-9]+$")))
    then . else error("post-reboot TCP vectors invalid") end' "${checkpoint}/migration.json" >"$temp"
  chmod 0600 "$temp"; mv -f "$temp" "${checkpoint}/migration.json"
}

verify_target_baseline() {
  jq -e '.baseline_recovery != null' "${checkpoint}/migration.json" >/dev/null || return 0
  jq -e --slurpfile migration "${checkpoint}/migration.json" '
    .original_sysctls as $actual | $migration[0].post_reboot_tcp as $expected |
    ($expected|type=="object") and
    all("net.ipv4.tcp_rmem", "net.ipv4.tcp_wmem";
      . as $key | ($actual[$key]|gsub("[\\t ]+";" ")) == ($expected[$key]|gsub("[\\t ]+";" ")))
  ' "$STATE_FILE" >/dev/null || die '目标状态未完整保存第一次重启后实际 TCP 基线；保留现场。'
}

validate_checkpoint() {
  [ -n "$checkpoint" ] && [[ "$checkpoint" = /* ]] && [ -d "$checkpoint" ] && [ ! -L "$checkpoint" ] ||
    die 'checkpoint 必须是已存在的绝对路径目录且不能是符号链接。'
  [ "$(stat -c '%u' "$checkpoint")" = 0 ] && [ $((8#$(stat -c '%a' "$checkpoint") & 0022)) -eq 0 ] ||
    die 'checkpoint 必须由 root 所有且不能被 group/world 写入。'
  [ -f "${checkpoint}/migration.json" ] && [ ! -L "${checkpoint}/migration.json" ] || die 'checkpoint 缺少 migration.json。'
  jq -e --arg version "$TOOL_VERSION" '
    .schema_version == 1 and .tool_version == $version and
    (.phase | type=="string") and (.assets.source_profile.sha256|type=="string") and
    (.assets.target_profile.sha256|type=="string") and (.assets.migration_tool.sha256|type=="string")
  ' "${checkpoint}/migration.json" >/dev/null || die 'migration.json schema 或工具版本无效。'
  for name in source-profile.sh target-profile.sh dvt-migrate.sh; do validate_file "$name" "${checkpoint}/${name}"; done
  [ "$(sha256sum "${checkpoint}/source-profile.sh" | awk '{print $1}')" = "$(jq -r '.assets.source_profile.sha256' "${checkpoint}/migration.json")" ] || die 'source profile hash 漂移。'
  [ "$(sha256sum "${checkpoint}/target-profile.sh" | awk '{print $1}')" = "$(jq -r '.assets.target_profile.sha256' "${checkpoint}/migration.json")" ] || die 'target profile hash 漂移。'
  [ "$(sha256sum "${checkpoint}/dvt-migrate.sh" | awk '{print $1}')" = "$(jq -r '.assets.migration_tool.sha256' "${checkpoint}/migration.json")" ] || die 'migration tool hash 漂移。'
  if jq -e '.baseline_recovery != null' "${checkpoint}/migration.json" >/dev/null; then
    validate_baseline_archive "${checkpoint}/baseline-recovery"
    [ "$(sha256sum "${checkpoint}/baseline-recovery/receipt.json" | awk '{print $1}')" = "$(jq -r '.baseline_recovery.receipt_sha256' "${checkpoint}/migration.json")" ] ||
      die 'checkpoint 基线来源记录摘要漂移。'
  fi
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
  [ ! -e "$checkpoint" ] && [ ! -L "$checkpoint" ] || die 'checkpoint 已存在，拒绝覆盖。'
  validate_file source-profile "$source_profile"; validate_file target-profile "$target_profile"
  [[ "$source_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]] &&
    [[ "$target_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]] || die 'source/target version 格式无效。'
  if [ "$target_version" != '0.2.0-rc.2' ] || ! [[ "$source_version" =~ ^0\.1\.0-rc\.([1-9]|1[0-9])$ ]]; then
    die '本版迁移器只接受 rc.1–rc.19 来源并迁移到 0.2.0-rc.2。'
  fi
  [[ "$profile_id" =~ ^debian1[23]-[A-Za-z0-9-]+$ ]] || die 'profile-id 格式无效。'
  [[ "$port_mbps" =~ ^[0-9]+$ ]] && [ "$((10#$port_mbps))" -ge 100 ] && [ "$((10#$port_mbps))" -le 1000 ] || die 'port 必须是 100..1000。'
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
  resolve_baseline_archive
  bash "$source_profile" verify >/dev/null
  env UPDATE_PREFLIGHT=1 PORT_SPEED_MBPS="$port_mbps" bash "$target_profile" preflight >/dev/null
  [ "$(sha256sum "$STATE_FILE" | awk '{print $1}')" = "$state_sha256" ] || die 'verify/preflight 期间来源状态漂移。'
  parent="$(dirname "$checkpoint")"; name="$(basename "$checkpoint")"
  [ -d "$parent" ] || install -d -o root -g root -m 0700 "$parent"
  [ ! -L "$parent" ] && [ "$(stat -c '%u' "$parent")" = 0 ] && [ $((8#$(stat -c '%a' "$parent") & 0022)) -eq 0 ] || die 'checkpoint 父目录不安全。'
  checkpoint="$(readlink -f "$parent")/${name}"; install -d -o root -g root -m 0700 "$checkpoint"
  install -o root -g root -m 0700 "$source_profile" "${checkpoint}/source-profile.sh"
  install -o root -g root -m 0700 "$target_profile" "${checkpoint}/target-profile.sh"
  install -o root -g root -m 0700 "${BASH_SOURCE[0]}" "${checkpoint}/dvt-migrate.sh"
  source_hash="$(sha256sum "${checkpoint}/source-profile.sh" | awk '{print $1}')"; target_hash="$(sha256sum "${checkpoint}/target-profile.sh" | awk '{print $1}')"; tool_hash="$(sha256sum "${checkpoint}/dvt-migrate.sh" | awk '{print $1}')"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; current_boot="$(boot_id)"
  [ -z "$baseline_archive" ] || initial_phase=PREPARING
  jq -n --arg version "$TOOL_VERSION" --arg utc "$now" --arg source "$source_version" --arg target "$target_version" \
    --arg phase "$initial_phase" \
    --arg profile "$profile_id" --argjson port "$port_mbps" --arg state "$state_sha256" --arg boot "$current_boot" \
    --arg source_hash "$source_hash" --arg target_hash "$target_hash" --arg tool_hash "$tool_hash" \
    '{schema_version:1,tool_version:$version,phase:$phase,created_utc:$utc,updated_utc:$utc,source_version:$source,target_version:$target,profile_id:$profile,port_speed_mbps:$port,source_state_sha256:$state,prepare_boot_id:$boot,reboot_gate_boot_id:null,assets:{source_profile:{file:"source-profile.sh",sha256:$source_hash},target_profile:{file:"target-profile.sh",sha256:$target_hash},migration_tool:{file:"dvt-migrate.sh",sha256:$tool_hash}},history:[{phase:$phase,utc:$utc,boot_id:$boot}]}' >"${checkpoint}/migration.json"
  chmod 0600 "${checkpoint}/migration.json"
  if [ -n "$baseline_archive" ]; then
    install -d -o root -g root -m 0700 "${checkpoint}/baseline-recovery"
    while IFS= read -r name; do
      install -o root -g root -m 0600 "${baseline_archive}/${name}" "${checkpoint}/baseline-recovery/${name}"
    done < <(jq -r '.files | keys[]' "${baseline_archive}/receipt.json")
    install -o root -g root -m 0600 "${baseline_archive}/receipt.json" "${checkpoint}/baseline-recovery/receipt.json"
    jq --slurpfile receipt "${baseline_archive}/receipt.json" \
      --arg digest "$(sha256sum "${baseline_archive}/receipt.json" | awk '{print $1}')" '
      .baseline_recovery={host_id:$receipt[0].host_id,mode:$receipt[0].mode,receipt_sha256:$digest}
    ' "${checkpoint}/migration.json" >"${checkpoint}/migration.json.tmp"
    chmod 0600 "${checkpoint}/migration.json.tmp"; mv -f "${checkpoint}/migration.json.tmp" "${checkpoint}/migration.json"
    validate_checkpoint
    [ "$(sha256sum "$STATE_FILE" | awk '{print $1}')" = "$state_sha256" ] || die '复制恢复归档期间来源状态漂移。'
    update_phase PREPARED
  fi
  info "checkpoint 已准备且未修改系统：${checkpoint}"
  info "下一步：bash ${checkpoint}/dvt-migrate.sh rollback --checkpoint ${checkpoint}"
}

rollback_stage() {
  local phase current_hash
  validate_checkpoint; phase="$(jq -r '.phase' "${checkpoint}/migration.json")"
  case "$phase" in
    PREPARED)
      current_hash="$(sha256sum "$STATE_FILE" 2>/dev/null | awk '{print $1}')"
      [ "$current_hash" = "$(jq -r '.source_state_sha256' "${checkpoint}/migration.json")" ] || die 'rollback 前 managed state 已漂移。'
      update_phase ROLLBACK_RUNNING
      PURGE_CREATED_SWAP=1 bash "${checkpoint}/source-profile.sh" rollback
      ;;
    ROLLBACK_RUNNING) [ ! -e "$STATE_FILE" ] || PURGE_CREATED_SWAP=1 bash "${checkpoint}/source-profile.sh" rollback ;;
    *) die "当前 phase=${phase} 不能执行 rollback。" ;;
  esac
  [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || die '旧版 rollback 后 managed state 仍存在；停止迁移。'
  update_phase ROLLED_BACK_REBOOT_REQUIRED "$(boot_id)"
  info '旧版已按选定恢复基线回退。现在必须重启；重启前不得执行 continue。'
}

continue_stage() {
  local phase gate current target_version profile port state_version state_phase
  validate_checkpoint; phase="$(jq -r '.phase' "${checkpoint}/migration.json")"; current="$(boot_id)"
  target_version="$(jq -r '.target_version' "${checkpoint}/migration.json")"; profile="$(jq -r '.profile_id' "${checkpoint}/migration.json")"; port="$(jq -r '.port_speed_mbps' "${checkpoint}/migration.json")"
  case "$phase" in
    ROLLED_BACK_REBOOT_REQUIRED)
      gate="$(jq -r '.reboot_gate_boot_id' "${checkpoint}/migration.json")"; [ "$current" != "$gate" ] || die '第一次重启尚未发生；boot ID 未变化。'
      [ ! -e "$STATE_FILE" ] || die '第一次重启后出现非预期 managed state。'
      record_post_reboot_tcp
      update_phase APPLY_RUNNING
      env PORT_SPEED_MBPS="$port" bash "${checkpoint}/target-profile.sh" preflight
      env PORT_SPEED_MBPS="$port" bash "${checkpoint}/target-profile.sh" apply
      ;;
    APPLY_RUNNING)
      if [ ! -e "$STATE_FILE" ]; then
        env PORT_SPEED_MBPS="$port" bash "${checkpoint}/target-profile.sh" preflight
        env PORT_SPEED_MBPS="$port" bash "${checkpoint}/target-profile.sh" apply
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
    verify_target_baseline
    update_phase TARGET_APPLIED_REBOOT_REQUIRED "$current"
    info '目标版已 apply。现在必须第二次重启；重启前不得再次执行 continue。'
    return 0
  fi
  if [ "$phase" = TARGET_APPLIED_REBOOT_REQUIRED ]; then
    gate="$(jq -r '.reboot_gate_boot_id' "${checkpoint}/migration.json")"; [ "$current" != "$gate" ] || die '第二次重启尚未发生；boot ID 未变化。'
    update_phase VERIFY_RUNNING
  fi
  bash "${checkpoint}/target-profile.sh" verify
  verify_target_baseline
  state_version="$(jq -r '.script_version // empty' "$STATE_FILE")"; state_phase="$(jq -r '.state // empty' "$STATE_FILE")"
  [ "$state_version" = "$target_version" ] && [ "$state_phase" = VERIFIED ] || die '最终 verify 未形成目标版本 VERIFIED 状态。'
  update_phase COMPLETE
  info '迁移 checkpoint 已完成。目标 VPS 的控制台可达性和真实业务链路仍需独立验收。'
}

main() {
  parse_args "$@"; [ "$(id -u)" -eq 0 ] || die '必须以 root 运行。'
  for command in awk bash chmod date dirname grep id install jq mv readlink sha256sum stat sysctl; do need_command "$command"; done
  case "$action" in
    prepare) prepare ;;
    rollback) rollback_stage ;;
    continue) continue_stage ;;
    status) validate_checkpoint; jq '.' "${checkpoint}/migration.json" ;;
    *) usage >&2; die "未知 action：$action" ;;
  esac
}

main "$@"
