#!/usr/bin/env bash
# Generated from tools/profile-template.sh.in. Do not edit generated profiles directly.
# Debian 13 / 1 vCPU / 1 GiB / 3X-UI-first conservative VPS tuning.

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

SCRIPT_VERSION='0.2.0-rc.2'
STATE_SCHEMA_VERSION=4
LEGACY_STATE_SCHEMA_VERSION=3
NAMESPACE='proxy-vps'
MANAGED_MARKER='# Managed by debian-vps-tuning; namespace=proxy-vps'

TARGET_DEBIAN_VERSION='13'
TARGET_OS_ID='debian'
TARGET_OS_VERSION='13'
PROFILE_RESOURCE_POLICY='fixed'
PROFILE_ID='debian13-1c1g'
PROFILE_LABEL='Debian 13 / 1 vCPU / 1 GiB'
PROFILE_CPU_MIN=1
PROFILE_CPU_MAX=1
PROFILE_RAM_MIN_MIB=768
PROFILE_RAM_MAX_MIB=1535
SWAP_MAX_MIB=2048
SWAP_CREATE_RESERVE_MIB=512
JOURNAL_SYSTEM_MAX_USE='128M'
JOURNAL_SYSTEM_KEEP_FREE='512M'
JOURNAL_RUNTIME_MAX_USE='32M'

DEFAULT_PORT_SPEED_MBPS=200
DEFAULT_BUFFER_TARGET_RTT_MS=200
BUFFER_TARGET_NUMERATOR=5
BUFFER_TARGET_DENOMINATOR=4
DEFAULT_SWAP_MB=1024
MIN_BUF_MAX=262144
MAX_BUF_MAX=33554432
SWAP_FILE='/swapfile-proxy'
FSTAB_FILE='/etc/fstab'

PORT_SPEED_MBPS_INPUT="${PORT_SPEED_MBPS:-}"
BUFFER_TARGET_RTT_MS_INPUT="${BUFFER_TARGET_RTT_MS:-}"
BUF_MAX_ENV_WAS_SET="${BUF_MAX+x}"
BUF_MAX_INPUT="${BUF_MAX:-auto}"
ENABLE_SWAP="${ENABLE_SWAP:-1}"
SWAP_MB_INPUT="${SWAP_MB:-$DEFAULT_SWAP_MB}"
PURGE_CREATED_SWAP="${PURGE_CREATED_SWAP:-0}"
ALLOW_EMPTY_STATE_RECOVERY="${ALLOW_EMPTY_STATE_RECOVERY:-0}"
PROXY_SERVICE_UNITS_INPUT="${PROXY_SERVICE_UNITS:-}"
REQUIRE_PROXY_SERVICE="${REQUIRE_PROXY_SERVICE:-0}"
DIAG_INTERVAL_SECONDS="${DIAG_INTERVAL_SECONDS:-5}"
DIAG_INCLUDE_SOCKET_DETAILS="${DIAG_INCLUDE_SOCKET_DETAILS:-0}"
UPDATE_PREFLIGHT="${UPDATE_PREFLIGHT:-0}"

PORT_SPEED_MBPS=''
BUFFER_TARGET_RTT_MS=''
BUF_MAX=''
BUF_MAX_MODE=''
BUFFER_BDP_BYTES=''
BUFFER_TARGET_BYTES=''
BUFFER_COVERAGE_MS=''
BUFFER_CLAMPED=0
ROOT_FS_TYPE=''
SWAP_CREATE_ALLOWED='1'
SWAP_SKIP_REASON=''
STATE_DIR_CREATED=0
QDISC_MATCH_REASON=''
POLICY_ROUTING_IPV4_STATE='unavailable'
POLICY_ROUTING_IPV6_STATE='unavailable'
BENCHMARK_ACTIVE_CHILD_PID=''
BENCHMARK_ACTIVE_CHILD_PGID=''
BENCHMARK_TIMEOUT_TERMINATE_GRACE_SECONDS=5

SYSCTL_FILE="/etc/sysctl.d/90-${NAMESPACE}.conf"
SYSCTL_SCAN_ROOT='/etc'
JOURNAL_FILE="/etc/systemd/journald.conf.d/90-${NAMESPACE}.conf"
FQ_HELPER="/usr/local/sbin/${NAMESPACE}-fq"
FQ_SERVICE_NAME="${NAMESPACE}-fq.service"
FQ_SERVICE="/etc/systemd/system/${FQ_SERVICE_NAME}"
XUI_DROPIN_DIR='/etc/systemd/system/x-ui.service.d'
XUI_DROPIN="${XUI_DROPIN_DIR}/90-${NAMESPACE}.conf"
XUI_NOFILE_LIMIT=65536
STATE_DIR="/var/lib/${NAMESPACE}-tuning"
STATE_FILE="${STATE_DIR}/state.json"
QDISC_STATE_FILE="${STATE_DIR}/qdisc-original.json"
RECONFIGURE_STATE_BACKUP="${STATE_DIR}/reconfigure-state.previous.json"
RECONFIGURE_SYSCTL_BACKUP="${STATE_DIR}/reconfigure-sysctl.previous.conf"
RECONFIGURE_FAILURE_EVIDENCE="${STATE_DIR}/reconfigure-last-failure.json"
LOCK_FILE="/run/lock/${NAMESPACE}-tuning.lock"

EXIT_USAGE=2
EXIT_UNSUPPORTED=3
EXIT_CONFLICT=4
EXIT_VERIFY=5
EXIT_ROLLBACK=6
WARNINGS=0
APPLY_ACTIVE=0
RECONFIGURE_ACTIVE=0
RECONFIGURE_STATE_BACKUP_SHA256=''
RECONFIGURE_SYSCTL_BACKUP_SHA256=''
PROVIDER_SYSCTL_TRANSFER_REQUIRED=0

PROFILE_SYSCTL_KEYS=(
  net.core.default_qdisc
  net.ipv4.tcp_congestion_control
  net.core.rmem_max
  net.core.wmem_max
  net.core.rmem_default
  net.core.wmem_default
  net.ipv4.tcp_rmem
  net.ipv4.tcp_wmem
  net.core.netdev_max_backlog
  net.core.somaxconn
  net.ipv4.tcp_max_syn_backlog
  net.ipv4.tcp_fastopen
  net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_keepalive_time
  net.ipv4.tcp_keepalive_intvl
  net.ipv4.tcp_keepalive_probes
  vm.swappiness
)

DEFAULT_PROXY_SERVICE_UNITS=(
  x-ui.service
  xray.service
  s-ui.service
  sing-box.service
  3x-ui.service
  v2ray.service
  hysteria-server.service
  hysteria.service
  tuic-server.service
  tuic.service
  naive.service
)

info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
error() { printf '[x] %s\n' "$*" >&2; }
die() { local code="$1"; shift; error "$*"; exit "$code"; }

need_root() {
  [ "${EUID}" -eq 0 ] || die "$EXIT_UNSUPPORTED" '必须以 root 权限运行。'
}

lock_process_start() {
  # comm 可包含空格和括号；移除到最后一个右括号后，starttime 是第 20 列。
  local stat_line
  IFS= read -r stat_line <"/proc/$1/stat" 2>/dev/null || return 1
  printf '%s\n' "${stat_line##*) }" | awk '{print $20}'
}

lock_uptime_seconds() {
  awk '{printf "%.0f\n", int($1)}' /proc/uptime 2>/dev/null
}

lock_conflict_details() {
  local pid start acquired extra current now
  IFS=' ' read -r pid start acquired extra <"$LOCK_FILE" || return 0
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$start" =~ ^[0-9]+$ && "$acquired" =~ ^[0-9]+$ ]] || return 0
  [ -z "$extra" ] || return 0
  current="$(lock_process_start "$pid")" || return 0
  [ "$current" = "$start" ] || return 0
  now="$(lock_uptime_seconds)" || return 0
  [[ "$now" =~ ^[0-9]+$ ]] && [ "$now" -ge "$acquired" ] || return 0
  printf ' owner_pid=%s held_seconds=%s（观测值）' "$pid" "$((now - acquired))"
}

acquire_lock() {
  local start acquired owner_pid="$BASHPID"
  mkdir -p "$(dirname "$LOCK_FILE")"
  # 竞争者不能在获取锁之前截断持有者的诊断信息；flock 仍是唯一仲裁依据。
  exec 9>>"$LOCK_FILE"
  flock -n 9 || die "$EXIT_CONFLICT" "另一个 proxy-vps-tuning 进程正在运行。$(lock_conflict_details)"
  : >"$LOCK_FILE"
  start="$(lock_process_start "$owner_pid")" || start=''
  acquired="$(lock_uptime_seconds)" || acquired=''
  if [[ "$start" =~ ^[0-9]+$ && "$acquired" =~ ^[0-9]+$ ]]; then
    printf '%s %s %s\n' "$owner_pid" "$start" "$acquired" >"$LOCK_FILE"
  fi
}

is_bool() { [ "$1" = '0' ] || [ "$1" = '1' ]; }

validate_inputs() {
  if [ "${PROFILE_RESOURCE_POLICY:-fixed}" = adaptive ]; then configure_resource_policy; fi
  BUFFER_CLAMPED=0
  PORT_SPEED_MBPS="${PORT_SPEED_MBPS_INPUT:-$DEFAULT_PORT_SPEED_MBPS}"
  BUFFER_TARGET_RTT_MS="${BUFFER_TARGET_RTT_MS_INPUT:-$DEFAULT_BUFFER_TARGET_RTT_MS}"

  [[ "$PORT_SPEED_MBPS" =~ ^[0-9]{1,5}$ ]] ||
    die "$EXIT_USAGE" 'PORT_SPEED_MBPS 必须是 1–10000 的整数。'
  PORT_SPEED_MBPS=$((10#$PORT_SPEED_MBPS))
  if [ "$PORT_SPEED_MBPS" -lt 1 ] || [ "$PORT_SPEED_MBPS" -gt 10000 ]; then
    die "$EXIT_USAGE" 'PORT_SPEED_MBPS 必须在 1–10000 之间。'
  fi

  [[ "$BUFFER_TARGET_RTT_MS" =~ ^[0-9]{2,3}$ ]] ||
    die "$EXIT_USAGE" 'BUFFER_TARGET_RTT_MS 必须是 20–500 的整数。'
  BUFFER_TARGET_RTT_MS=$((10#$BUFFER_TARGET_RTT_MS))
  if [ "$BUFFER_TARGET_RTT_MS" -lt 20 ] || [ "$BUFFER_TARGET_RTT_MS" -gt 500 ]; then
    die "$EXIT_USAGE" 'BUFFER_TARGET_RTT_MS 必须在 20–500 之间。'
  fi

  BUFFER_BDP_BYTES=$((PORT_SPEED_MBPS * 125 * BUFFER_TARGET_RTT_MS))
  BUFFER_TARGET_BYTES=$(((BUFFER_BDP_BYTES * BUFFER_TARGET_NUMERATOR + BUFFER_TARGET_DENOMINATOR - 1) / BUFFER_TARGET_DENOMINATOR))
  if [ "$BUF_MAX_INPUT" = 'auto' ]; then
    BUF_MAX_MODE='auto'
    if [ "${PROFILE_RESOURCE_POLICY:-fixed}" = adaptive ]; then
      BUF_MAX=16777216
      while [ "$BUF_MAX" -lt "$BUFFER_TARGET_BYTES" ] && [ "$BUF_MAX" -lt 268435456 ]; do
        BUF_MAX=$((BUF_MAX * 2))
      done
    elif [ "$BUFFER_TARGET_BYTES" -le 16777216 ]; then
      BUF_MAX=16777216
    elif [ "$BUFFER_TARGET_BYTES" -le 33554432 ]; then
      BUF_MAX=33554432
    else
      BUF_MAX=67108864
    fi
    if [ "$BUF_MAX" -gt "$MAX_BUF_MAX" ]; then
      BUF_MAX="$MAX_BUF_MAX"
      BUF_MAX_MODE='auto-clamped'
      BUFFER_CLAMPED=1
    fi
    if [ "$BUF_MAX" -lt "$BUFFER_TARGET_BYTES" ]; then
      BUF_MAX_MODE='auto-clamped'
      BUFFER_CLAMPED=1
    fi
  else
    [[ "$BUF_MAX_INPUT" =~ ^[0-9]{6,9}$ ]] ||
      die "$EXIT_USAGE" 'BUF_MAX 必须为 auto 或允许范围内的整数字节数。'
    BUF_MAX=$((10#$BUF_MAX_INPUT))
    BUF_MAX_MODE='explicit'
  fi
  if [ "$BUF_MAX" -lt "$MIN_BUF_MAX" ] || [ "$BUF_MAX" -gt "$MAX_BUF_MAX" ]; then
    die "$EXIT_USAGE" "BUF_MAX 必须在 ${MIN_BUF_MAX}–${MAX_BUF_MAX} 字节之间。"
  fi
  BUFFER_COVERAGE_MS=$((BUF_MAX * 8 / (PORT_SPEED_MBPS * 1000)))
  if [ "$BUFFER_CLAMPED" -eq 1 ]; then
    warn "按 ${PROFILE_LABEL} 的内存预算将自动 socket 上限限制为 $((MAX_BUF_MAX / 1048576)) MiB；约覆盖 ${BUFFER_COVERAGE_MS} ms，未达到 ${BUFFER_TARGET_NUMERATOR}/${BUFFER_TARGET_DENOMINATOR}×BDP 性能目标。"
  fi

  is_bool "$ENABLE_SWAP" || die "$EXIT_USAGE" 'ENABLE_SWAP 只能为 0 或 1。'
  is_bool "$PURGE_CREATED_SWAP" || die "$EXIT_USAGE" 'PURGE_CREATED_SWAP 只能为 0 或 1。'
  is_bool "$REQUIRE_PROXY_SERVICE" || die "$EXIT_USAGE" 'REQUIRE_PROXY_SERVICE 只能为 0 或 1。'
  is_bool "$UPDATE_PREFLIGHT" || die "$EXIT_USAGE" 'UPDATE_PREFLIGHT 只能为 0 或 1。'
  [[ "$SWAP_MB_INPUT" =~ ^[0-9]{3,4}$ ]] ||
    die "$EXIT_USAGE" "SWAP_MB 必须是 512–${SWAP_MAX_MIB} 的整数。"
  SWAP_MB=$((10#$SWAP_MB_INPUT))
  if [ "$SWAP_MB" -lt 512 ] || [ "$SWAP_MB" -gt "$SWAP_MAX_MIB" ]; then
    die "$EXIT_USAGE" "SWAP_MB 必须在 512–${SWAP_MAX_MIB} MiB 之间。"
  fi
}

missing_commands() {
  local cmd
  for cmd in awk grep sed sysctl ip tc ss modprobe modinfo systemctl swapon swapoff mkswap findmnt find flock sha256sum pgrep ps jq stat readlink install nproc date tee sort dirname; do
    command -v "$cmd" >/dev/null 2>&1 || printf '%s\n' "$cmd"
  done
}

ensure_required_tools() {
  local missing
  missing="$(missing_commands)"
  if [ -n "$missing" ]; then
    error '缺少必要命令：'
    printf '%s\n' "$missing" >&2
    error '请先执行：apt install -y iproute2 procps kmod util-linux jq'
    exit "$EXIT_UNSUPPORTED"
  fi
}

check_supported_os() {
  [ -r /etc/os-release ] || die "$EXIT_UNSUPPORTED" '/etc/os-release 不可读。'
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "$TARGET_OS_ID" ] || [ "${VERSION_ID:-}" != "$TARGET_OS_VERSION" ]; then
    die "$EXIT_UNSUPPORTED" "本脚本仅支持 ${TARGET_OS_ID} ${TARGET_OS_VERSION}。"
  fi
  case "$(uname -m)" in
    x86_64 | aarch64) ;;
    *) die "$EXIT_UNSUPPORTED" '本版本支持 x86_64/amd64 和 aarch64/ARM64。' ;;
  esac

  local kernel
  kernel="$(uname -r)"
  case "$TARGET_OS_ID:$TARGET_OS_VERSION:$kernel" in
    debian:12:6.1.* | debian:13:6.12.* | ubuntu:24.04:6.8.*) ;;
    *) warn "内核 ${kernel} 不属于当前验证基线；将继续按实际 BBR/fq 能力判断。" ;;
  esac
}

memory_mib() { awk '/^MemTotal:/ {print int($2 / 1024); exit}' /proc/meminfo; }

configure_resource_policy() {
  local mem
  mem="$(memory_mib)"
  [[ "$mem" =~ ^[0-9]{1,12}$ ]] && [ "$mem" -ge 384 ] ||
    die "$EXIT_UNSUPPORTED" '自适应配置需要至少 384 MiB 可识别物理内存。'
  # socket 上限按字节计算，不修改按页计量的 tcp_mem，也不随核数线性放大。
  if [ "$mem" -ge 8192 ]; then MAX_BUF_MAX=268435456
  else MAX_BUF_MAX=$((mem * 1048576 / 32)); fi
  [ "$MAX_BUF_MAX" -ge 16777216 ] || MAX_BUF_MAX=16777216
}

check_resource_profile() {
  local mem cpus
  cpus="$(nproc 2>/dev/null || true)"
  mem="$(memory_mib)"
  [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || die "$EXIT_UNSUPPORTED" '无法读取可用逻辑 CPU 数。'
  [[ "$mem" =~ ^[0-9]+$ ]] || die "$EXIT_UNSUPPORTED" '无法读取物理内存。'
  if [ "${PROFILE_RESOURCE_POLICY:-fixed}" = adaptive ]; then configure_resource_policy; fi
  if [ "$cpus" -lt "$PROFILE_CPU_MIN" ] || { [ "$PROFILE_CPU_MAX" -gt 0 ] && [ "$cpus" -gt "$PROFILE_CPU_MAX" ]; }; then
    die "$EXIT_UNSUPPORTED" "检测到 ${cpus} vCPU，不符合 ${PROFILE_LABEL} 的 ${PROFILE_CPU_MIN}–${PROFILE_CPU_MAX} vCPU 范围。"
  fi
  if [ "$mem" -lt "$PROFILE_RAM_MIN_MIB" ] || { [ "$PROFILE_RAM_MAX_MIB" -gt 0 ] && [ "$mem" -gt "$PROFILE_RAM_MAX_MIB" ]; }; then
    die "$EXIT_UNSUPPORTED" "检测到 ${mem} MiB RAM，不符合 ${PROFILE_LABEL} 的 ${PROFILE_RAM_MIN_MIB}–${PROFILE_RAM_MAX_MIB} MiB 范围。"
  fi
}

state_exists() { [ -f "$STATE_FILE" ]; }

state_file_path_is_valid() {
  local candidate="$1" result
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  [ "$(stat -c '%u' "$candidate" 2>/dev/null || true)" = '0' ] || return 1
  [ -s "$candidate" ] || return 1
  result="$(jq -c -e -s --argjson schema "$STATE_SCHEMA_VERSION" \
    --argjson legacy_schema "$LEGACY_STATE_SCHEMA_VERSION" --argjson update_preflight "$UPDATE_PREFLIGHT" \
    --arg version "$SCRIPT_VERSION" --arg profile "$PROFILE_ID" \
    --arg provider_file "${SYSCTL_SCAN_ROOT}/sysctl.conf" \
    --arg provider_backup "${STATE_DIR}/provider-sysctl.conf.original" '
    length == 1 and
    (.[0] |
      type == "object" and
      ((.schema_version == $schema) or ($update_preflight == 1 and .schema_version == $legacy_schema)) and
      (.script_version | type == "string") and
      .profile.id == $profile and
      (.state | type == "string") and
      (.network | type == "object") and
      (.original_sysctls | type == "object") and
      (.qdisc.file | type == "string") and
      (.qdisc.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.swap | type == "object") and
      (.managed_files | type == "array") and
      (.timestamps | type == "object") and
      (if .schema_version == $schema then
        (.script_version == $version or
          ($update_preflight == 1 and
            (.script_version | test("^0\\.1\\.0-rc\\.([1-9]|1[0-9])$")))) and
        (.provider_sysctl_transfer | type == "object") and
        (.provider_sysctl_transfer.required | type == "boolean") and
        (.provider_sysctl_transfer.source_path == $provider_file) and
        (.provider_sysctl_transfer.backup_path == $provider_backup) and
        (.provider_sysctl_transfer.keys | type == "array") and
        (.provider_sysctl_transfer.state | IN("NOT_REQUIRED", "DETECTED", "PLANNED", "TRANSFERRED", "RESTORED")) and
        (if .provider_sysctl_transfer.required then
          (.provider_sysctl_transfer.original_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
          (.provider_sysctl_transfer.original_uid | type == "number") and
          (.provider_sysctl_transfer.original_gid | type == "number") and
          (.provider_sysctl_transfer.original_mode | type == "string" and test("^[0-7]{3,4}$")) and
          (.provider_sysctl_transfer.keys | length > 0 and length <= 2) and
          (all(.provider_sysctl_transfer.keys[];
            (.key == "net.core.default_qdisc" and .value == "fq") or
            (.key == "net.ipv4.tcp_congestion_control" and .value == "bbr"))) and
          (([.provider_sysctl_transfer.keys[].key] | unique | length) == (.provider_sysctl_transfer.keys | length)) and
          (if .provider_sysctl_transfer.state == "PLANNED" or .provider_sysctl_transfer.state == "TRANSFERRED" then
            (.provider_sysctl_transfer.backup_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
            (.provider_sysctl_transfer.transferred_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
          elif .provider_sysctl_transfer.state == "DETECTED" then
            .provider_sysctl_transfer.backup_sha256 == null and .provider_sysctl_transfer.transferred_sha256 == null
          else true end)
        else
          .provider_sysctl_transfer.state == "NOT_REQUIRED" and
          .provider_sysctl_transfer.original_sha256 == null and
          .provider_sysctl_transfer.backup_sha256 == null and
          .provider_sysctl_transfer.transferred_sha256 == null and
          ((.provider_sysctl_transfer.original_uid == null and
            .provider_sysctl_transfer.original_gid == null and
            .provider_sysctl_transfer.original_mode == null) or
           (.provider_sysctl_transfer.original_uid == 0 and
            .provider_sysctl_transfer.original_gid == 0 and
            .provider_sysctl_transfer.original_mode == "000")) and
          (.provider_sysctl_transfer.keys | length == 0)
        end)
      else true end))
  ' "$candidate" 2>/dev/null)" || return 1
  [ "$result" = 'true' ]
}

state_file_is_valid() { state_file_path_is_valid "$STATE_FILE"; }

validate_state_file() {
  local saved_version=''
  state_exists || return 0
  state_file_is_valid && return 0
  if [ "$UPDATE_PREFLIGHT" = '0' ] && [ ! -L "$STATE_FILE" ] &&
    [ "$(stat -c '%u' "$STATE_FILE" 2>/dev/null || true)" = '0' ]; then
    saved_version="$(jq -er -s --arg profile "$PROFILE_ID" --argjson schema "$STATE_SCHEMA_VERSION" '
      select(length == 1) | .[0] |
      select(.schema_version == $schema and .profile.id == $profile) |
      .script_version | select(type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+-rc\\.[0-9]+$"))
    ' "$STATE_FILE" 2>/dev/null || true)"
    if [ -n "$saved_version" ] && [ "$saved_version" != "$SCRIPT_VERSION" ]; then
      die "$EXIT_CONFLICT" "状态属于版本 ${saved_version}，当前脚本为 ${SCRIPT_VERSION}；请使用固定目标总控执行 update 只读升级检查，保留旧状态并使用对应来源版本处理恢复。"
    fi
  fi
  die "$EXIT_CONFLICT" "状态文件为空、损坏、包含多份 JSON 或 schema/profile/版本不匹配：${STATE_FILE}。不要继续 apply；只有确认它来自 rc.2 首次系统写入前的失败，才可使用 ALLOW_EMPTY_STATE_RECOVERY=1 执行 recover。"
}

state_get() { jq -er "$1" "$STATE_FILE"; }

atomic_json_commit() {
  local target="$1" tmp="$2"
  if [ ! -f "$tmp" ] || [ -L "$tmp" ] || [ ! -s "$tmp" ] ||
    ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$tmp" >/dev/null ||
    ! chmod 0600 "$tmp" || ! chown root:root "$tmp" || ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 1
  fi
}

state_set_phase() {
  local phase="$1" tmp
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! jq --arg phase "$phase" --arg now "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    '.state=$phase | .timestamps.last_update=$now' "$STATE_FILE" >"$tmp" ||
    ! atomic_json_commit "$STATE_FILE" "$tmp"; then
    rm -f -- "$tmp"
    error "无法原子更新事务状态为 ${phase}；原状态文件保持不变。"
    return 1
  fi
  state_file_is_valid || { error "事务状态 ${phase} 写入后校验失败。"; return 1; }
}

state_managed_hash() {
  local path="$1"
  jq -er --arg path "$path" '.managed_files[] | select(.path == $path) | .sha256' "$STATE_FILE" 2>/dev/null || true
}

is_marker_managed_file() {
  local path="$1"
  [ -f "$path" ] && [ ! -L "$path" ] && [ "$(stat -c '%u' "$path")" = '0' ] && grep -Fq "$MANAGED_MARKER" "$path"
}

assert_owned_file() {
  local path="$1" expected actual phase=''
  is_marker_managed_file "$path" || die "$EXIT_CONFLICT" "拒绝操作非本项目文件：${path}"
  expected="$(state_managed_hash "$path")"
  if [ -z "$expected" ]; then
    phase="$(state_get '.state' 2>/dev/null || true)"
    case "$phase" in
      PREPARED | DEGRADED | ROLLBACK_PENDING) return 0 ;;
      *) die "$EXIT_CONFLICT" "状态中没有文件所有权记录：${path}" ;;
    esac
  fi
  actual="$(sha256sum "$path" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die "$EXIT_CONFLICT" "管理文件已被外部修改：${path}"
}

check_managed_paths() {
  local path
  if state_exists; then
    validate_state_file
    for path in "$SYSCTL_FILE" "$JOURNAL_FILE" "$FQ_HELPER" "$FQ_SERVICE" "$XUI_DROPIN"; do
      if [ -e "$path" ] || [ -L "$path" ]; then
        assert_owned_file "$path"
      fi
    done
  else
    if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
      die "$EXIT_CONFLICT" "状态目录存在但没有有效状态：${STATE_DIR}"
    fi
    for path in "$SYSCTL_FILE" "$JOURNAL_FILE" "$FQ_HELPER" "$FQ_SERVICE" "$XUI_DROPIN"; do
      if [ -e "$path" ] || [ -L "$path" ]; then
        die "$EXIT_CONFLICT" "目标路径已存在且不属于本项目：${path}"
      fi
    done
  fi
  if [ -e "$SWAP_FILE" ] && ! state_exists; then
    die "$EXIT_CONFLICT" "${SWAP_FILE} 已存在；脚本不会接管或覆盖。"
  fi
}

check_preflight_state() {
  state_exists || return 0
  local phase
  phase="$(state_get '.state')"
  if [ "$UPDATE_PREFLIGHT" = '1' ]; then
    case "$phase" in
      VERIFIED | APPLIED)
        info "检测到现有管理状态 ${phase}；进入只读 update-preflight，不执行任何系统写入。"
        return 0
        ;;
      *)
        die "$EXIT_CONFLICT" "update-preflight 只接受 VERIFIED/APPLIED；当前状态 ${phase} 必须先按现有版本处理。"
        ;;
    esac
  fi
  case "$phase" in
    VERIFIED | APPLIED)
      die "$EXIT_CONFLICT" "检测到现有管理状态 ${phase}；已安装配置请执行 verify。仅变更服务商端口带宽时请使用 reconfigure；其他参数仍需用 PURGE_CREATED_SWAP=1 执行 rollback，重启后再用新参数执行 preflight/apply。"
      ;;
    SWAP_RETAINED)
      die "$EXIT_CONFLICT" '检测到 SWAP_RETAINED；重新应用前请用 PURGE_CREATED_SWAP=1 执行 rollback。'
      ;;
    RECONFIGURING)
      die "$EXIT_CONFLICT" '检测到未完成的带宽重配置事务；请先执行 recover，不要直接 apply。'
      ;;
    DEGRADED)
      if jq -e '.reconfigure | type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
        die "$EXIT_CONFLICT" '检测到带宽重配置恢复失败后的 DEGRADED 状态；请先执行 recover，不要直接 apply。'
      fi
      die "$EXIT_CONFLICT" '检测到 DEGRADED；请先按现有版本执行 rollback，不要直接 apply。'
      ;;
    *)
      die "$EXIT_CONFLICT" "检测到未完成的事务状态 ${phase}；请先执行 rollback，不要直接 apply。"
      ;;
  esac
}

report_sysctl_conflicts() {
  local key file found=0 escaped canonical managed_canonical provider_file expected count
  local -a files=()
  declare -A seen=()

  PROVIDER_SYSCTL_TRANSFER_REQUIRED=0
  provider_file="${SYSCTL_SCAN_ROOT}/sysctl.conf"

  shopt -s nullglob
  files=("${SYSCTL_SCAN_ROOT}/sysctl.conf" "${SYSCTL_SCAN_ROOT}/sysctl.d/"*.conf)
  shopt -u nullglob

  managed_canonical="$(readlink -f "$SYSCTL_FILE" 2>/dev/null || printf '%s' "$SYSCTL_FILE")"
  for file in "${files[@]}"; do
    [ -f "$file" ] || continue
    canonical="$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")"
    [ "$file" = "$SYSCTL_FILE" ] && continue
    [ "$canonical" = "$managed_canonical" ] && continue
    [ -z "${seen[$canonical]:-}" ] || continue
    seen["$canonical"]=1
    for key in "${PROFILE_SYSCTL_KEYS[@]}"; do
      escaped="${key//./\\.}"
      if grep -Eq "^[[:space:]]*${escaped}[[:space:]]*=" "$file"; then
        expected=''
        case "$key" in
          net.core.default_qdisc) expected='fq' ;;
          net.ipv4.tcp_congestion_control) expected='bbr' ;;
        esac
        count="$(grep -Ec "^[[:space:]]*${escaped}[[:space:]]*=" "$file")"
        if [ "$file" = "$provider_file" ] && [ -n "$expected" ] && [ "$count" -eq 1 ] &&
          [ ! -L "$file" ] && [ "$(stat -c '%u' "$file" 2>/dev/null || true)" = '0' ] &&
          grep -Eq "^[[:space:]]*${escaped}[[:space:]]*=[[:space:]]*${expected}[[:space:]]*$" "$file"; then
          PROVIDER_SYSCTL_TRANSFER_REQUIRED=1
          warn "检测到可迁移的厂商 sysctl 基线：${key} = ${expected}（${file}）。"
        else
          error "sysctl 冲突：${key} 已在 ${file} 中定义；仅 /etc/sysctl.conf 中唯一且值严格为 fq/bbr 的厂商基线可由 apply 事务化迁移。"
          found=1
        fi
      fi
    done
  done
  if [ "$found" -eq 0 ] && [ "$PROVIDER_SYSCTL_TRANSFER_REQUIRED" -eq 1 ]; then
    warn "preflight 保持只读；apply 将完整备份 ${provider_file}，再把上述配置归属迁移到 ${SYSCTL_FILE}。"
  fi
  [ "$found" -eq 0 ]
}

scan_sysctl_conflicts() {
  if ! report_sysctl_conflicts; then
    die "$EXIT_CONFLICT" '存在不能安全自动迁移的重复 sysctl 定义；请人工确认其归属和目标值。'
  fi
}

default_route_ifaces() {
  {
    ip -o -4 route show default 2>/dev/null || true
    ip -o -6 route show default 2>/dev/null || true
  } | awk '{for(i=1;i<=NF;i++) if($i=="dev" && (i+1)<=NF) print $(i+1)}' | awk 'NF && !seen[$0]++'
}

policy_rule_state() {
  local family="$1" rules
  if ! rules="$(ip "-${family}" rule show 2>/dev/null)"; then
    printf '%s\n' unavailable
    return 0
  fi
  if awk '
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^0:[[:space:]]+from all lookup (local|255)([[:space:]]+proto kernel)?$/) next
      if (line ~ /^32766:[[:space:]]+from all lookup (main|254)([[:space:]]+proto kernel)?$/) next
      if (line ~ /^32767:[[:space:]]+from all lookup (default|253)([[:space:]]+proto kernel)?$/) next
      if (line != "") custom=1
    }
    END {exit custom ? 0 : 1}
  ' <<<"$rules"; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
}

detect_policy_routing() {
  POLICY_ROUTING_IPV4_STATE="$(policy_rule_state 4)"
  POLICY_ROUTING_IPV6_STATE="$(policy_rule_state 6)"
}

show_policy_routing_evidence() {
  printf '[policy-routing-ipv4-rules]\n'
  ip -4 rule show 2>/dev/null || printf '%s\n' 'unavailable'
  printf '[policy-routing-ipv6-rules]\n'
  ip -6 rule show 2>/dev/null || printf '%s\n' 'unavailable'
  if [ "$POLICY_ROUTING_IPV4_STATE" = true ]; then
    printf '[policy-routing-ipv4-routes-all]\n'
    ip -4 route show table all 2>/dev/null || printf '%s\n' 'unavailable'
  fi
  if [ "$POLICY_ROUTING_IPV6_STATE" = true ]; then
    printf '[policy-routing-ipv6-routes-all]\n'
    ip -6 route show table all 2>/dev/null || printf '%s\n' 'unavailable'
  fi
  printf '[policy-routing-summary] custom_ipv4=%s custom_ipv6=%s interface_discovery=conventional-default-routes-only\n' \
    "$POLICY_ROUTING_IPV4_STATE" "$POLICY_ROUTING_IPV6_STATE"
  if [ "$POLICY_ROUTING_IPV4_STATE" = true ] || [ "$POLICY_ROUTING_IPV6_STATE" = true ]; then
    warn '检测到自定义策略路由规则；本项目只按常规默认路由发现网卡，当前证据不证明该拓扑可安全 apply。'
  elif [ "$POLICY_ROUTING_IPV4_STATE" = unavailable ] || [ "$POLICY_ROUTING_IPV6_STATE" = unavailable ]; then
    warn '至少一个地址族的策略路由规则不可读；不能确认是否只有内核默认规则。'
  fi
  return 0
}

kernel_feature_available() {
  local module="$1" config_key="$2"
  [ -d "/sys/module/${module}" ] || modinfo "$module" >/dev/null 2>&1 ||
    grep -Eq "^${config_key}=[ym]$" "/boot/config-$(uname -r)" 2>/dev/null
}

check_bbr_fq_capability() {
  local available current_qdisc
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if [[ " $available " != *' bbr '* ]] && ! kernel_feature_available tcp_bbr CONFIG_TCP_CONG_BBR; then
    die "$EXIT_UNSUPPORTED" '当前内核没有暴露或提供 tcp_bbr。'
  fi
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  if [ "$current_qdisc" != 'fq' ] && ! kernel_feature_available sch_fq CONFIG_NET_SCH_FQ; then
    die "$EXIT_UNSUPPORTED" '当前内核没有暴露或提供 sch_fq。'
  fi
}

qdisc_snapshot_for_iface() {
  local iface="$1"
  tc -j qdisc show dev "$iface" | jq --arg iface "$iface" '{interface:$iface,qdiscs:.}'
}

mq_root_handle_from_snapshot() {
  local snapshot="$1"
  jq -er '
    def qdiscs: if type == "array" then . else .qdiscs end;
    [qdiscs[] | select(.root == true and .kind == "mq")] as $roots |
    if ($roots | length) == 1 then ($roots[0].handle // "")
    else error("expected exactly one mq root") end
  ' <<<"$snapshot"
}

mq_root_major_from_snapshot() {
  local snapshot="$1" handle major
  handle="$(mq_root_handle_from_snapshot "$snapshot")" || return 1
  case "$handle" in
    '' | '0:') printf '0\n' ;;
    *:)
      major="${handle%:}"
      [[ "$major" =~ ^[0-9A-Fa-f]+$ ]] || return 1
      printf '%s\n' "${major,,}"
      ;;
    *) return 1 ;;
  esac
}

mq_parent_minor() {
  local root_major="$1" parent="$2" minor
  if [ "$root_major" = '0' ]; then
    if [[ "$parent" =~ ^:([0-9A-Fa-f]+)$ ]] || [[ "$parent" =~ ^0:([0-9A-Fa-f]+)$ ]]; then
      minor="${BASH_REMATCH[1]}"
    else
      return 1
    fi
  elif [[ "$parent" =~ ^${root_major}:([0-9A-Fa-f]+)$ ]]; then
    minor="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  printf '%s\n' "${minor,,}"
}

mq_leaf_rows_from_snapshot() {
  local snapshot="$1" root_major="$2" kind parent minor
  while IFS=$'\t' read -r kind parent; do
    kind="${kind%$'\r'}"
    parent="${parent%$'\r'}"
    [ -n "$kind" ] && [ -n "$parent" ] || continue
    if minor="$(mq_parent_minor "$root_major" "$parent")"; then
      printf '%s\t%s\t%s\n' "$minor" "$kind" "$parent"
    fi
  done < <(jq -r '
    def qdiscs: if type == "array" then . else .qdiscs end;
    qdiscs[] | select(has("parent")) | [(.kind // ""), (.parent // "")] | @tsv
  ' <<<"$snapshot")
}

mq_leaf_minors_from_rows() {
  jq -Rsc '[splits("\n") | select(length > 0) | split("\t")[0]] | sort' <<<"$1"
}

mq_leaf_rows_are_supported() {
  local rows="$1"
  [ -n "$rows" ] || return 1
  awk -F '\t' '
    NF >= 3 {
      count++
      if (seen[$1]++) duplicate=1
      if ($2 != "fq" && $2 != "fq_codel") unsupported=1
    }
    END {exit !(count > 0 && !duplicate && !unsupported)}
  ' <<<"$rows"
}

mq_select_free_major_from_snapshot() {
  local snapshot="$1" candidate
  for candidate in 1 2 3 4 5 6 7 8 d18 d19 d1a d1b; do
    if ! jq -e --arg handle "${candidate}:" '
      def qdiscs: if type == "array" then . else .qdiscs end;
      any(qdiscs[]; (.handle // "") == $handle)
    ' <<<"$snapshot" >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_addressable_mq_root() {
  local iface="$1" expected_minors="$2" snapshot root_major selected rows current_minors
  snapshot="$(qdisc_snapshot_for_iface "$iface")" || return 1
  root_major="$(mq_root_major_from_snapshot "$snapshot")" || return 1
  if [ "$root_major" != '0' ]; then
    printf '%s\n' "$root_major"
    return 0
  fi
  selected="$(mq_select_free_major_from_snapshot "$snapshot")" || {
    error "${iface}: 无法为 mq 选择无冲突的非零 root handle。"
    return 1
  }
  # 内核自建 mq 0: 的 :N parent 可显示但不可可靠寻址；重建 root 会重建叶子，
  # 所以调用方必须先限定可无损处理的拓扑，并在下方重新读取和核对队列集合。
  if ! tc qdisc replace dev "$iface" root handle "${selected}:" mq; then
    error "${iface}: 无法把内核自建 mq 0: 转换为可寻址的 mq ${selected}:。"
    return 1
  fi
  snapshot="$(qdisc_snapshot_for_iface "$iface")" || return 1
  root_major="$(mq_root_major_from_snapshot "$snapshot")" || return 1
  [ "$root_major" = "$selected" ] || {
    error "${iface}: mq root handle 规范化后不是预期的 ${selected}:。"
    return 1
  }
  rows="$(mq_leaf_rows_from_snapshot "$snapshot" "$root_major")"
  mq_leaf_rows_are_supported "$rows" || {
    error "${iface}: mq root handle 规范化后叶子缺失、重复或类型不受支持。"
    return 1
  }
  current_minors="$(mq_leaf_minors_from_rows "$rows")"
  [ "$current_minors" = "$expected_minors" ] || {
    error "${iface}: mq root handle 规范化改变了发送队列 minor 集合。"
    return 1
  }
  printf '%s\n' "$root_major"
}

is_conventional_pfifo_fast_snapshot() {
  jq -e '
    (.qdiscs | length) == 1 and
    (.qdiscs[0].root == true) and
    (.qdiscs[0].kind == "pfifo_fast") and
    ((.qdiscs[0].options // {}) |
      ((keys - ["bands", "multiqueue", "priomap"]) | length) == 0 and
      ((.bands // 3) == 3) and
      ((.multiqueue // false) == false) and
      ((has("priomap") | not) or
       .priomap == [1,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1]))
  ' <<<"$1" >/dev/null 2>&1
}

validate_qdisc_topology() {
  local iface snapshot root_kind root_major rows unsupported leaf_count unknown_options
  local fq_count fq_codel_count parent options
  mapfile -t IFACES < <(default_route_ifaces)
  [ "${#IFACES[@]}" -gt 0 ] || die "$EXIT_UNSUPPORTED" '没有发现常规 IPv4 或 IPv6 默认路由网卡。'

  for iface in "${IFACES[@]}"; do
    snapshot="$(qdisc_snapshot_for_iface "$iface")" || die "$EXIT_UNSUPPORTED" "无法读取 ${iface} 的 qdisc。"
    root_kind="$(jq -r '.qdiscs[] | select(.root == true) | .kind' <<<"$snapshot" | head -n1)"
    case "$root_kind" in
      fq) info "${iface}: 根 qdisc 已是 fq。" ;;
      fq_codel)
        unknown_options="$(jq -r '[.qdiscs[] | select(.root == true and .kind == "fq_codel") | .options // {} | keys[] | select(. != "limit" and . != "flows" and . != "quantum" and . != "target" and . != "interval" and . != "memory_limit" and . != "ecn" and . != "ce_threshold" and . != "drop_batch")] | unique | join(",")' <<<"$snapshot")"
        [ -z "$unknown_options" ] || die "$EXIT_UNSUPPORTED" "${iface}: fq_codel 含有无法可靠恢复的选项：${unknown_options}"
        info "${iface}: 支持从根 fq_codel 切换到 fq。"
        ;;
      pfifo_fast)
        is_conventional_pfifo_fast_snapshot "$snapshot" ||
          die "$EXIT_UNSUPPORTED" "${iface}: pfifo_fast 不是可无损恢复的常规默认拓扑。"
        info "${iface}: 支持从常规根 pfifo_fast 切换到 fq，并在 rollback 时恢复。"
        ;;
      noqueue) warn "${iface}: 根 qdisc 为 noqueue，将跳过即时替换。" ;;
      mq)
        root_major="$(mq_root_major_from_snapshot "$snapshot")" ||
          die "$EXIT_UNSUPPORTED" "${iface}: mq root handle 无法解析。"
        rows="$(mq_leaf_rows_from_snapshot "$snapshot" "$root_major")"
        mq_leaf_rows_are_supported "$rows" ||
          die "$EXIT_UNSUPPORTED" "${iface}: mq 叶子缺失、重复、父句柄不匹配或类型不受支持。"
        leaf_count="$(awk -F '\t' 'NF >= 3 {count++} END {print count+0}' <<<"$rows")"
        [ "$leaf_count" -gt 0 ] || die "$EXIT_UNSUPPORTED" "${iface}: mq 没有可识别的叶子 qdisc。"
        unsupported="$(awk -F '\t' '$2 != "fq" && $2 != "fq_codel" {print $2}' <<<"$rows" | sort -u)"
        [ -z "$unsupported" ] || die "$EXIT_UNSUPPORTED" "${iface}: mq 包含不支持的叶子 qdisc：${unsupported}"
        fq_count="$(awk -F '\t' '$2 == "fq" {count++} END {print count+0}' <<<"$rows")"
        fq_codel_count="$(awk -F '\t' '$2 == "fq_codel" {count++} END {print count+0}' <<<"$rows")"
        if [ "$root_major" = '0' ] && [ "$fq_count" -gt 0 ] && [ "$fq_codel_count" -gt 0 ]; then
          die "$EXIT_UNSUPPORTED" "${iface}: mq 0: 混合 fq/fq_codel；规范化 root 会重建叶子，无法证明既有 fq 参数可无损保留。"
        fi
        unknown_options=''
        while IFS=$'\t' read -r _ kind parent; do
          [ "$kind" = 'fq_codel' ] || continue
          options="$(jq -r --arg parent "$parent" '
            [.qdiscs[] | select(.parent == $parent and .kind == "fq_codel") |
             (.options // {}) | keys[] |
             select(. != "limit" and . != "flows" and . != "quantum" and
                    . != "target" and . != "interval" and . != "memory_limit" and
                    . != "ecn" and . != "ce_threshold" and . != "drop_batch")] |
            unique | join(",")
          ' <<<"$snapshot")"
          [ -z "$options" ] || unknown_options="${unknown_options}${unknown_options:+,}${options}"
        done <<<"$rows"
        [ -z "$unknown_options" ] || die "$EXIT_UNSUPPORTED" "${iface}: mq 叶子含有无法可靠恢复的选项：${unknown_options}"
        if [ "$root_major" = '0' ] && [ "$fq_codel_count" -gt 0 ]; then
          mq_select_free_major_from_snapshot "$snapshot" >/dev/null ||
            die "$EXIT_UNSUPPORTED" "${iface}: mq 0: 没有可用的非零 root handle。"
          info "${iface}: apply 将先把 mq 0: 规范化为可寻址的非零 handle，再应用 fq 叶子。"
        else
          info "${iface}: 将保留 mq 根，仅对需要的叶子应用 fq。"
        fi
        ;;
      '') die "$EXIT_UNSUPPORTED" "${iface}: 无法识别根 qdisc。" ;;
      *) die "$EXIT_UNSUPPORTED" "${iface}: 不支持自动修改复杂根 qdisc ${root_kind}。" ;;
    esac
  done
}

check_swap_preconditions() {
  [ "$ENABLE_SWAP" = '1' ] || return 0
  # 消费完整列表，避免合法的长路径列表在 pipefail 下触发上游 SIGPIPE。
  if swapon --show=NAME --noheadings 2>/dev/null | grep '[^[:space:]]' >/dev/null; then
    info '系统已有活动 swap，不会创建新的 swap。'
    return 0
  fi

  ROOT_FS_TYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  [ -n "$ROOT_FS_TYPE" ] || ROOT_FS_TYPE='unknown'
  case "$ROOT_FS_TYPE" in
    ext2 | ext3 | ext4 | xfs)
      info "根文件系统为 ${ROOT_FS_TYPE}，允许创建普通 swap 文件。"
      ;;
    btrfs | zfs | overlay | overlayfs | nfs | nfs4 | fuse | fuse.*)
      SWAP_CREATE_ALLOWED='0'
      SWAP_SKIP_REASON="根文件系统 ${ROOT_FS_TYPE} 需要专用或不适合通用 swap-file 流程"
      warn "${SWAP_SKIP_REASON}；将跳过自动创建 swap。"
      return 0
      ;;
    *)
      SWAP_CREATE_ALLOWED='0'
      SWAP_SKIP_REASON="根文件系统 ${ROOT_FS_TYPE} 未经本项目验证"
      warn "${SWAP_SKIP_REASON}；将跳过自动创建 swap。"
      return 0
      ;;
  esac

  [ ! -e "$SWAP_FILE" ] || state_exists || die "$EXIT_CONFLICT" "${SWAP_FILE} 已存在且所有权未知。"
  local available_kib required_kib
  available_kib="$(df -Pk / | awk 'NR==2 {print $4}')"
  required_kib=$(((SWAP_MB + SWAP_CREATE_RESERVE_MIB) * 1024))
  [ "$available_kib" -ge "$required_kib" ] ||
    die "$EXIT_UNSUPPORTED" "剩余空间不足以创建 ${SWAP_MB} MiB swap 并保留 ${SWAP_CREATE_RESERVE_MIB} MiB。"
}

show_environment() {
  local mem cpus
  cpus="$(nproc 2>/dev/null || printf '?')"
  mem="$(memory_mib)"
  info "脚本版本：${SCRIPT_VERSION}"
  info "配置档位：${PROFILE_ID} (${PROFILE_LABEL})"
  info "系统：${PRETTY_NAME:-unknown}"
  info "内核：$(uname -r)"
  info "CPU：${cpus} vCPU"
  info "内存：${mem} MiB"
  info "端口上限：${PORT_SPEED_MBPS} Mbps；目标 RTT：${BUFFER_TARGET_RTT_MS} ms"
  info "理论 BDP：${BUFFER_BDP_BYTES} 字节；${BUFFER_TARGET_NUMERATOR}/${BUFFER_TARGET_DENOMINATOR}×BDP 目标：${BUFFER_TARGET_BYTES} 字节"
  info "BUF_MAX：${BUF_MAX} 字节 (${BUF_MAX_MODE})"
  info "所选缓冲上限的理论线路覆盖：${BUFFER_COVERAGE_MS} ms"
  info "默认路由网卡：$(default_route_ifaces | paste -sd, -)"
  if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | sed 's/^/[ufw] /' || true
  else
    warn '未安装 ufw；调优脚本不会自动安装或配置防火墙。'
  fi
}

run_preflight() {
  local context="${1:-standalone}"
  ensure_required_tools
  check_supported_os
  validate_inputs
  check_resource_profile
  check_managed_paths
  [ "$context" = 'apply' ] || check_preflight_state
  scan_sysctl_conflicts
  check_bbr_fq_capability
  validate_qdisc_topology
  check_swap_preconditions
  show_environment
  if [ "$PROVIDER_SYSCTL_TRANSFER_REQUIRED" -eq 1 ]; then
    info "预检通过（PASS_WITH_PROVIDER_SYSCTL_TRANSFER）；apply 将在事务保护下迁移厂商 sysctl 配置归属；警告数：${WARNINGS}。"
  else
    info "预检通过；警告数：${WARNINGS}。"
  fi
}

write_qdisc_snapshot() {
  local snapshot_iface tmp
  tmp="$(mktemp)"
  if ! {
    for snapshot_iface in "${IFACES[@]}"; do
      qdisc_snapshot_for_iface "$snapshot_iface"
    done | jq -s . >"$tmp"
  } || [ ! -s "$tmp" ] ||
    ! jq -e 'type == "array" and length > 0 and all(.[];
      (.interface | type == "string") and (.interface | length > 0) and
      (.qdiscs | type == "array") and (.qdiscs | length > 0) and
      ([.qdiscs[] | select(.root == true)] | length == 1))' "$tmp" >/dev/null ||
    ! install -o root -g root -m 0600 "$tmp" "$QDISC_STATE_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
}

original_sysctls_json() {
  local key value
  for key in "${PROFILE_SYSCTL_KEYS[@]}"; do
    value="$(sysctl -n "$key")" || return 1
    printf '%s\t%s\n' "$key" "$value"
  done | jq -Rn '[inputs | split("\t") | {(.[0]): (.[1:] | join("\t"))}] | add'
}

write_initial_state() {
  local original qhash now tmp provider_file provider_backup provider_hash='' provider_uid=0 provider_gid=0 provider_mode='000'
  local provider_required=false provider_state='NOT_REQUIRED' provider_keys='[]'
  mkdir -- "$STATE_DIR" || return 1
  STATE_DIR_CREATED=1
  chmod 0700 "$STATE_DIR" || return 1
  write_qdisc_snapshot || return 1
  if ! original="$(original_sysctls_json)"; then
    error '无法采集原始 sysctl 状态。'
    return 1
  fi
  qhash="$(sha256sum "$QDISC_STATE_FILE" | awk '{print $1}')"
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  provider_file="${SYSCTL_SCAN_ROOT}/sysctl.conf"
  provider_backup="${STATE_DIR}/provider-sysctl.conf.original"
  if [ "$PROVIDER_SYSCTL_TRANSFER_REQUIRED" -eq 1 ]; then
    [ -f "$provider_file" ] && [ ! -L "$provider_file" ] || return 1
    provider_hash="$(sha256sum "$provider_file" | awk '{print $1}')" || return 1
    provider_uid="$(stat -c '%u' "$provider_file")" || return 1
    provider_gid="$(stat -c '%g' "$provider_file")" || return 1
    provider_mode="$(stat -c '%a' "$provider_file")" || return 1
    provider_required=true
    provider_state='DETECTED'
    if grep -Eq '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$' "$provider_file"; then
      provider_keys="$(jq -c '. + [{key:"net.core.default_qdisc",value:"fq"}]' <<<"$provider_keys")" || return 1
    fi
    if grep -Eq '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$' "$provider_file"; then
      provider_keys="$(jq -c '. + [{key:"net.ipv4.tcp_congestion_control",value:"bbr"}]' <<<"$provider_keys")" || return 1
    fi
    [ "$(jq 'length' <<<"$provider_keys")" -gt 0 ] || return 1
  fi
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! jq -n \
    --argjson schema "$STATE_SCHEMA_VERSION" --arg version "$SCRIPT_VERSION" \
    --arg profile "$PROFILE_ID" --arg profile_label "$PROFILE_LABEL" \
    --arg debian "$TARGET_DEBIAN_VERSION" --arg arch "$(uname -m)" \
    --arg os_id "$TARGET_OS_ID" --arg os_version "$TARGET_OS_VERSION" \
    --arg kernel "$(uname -r)" --argjson mem "$(memory_mib)" \
    --argjson port "$PORT_SPEED_MBPS" --argjson rtt "$BUFFER_TARGET_RTT_MS" \
    --argjson buf "$BUF_MAX" --arg mode "$BUF_MAX_MODE" \
    --argjson target_numerator "$BUFFER_TARGET_NUMERATOR" \
    --argjson target_denominator "$BUFFER_TARGET_DENOMINATOR" \
    --arg qfile "$QDISC_STATE_FILE" --arg qhash "$qhash" --arg now "$now" \
    --argjson original "$original" --argjson provider_required "$provider_required" \
    --arg provider_file "$provider_file" --arg provider_backup "$provider_backup" \
    --arg provider_hash "$provider_hash" --argjson provider_uid "$provider_uid" \
    --argjson provider_gid "$provider_gid" --arg provider_mode "$provider_mode" \
    --arg provider_state "$provider_state" --argjson provider_keys "$provider_keys" \
    '{schema_version:$schema,script_version:$version,state:"PREPARED",
      profile:{id:$profile,label:$profile_label,os_id:$os_id,os_version:$os_version,debian_version:(if $os_id=="debian" then $debian else null end),architecture:$arch,kernel_release:$kernel,memory_mib:$mem},
       network:{port_speed_mbps:$port,target_rtt_ms:$rtt,buffer_target_numerator:$target_numerator,buffer_target_denominator:$target_denominator,buffer_max_bytes:$buf,buffer_mode:$mode},
       original_sysctls:$original,qdisc:{file:$qfile,sha256:$qhash},
       swap:{created_by_script:false,path:"/swapfile-proxy",size_mib:0,device:0,inode:0,active:false},
       provider_sysctl_transfer:{required:$provider_required,source_path:$provider_file,backup_path:$provider_backup,
         original_sha256:(if $provider_required then $provider_hash else null end),backup_sha256:null,transferred_sha256:null,
          original_uid:(if $provider_required then $provider_uid else null end),
          original_gid:(if $provider_required then $provider_gid else null end),
          original_mode:(if $provider_required then $provider_mode else null end),
          keys:$provider_keys,state:$provider_state},
       managed_files:[],timestamps:{prepared:$now,last_update:$now}}' >"$tmp" ||
    ! atomic_json_commit "$STATE_FILE" "$tmp"; then
    rm -f -- "$tmp"
    error '无法创建有效的初始事务状态；未提交空状态文件。'
    return 1
  fi
  state_file_is_valid || { error '初始事务状态写入后校验失败。'; return 1; }
}

set_provider_sysctl_transfer_state() {
  local phase="$1" backup_hash="$2" transferred_hash="$3" tmp
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! jq --arg phase "$phase" --arg backup_hash "$backup_hash" --arg transferred_hash "$transferred_hash" \
    --arg now "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '
      .provider_sysctl_transfer.state=$phase |
      .provider_sysctl_transfer.backup_sha256=(if $backup_hash == "" then null else $backup_hash end) |
      .provider_sysctl_transfer.transferred_sha256=(if $transferred_hash == "" then null else $transferred_hash end) |
      .timestamps.last_update=$now
    ' "$STATE_FILE" >"$tmp" || ! atomic_json_commit "$STATE_FILE" "$tmp"; then
    rm -f -- "$tmp"
    error "无法记录厂商 sysctl 归属迁移状态 ${phase}。"
    return 1
  fi
  state_file_is_valid || { error "厂商 sysctl 归属迁移状态 ${phase} 校验失败。"; return 1; }
}

transfer_provider_sysctl_ownership() {
  state_get '.provider_sysctl_transfer.required' | grep -qx true || return 0
  local source backup original_hash current_hash backup_hash transferred_hash uid gid mode tmp
  source="$(state_get '.provider_sysctl_transfer.source_path')"
  backup="$(state_get '.provider_sysctl_transfer.backup_path')"
  original_hash="$(state_get '.provider_sysctl_transfer.original_sha256')"
  uid="$(state_get '.provider_sysctl_transfer.original_uid')"
  gid="$(state_get '.provider_sysctl_transfer.original_gid')"
  mode="$(state_get '.provider_sysctl_transfer.original_mode')"

  [ -f "$source" ] && [ ! -L "$source" ] || { error "厂商 sysctl 文件类型已变化：${source}"; return 1; }
  current_hash="$(sha256sum "$source" | awk '{print $1}')" || return 1
  [ "$current_hash" = "$original_hash" ] || { error "${source} 在 preflight 后发生变化，拒绝迁移。"; return 1; }
  [ ! -e "$backup" ] && [ ! -L "$backup" ] || { error "厂商 sysctl 备份路径已存在：${backup}"; return 1; }
  install -o root -g root -m 0600 "$source" "$backup" || return 1
  backup_hash="$(sha256sum "$backup" | awk '{print $1}')" || return 1
  [ "$backup_hash" = "$original_hash" ] || { error '厂商 sysctl 备份哈希与原文件不一致。'; return 1; }

  tmp="$(mktemp "${source}.proxy-vps.tmp.XXXXXX")" || return 1
  if ! awk '
    /^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$/ {
      print "# proxy-vps-tuning: ownership transferred to /etc/sysctl.d/90-proxy-vps.conf"
      print "# original: " $0
      next
    }
    /^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$/ {
      print "# proxy-vps-tuning: ownership transferred to /etc/sysctl.d/90-proxy-vps.conf"
      print "# original: " $0
      next
    }
    { print }
  ' "$source" >"$tmp" || ! chmod "$mode" "$tmp" || ! chown "${uid}:${gid}" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  transferred_hash="$(sha256sum "$tmp" | awk '{print $1}')" || { rm -f -- "$tmp"; return 1; }
  [ "$transferred_hash" != "$original_hash" ] || { rm -f -- "$tmp"; error '厂商 sysctl 迁移没有产生预期变更。'; return 1; }

  set_provider_sysctl_transfer_state 'PLANNED' "$backup_hash" "$transferred_hash" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$source" || { rm -f -- "$tmp"; return 1; }
  current_hash="$(sha256sum "$source" | awk '{print $1}')" || return 1
  [ "$current_hash" = "$transferred_hash" ] || { error '厂商 sysctl 迁移后哈希不匹配。'; return 1; }
  set_provider_sysctl_transfer_state 'TRANSFERRED' "$backup_hash" "$transferred_hash" || return 1
  info "已备份并迁移厂商 sysctl 配置归属：${source}；备份：${backup}。"
}

cleanup_uncommitted_state() {
  [ "$STATE_DIR_CREATED" -eq 1 ] || return 1
  [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 1
  rm -f -- "$QDISC_STATE_FILE" "${STATE_FILE}.tmp."*
  rmdir -- "$STATE_DIR"
}

write_managed_file() {
  local path="$1" mode="$2" dir
  dir="$(dirname "$path")"
  mkdir -p "$dir" || return 1
  local tmp
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  if ! cat >"$tmp" || ! chmod "$mode" "$tmp" || ! chown root:root "$tmp" ||
    ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

refresh_managed_files() {
  local path json='[]' hash tmp
  for path in "$SYSCTL_FILE" "$JOURNAL_FILE" "$FQ_HELPER" "$FQ_SERVICE" "$XUI_DROPIN"; do
    [ -f "$path" ] || continue
    hash="$(sha256sum "$path" | awk '{print $1}')"
    if ! json="$(jq -c --arg path "$path" --arg hash "$hash" '. + [{path:$path,sha256:$hash}]' <<<"$json")"; then
      error '无法构造 managed_files 状态。'
      return 1
    fi
  done
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! jq --argjson files "$json" '.managed_files=$files' "$STATE_FILE" >"$tmp" ||
    ! atomic_json_commit "$STATE_FILE" "$tmp"; then
    rm -f -- "$tmp"
    error '无法原子更新 managed_files；原状态文件保持不变。'
    return 1
  fi
  state_file_is_valid || { error 'managed_files 更新后状态校验失败。'; return 1; }
}

render_sysctl_profile() {
  cat <<EOF_SYSCTL
${MANAGED_MARKER}
# ${PROFILE_LABEL}; provider cap ${PORT_SPEED_MBPS} Mbps; target RTT ${BUFFER_TARGET_RTT_MS} ms.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = ${BUF_MAX}
net.core.wmem_max = ${BUF_MAX}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 131072 ${BUF_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${BUF_MAX}
net.core.netdev_max_backlog = 4096
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
vm.swappiness = 20
EOF_SYSCTL
}

write_sysctl_profile() {
  render_sysctl_profile | write_managed_file "$SYSCTL_FILE" 0644
}

write_journal_profile() {
  write_managed_file "$JOURNAL_FILE" 0644 <<EOF_JOURNAL || return 1
${MANAGED_MARKER}
[Journal]
SystemMaxUse=${JOURNAL_SYSTEM_MAX_USE}
SystemKeepFree=${JOURNAL_SYSTEM_KEEP_FREE}
RuntimeMaxUse=${JOURNAL_RUNTIME_MAX_USE}
EOF_JOURNAL
}

write_xui_dropin() {
  write_managed_file "$XUI_DROPIN" 0644 <<EOF_XUI || return 1
${MANAGED_MARKER}
[Service]
LimitNOFILE=${XUI_NOFILE_LIMIT}
EOF_XUI
}

write_fq_helper() {
  write_managed_file "$FQ_HELPER" 0755 <<'EOF_HELPER' || return 1
#!/usr/bin/env bash
# Managed by debian-vps-tuning; namespace=proxy-vps
set -Eeuo pipefail
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
fq_error() { printf '[proxy-vps-fq] %s\n' "$*" >&2; }
qdisc_snapshot_for_iface() {
  local iface="$1"
  tc -j qdisc show dev "$iface" | jq --arg iface "$iface" '{interface:$iface,qdiscs:.}'
}
mq_root_handle_from_snapshot() {
  local snapshot="$1"
  jq -er '
    def qdiscs: if type == "array" then . else .qdiscs end;
    [qdiscs[] | select(.root == true and .kind == "mq")] as $roots |
    if ($roots | length) == 1 then ($roots[0].handle // "")
    else error("expected exactly one mq root") end
  ' <<<"$snapshot"
}
mq_root_major_from_snapshot() {
  local snapshot="$1" handle major
  handle="$(mq_root_handle_from_snapshot "$snapshot")" || return 1
  case "$handle" in
    '' | '0:') printf '0\n' ;;
    *:)
      major="${handle%:}"
      [[ "$major" =~ ^[0-9A-Fa-f]+$ ]] || return 1
      printf '%s\n' "${major,,}"
      ;;
    *) return 1 ;;
  esac
}
mq_parent_minor() {
  local root_major="$1" parent="$2" minor
  if [ "$root_major" = '0' ]; then
    if [[ "$parent" =~ ^:([0-9A-Fa-f]+)$ ]] || [[ "$parent" =~ ^0:([0-9A-Fa-f]+)$ ]]; then
      minor="${BASH_REMATCH[1]}"
    else
      return 1
    fi
  elif [[ "$parent" =~ ^${root_major}:([0-9A-Fa-f]+)$ ]]; then
    minor="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  printf '%s\n' "${minor,,}"
}
mq_leaf_rows_from_snapshot() {
  local snapshot="$1" root_major="$2" kind parent minor
  while IFS=$'\t' read -r kind parent; do
    kind="${kind%$'\r'}"
    parent="${parent%$'\r'}"
    [ -n "$kind" ] && [ -n "$parent" ] || continue
    if minor="$(mq_parent_minor "$root_major" "$parent")"; then
      printf '%s\t%s\t%s\n' "$minor" "$kind" "$parent"
    fi
  done < <(jq -r '
    def qdiscs: if type == "array" then . else .qdiscs end;
    qdiscs[] | select(has("parent")) | [(.kind // ""), (.parent // "")] | @tsv
  ' <<<"$snapshot")
}
mq_leaf_minors_from_rows() {
  jq -Rsc '[splits("\n") | select(length > 0) | split("\t")[0]] | sort' <<<"$1"
}
mq_leaf_rows_are_supported() {
  local rows="$1"
  [ -n "$rows" ] || return 1
  awk -F '\t' '
    NF >= 3 {
      count++
      if (seen[$1]++) duplicate=1
      if ($2 != "fq" && $2 != "fq_codel") unsupported=1
    }
    END {exit !(count > 0 && !duplicate && !unsupported)}
  ' <<<"$rows"
}
mq_select_free_major_from_snapshot() {
  local snapshot="$1" candidate
  for candidate in 1 2 3 4 5 6 7 8 d18 d19 d1a d1b; do
    if ! jq -e --arg handle "${candidate}:" '
      def qdiscs: if type == "array" then . else .qdiscs end;
      any(qdiscs[]; (.handle // "") == $handle)
    ' <<<"$snapshot" >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
ensure_addressable_mq_root() {
  local iface="$1" expected_minors="$2" snapshot root_major selected rows current_minors
  snapshot="$(qdisc_snapshot_for_iface "$iface")" || return 1
  root_major="$(mq_root_major_from_snapshot "$snapshot")" || return 1
  if [ "$root_major" != '0' ]; then
    printf '%s\n' "$root_major"
    return 0
  fi
  selected="$(mq_select_free_major_from_snapshot "$snapshot")" || {
    fq_error "${iface}: cannot select a collision-free mq root handle"
    return 1
  }
  # Kernel-created mq 0: parents are printable but not reliably addressable.
  # Replacing the root recreates leaves, so callers constrain scope and we re-read minors below.
  if ! tc qdisc replace dev "$iface" root handle "${selected}:" mq; then
    fq_error "${iface}: failed to make kernel-created mq 0: addressable"
    return 1
  fi
  snapshot="$(qdisc_snapshot_for_iface "$iface")" || return 1
  root_major="$(mq_root_major_from_snapshot "$snapshot")" || return 1
  [ "$root_major" = "$selected" ] || {
    fq_error "${iface}: mq root handle differs after normalization"
    return 1
  }
  rows="$(mq_leaf_rows_from_snapshot "$snapshot" "$root_major")"
  mq_leaf_rows_are_supported "$rows" || {
    fq_error "${iface}: invalid mq leaves after root normalization"
    return 1
  }
  current_minors="$(mq_leaf_minors_from_rows "$rows")"
  [ "$current_minors" = "$expected_minors" ] || {
    fq_error "${iface}: mq queue minors changed during root normalization"
    return 1
  }
  printf '%s\n' "$root_major"
}
apply_fq_to_mq() {
  local iface="$1" snapshot root_major rows expected_minors fq_count fq_codel_count
  local _ kind parent final_rows final_minors
  snapshot="$(qdisc_snapshot_for_iface "$iface")" || return 1
  root_major="$(mq_root_major_from_snapshot "$snapshot")" || return 1
  rows="$(mq_leaf_rows_from_snapshot "$snapshot" "$root_major")"
  mq_leaf_rows_are_supported "$rows" || {
    fq_error "${iface}: mq leaves are missing, duplicated, mismatched, or unsupported"
    return 1
  }
  expected_minors="$(mq_leaf_minors_from_rows "$rows")"
  fq_count="$(awk -F '\t' '$2 == "fq" {count++} END {print count+0}' <<<"$rows")"
  fq_codel_count="$(awk -F '\t' '$2 == "fq_codel" {count++} END {print count+0}' <<<"$rows")"
  [ "$fq_codel_count" -gt 0 ] || return 0
  if [ "$root_major" = '0' ]; then
    if [ "$fq_count" -gt 0 ]; then
      fq_error "${iface}: refusing to rebuild mixed fq/fq_codel leaves under mq 0:"
      return 1
    fi
    root_major="$(ensure_addressable_mq_root "$iface" "$expected_minors")" || return 1
    snapshot="$(qdisc_snapshot_for_iface "$iface")" || return 1
    rows="$(mq_leaf_rows_from_snapshot "$snapshot" "$root_major")"
  fi
  while IFS=$'\t' read -r _ kind parent; do
    [ "$kind" = 'fq_codel' ] || continue
    tc qdisc replace dev "$iface" parent "$parent" fq || return 1
  done <<<"$rows"
  snapshot="$(qdisc_snapshot_for_iface "$iface")" || return 1
  root_major="$(mq_root_major_from_snapshot "$snapshot")" || return 1
  final_rows="$(mq_leaf_rows_from_snapshot "$snapshot" "$root_major")"
  mq_leaf_rows_are_supported "$final_rows" || return 1
  final_minors="$(mq_leaf_minors_from_rows "$final_rows")"
  [ "$final_minors" = "$expected_minors" ] || return 1
  if awk -F '\t' 'NF >= 3 && $2 != "fq" {exit 1}' <<<"$final_rows"; then
    :
  else
    fq_error "${iface}: one or more mq leaves are not fq after apply"
    return 1
  fi
}
ifaces="$({ ip -o -4 route show default 2>/dev/null || true; ip -o -6 route show default 2>/dev/null || true; } |
  awk '{for(i=1;i<=NF;i++) if($i=="dev" && (i+1)<=NF) print $(i+1)}' | awk 'NF && !seen[$0]++')"
[ -n "$ifaces" ] || exit 0
while IFS= read -r iface; do
  [ -n "$iface" ] || continue
  root_kind="$(tc -j qdisc show dev "$iface" | jq -r '.[] | select(.root == true) | .kind' | head -n1)"
  case "$root_kind" in
    fq) ;;
    noqueue) ;;
    mq) apply_fq_to_mq "$iface" ;;
    fq_codel | pfifo_fast) tc qdisc replace dev "$iface" root fq ;;
    *) printf '[proxy-vps-fq] unsupported qdisc on %s: %s\n' "$iface" "$root_kind" >&2; exit 1 ;;
  esac
done <<<"$ifaces"
EOF_HELPER
  refresh_managed_files || return 1

  write_managed_file "$FQ_SERVICE" 0644 <<EOF_SERVICE || return 1
${MANAGED_MARKER}
[Unit]
Description=Apply fq to conventional default-route interfaces
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${FQ_HELPER}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  refresh_managed_files || return 1
}

apply_kernel_settings() {
  modprobe tcp_bbr >/dev/null 2>&1 || true
  modprobe sch_fq >/dev/null 2>&1 || true
  if ! sysctl -p "$SYSCTL_FILE" >/dev/null; then
    error "无法应用 ${SYSCTL_FILE}。"
    return 1
  fi
  if ! systemctl daemon-reload; then
    error 'systemctl daemon-reload 失败。'
    return 1
  fi
  if ! systemctl enable --now "$FQ_SERVICE_NAME" >/dev/null; then
    error "无法启用或运行 ${FQ_SERVICE_NAME}。"
    return 1
  fi
  if ! systemctl try-restart systemd-journald.service >/dev/null 2>&1; then
    warn 'systemd-journald 未能立即重启；配置将在服务下次启动时生效。'
  fi
}

state_set_swap_created() {
  local device inode tmp
  device="$(stat -c '%d' "$SWAP_FILE")"
  inode="$(stat -c '%i' "$SWAP_FILE")"
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! jq --argjson size "$SWAP_MB" --argjson device "$device" --argjson inode "$inode" \
    '.swap.created_by_script=true | .swap.size_mib=$size | .swap.device=$device | .swap.inode=$inode | .swap.active=true' "$STATE_FILE" >"$tmp" ||
    ! atomic_json_commit "$STATE_FILE" "$tmp"; then
    rm -f -- "$tmp"
    error '无法原子记录 swap 所有权；原状态文件保持不变。'
    return 1
  fi
  state_file_is_valid || { error 'swap 所有权更新后状态校验失败。'; return 1; }
}

ensure_fstab_swap_line() {
  local line="${SWAP_FILE} none swap sw 0 0"
  grep -Fqx "$line" /etc/fstab 2>/dev/null || printf '%s\n' "$line" >>/etc/fstab
  [ "$(grep -Fxc "$line" /etc/fstab)" -eq 1 ]
}

create_swap_if_needed() {
  [ "$ENABLE_SWAP" = '1' ] || return 0
  if [ "$SWAP_CREATE_ALLOWED" != '1' ]; then
    info "跳过自动创建 swap：${SWAP_SKIP_REASON:-根文件系统不在支持范围内}。"
    return 0
  fi
  if swapon --show=NAME --noheadings 2>/dev/null | grep '[^[:space:]]' >/dev/null; then return 0; fi
  [ ! -e "$SWAP_FILE" ] || die "$EXIT_CONFLICT" "${SWAP_FILE} 已存在，拒绝覆盖。"
  info "创建 ${SWAP_MB} MiB 应急 swap：${SWAP_FILE}"
  if command -v fallocate >/dev/null 2>&1 && fallocate -l "${SWAP_MB}M" "$SWAP_FILE"; then :; else
    rm -f -- "$SWAP_FILE"
    if ! dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_MB" status=none conv=fsync; then
      rm -f -- "$SWAP_FILE"
      die 1 'swap 文件分配失败。'
    fi
  fi
  if ! chmod 0600 "$SWAP_FILE" || ! mkswap "$SWAP_FILE" >/dev/null; then
    rm -f -- "$SWAP_FILE"
    die 1 'swap 初始化失败。'
  fi
  if ! swapon "$SWAP_FILE"; then
    warn 'fallocate 创建的 swap 未被文件系统接受，将使用 dd 重试。'
    rm -f -- "$SWAP_FILE"
    if ! dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_MB" status=none conv=fsync ||
      ! chmod 0600 "$SWAP_FILE" || ! mkswap "$SWAP_FILE" >/dev/null || ! swapon "$SWAP_FILE"; then
      swapoff "$SWAP_FILE" >/dev/null 2>&1 || true
      rm -f -- "$SWAP_FILE"
      die 1 '使用 dd 重试 swap 仍失败。'
    fi
  fi
  if ! state_set_swap_created; then
    swapoff "$SWAP_FILE" >/dev/null 2>&1 || true
    rm -f -- "$SWAP_FILE"
    die 1 '无法持久记录 swap 所有权，已撤销。'
  fi
  if ! ensure_fstab_swap_line; then
    swapoff "$SWAP_FILE" || true
    rm -f -- "$SWAP_FILE"
    die 1 '无法可靠写入 /etc/fstab，已撤销 swap。'
  fi
}

profile_service_units() {
  local unit
  if [ -n "$PROXY_SERVICE_UNITS_INPUT" ]; then
    IFS=' ' read -r -a units <<<"$PROXY_SERVICE_UNITS_INPUT"
    for unit in "${units[@]}"; do
      [[ "$unit" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || die "$EXIT_USAGE" "非法 systemd unit：${unit}"
      printf '%s\n' "$unit"
    done
  else
    printf '%s\n' "${DEFAULT_PROXY_SERVICE_UNITS[@]}"
  fi
}

read_nofile_limits() {
  local limits_file="$1"
  awk '$1 == "Max" && $2 == "open" && $3 == "files" {printf "%s\t%s\n", $4, $5; exit}' "$limits_file"
}

verify_runtime_nofile() {
  local unit="$1" process_label="$2" limits_file="$3" runtime_strict="$4" soft='' hard=''
  IFS=$'\t' read -r soft hard < <(read_nofile_limits "$limits_file")
  printf '[service] %s %s NOFILE soft=%s hard=%s\n' "$unit" "$process_label" "$soft" "$hard"
  if ! [[ "$soft" =~ ^[0-9]+$ ]] || [ "$soft" -lt "$XUI_NOFILE_LIMIT" ] ||
    ! [[ "$hard" =~ ^[0-9]+$ ]] || [ "$hard" -lt "$XUI_NOFILE_LIMIT" ]; then
    if [ "$unit" = 'x-ui.service' ] && [ "$runtime_strict" -eq 1 ]; then
      error "${unit} 的 ${process_label} 运行时 NOFILE soft/hard limit 未达到 ${XUI_NOFILE_LIMIT}。"
      return 1
    fi
    warn "${unit} 的 ${process_label} 运行时 NOFILE soft/hard limit 低于 ${XUI_NOFILE_LIMIT}；重启服务或主机后再验证。"
  fi
}

verify_proxy_services() {
  local unit loaded=0 active_count=0 active main_pid child strict=0 runtime_strict=0 failures=0 configured_soft configured_hard
  [ -z "$PROXY_SERVICE_UNITS_INPUT" ] || strict=1
  if [ "$strict" -eq 1 ] || [ "$REQUIRE_PROXY_SERVICE" = '1' ]; then runtime_strict=1; fi
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    [ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)" = 'loaded' ] || continue
    loaded=$((loaded + 1))
    active="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
    main_pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
    printf '[service] %s ActiveState=%s MainPID=%s\n' "$unit" "$active" "${main_pid:-0}"
    if [ "$unit" = 'x-ui.service' ]; then
      configured_soft="$(systemctl show -p LimitNOFILESoft --value "$unit" 2>/dev/null || true)"
      configured_hard="$(systemctl show -p LimitNOFILE --value "$unit" 2>/dev/null || true)"
      printf '[service] %s configured NOFILE soft=%s hard=%s\n' "$unit" "${configured_soft:-unknown}" "${configured_hard:-unknown}"
      if ! [[ "$configured_soft" =~ ^[0-9]+$ ]] || [ "$configured_soft" -lt "$XUI_NOFILE_LIMIT" ] ||
        ! [[ "$configured_hard" =~ ^[0-9]+$ ]] || [ "$configured_hard" -lt "$XUI_NOFILE_LIMIT" ]; then
        error "x-ui.service 的 systemd LimitNOFILE 未达到 ${XUI_NOFILE_LIMIT}。"
        failures=$((failures + 1))
      fi
    fi
    if [ "$active" != 'active' ]; then
      if [ "$strict" -eq 1 ]; then error "指定的服务未运行：${unit}"; failures=$((failures + 1)); else warn "检测到未运行的兼容服务：${unit}"; fi
      continue
    fi
    active_count=$((active_count + 1))
    if [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] && [ -r "/proc/${main_pid}/limits" ]; then
      verify_runtime_nofile "$unit" MainPID "/proc/${main_pid}/limits" "$runtime_strict" || failures=$((failures + 1))
      while IFS= read -r child; do
        [ -r "/proc/${child}/limits" ] || continue
        verify_runtime_nofile "$unit" "child=${child}" "/proc/${child}/limits" "$runtime_strict" || failures=$((failures + 1))
      done < <(pgrep -P "$main_pid" 2>/dev/null || true)
    fi
  done < <(profile_service_units)
  if [ "$loaded" -eq 0 ]; then
    if [ "$REQUIRE_PROXY_SERVICE" = '1' ]; then error '没有发现要求的代理服务。'; return 1; fi
    info '尚未安装代理服务；x-ui.service 的 LimitNOFILE drop-in 已预置，安装 3X-UI 后请重新 verify。'
  fi
  if [ "$REQUIRE_PROXY_SERVICE" = '1' ] && [ "$active_count" -eq 0 ]; then error '没有发现活动的目标代理服务。'; failures=$((failures + 1)); fi
  [ "$failures" -eq 0 ]
}

normalize_sysctl_value() {
  awk '{$1=$1; print}' <<<"$1"
}

managed_sysctl_value() {
  local key="$1"
  awk -F= -v k="$key" '{
    name=$1
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
    if (name == k) {
      value=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  }' "$SYSCTL_FILE"
}

verify_current_qdiscs() {
  local iface snapshot root_kind root_major rows bad failures=0
  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    snapshot="$(qdisc_snapshot_for_iface "$iface")" || { error "${iface}: 无法读取 qdisc。"; failures=$((failures + 1)); continue; }
    root_kind="$(jq -r '.qdiscs[] | select(.root == true) | .kind' <<<"$snapshot" | head -n1)"
    case "$root_kind" in
      fq) ;;
      noqueue) warn "${iface}: noqueue，未执行即时 fq 替换。" ;;
      mq)
        root_major="$(mq_root_major_from_snapshot "$snapshot")" || {
          error "${iface}: mq root handle 无法解析。"; failures=$((failures + 1)); continue; }
        rows="$(mq_leaf_rows_from_snapshot "$snapshot" "$root_major")"
        if ! mq_leaf_rows_are_supported "$rows"; then
          error "${iface}: mq 叶子缺失、重复、父句柄不匹配或类型不受支持。"
          failures=$((failures + 1))
          continue
        fi
        bad="$(awk -F '\t' '$2 != "fq" && !seen[$2]++ {values=(values ? values "," : "") $2} END {print values}' <<<"$rows")"
        if [ -n "$bad" ]; then error "${iface}: mq 叶子不是 fq：${bad}"; failures=$((failures + 1)); fi
        ;;
      *) error "${iface}: 实际根 qdisc 不是 fq：${root_kind:-missing}"; failures=$((failures + 1)) ;;
    esac
  done < <(default_route_ifaces)
  [ "$failures" -eq 0 ]
}

verify_provider_sysctl_transfer() {
  local required phase source backup expected actual key escaped failures=0
  required="$(state_get '.provider_sysctl_transfer.required')"
  phase="$(state_get '.provider_sysctl_transfer.state')"
  if [ "$required" != 'true' ]; then
    [ "$phase" = 'NOT_REQUIRED' ] || { error "厂商 sysctl 迁移状态异常：${phase}"; return 1; }
    return 0
  fi
  [ "$phase" = 'TRANSFERRED' ] || { error "厂商 sysctl 迁移尚未完成：${phase}"; return 1; }
  source="$(state_get '.provider_sysctl_transfer.source_path')"
  backup="$(state_get '.provider_sysctl_transfer.backup_path')"
  [ -f "$source" ] && [ ! -L "$source" ] || { error "厂商 sysctl 文件缺失或类型异常：${source}"; failures=$((failures + 1)); }
  [ -f "$backup" ] && [ ! -L "$backup" ] && [ "$(stat -c '%u' "$backup" 2>/dev/null || true)" = '0' ] || {
    error "厂商 sysctl 原始备份缺失或所有权异常：${backup}"; failures=$((failures + 1)); }
  if [ -f "$source" ] && [ ! -L "$source" ]; then
    expected="$(state_get '.provider_sysctl_transfer.transferred_sha256')"
    actual="$(sha256sum "$source" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || { error "厂商 sysctl 迁移后文件哈希不匹配：${source}"; failures=$((failures + 1)); }
  fi
  if [ -f "$backup" ] && [ ! -L "$backup" ]; then
    expected="$(state_get '.provider_sysctl_transfer.backup_sha256')"
    actual="$(sha256sum "$backup" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || { error "厂商 sysctl 备份哈希不匹配：${backup}"; failures=$((failures + 1)); }
    [ "$actual" = "$(state_get '.provider_sysctl_transfer.original_sha256')" ] || {
      error '厂商 sysctl 备份与原始哈希不一致。'; failures=$((failures + 1)); }
  fi
  while IFS= read -r key; do
    escaped="${key//./\\.}"
    if [ -f "$source" ] && grep -Eq "^[[:space:]]*${escaped}[[:space:]]*=" "$source"; then
      error "厂商 sysctl 中仍有已迁移键的有效定义：${key}"
      failures=$((failures + 1))
    fi
  done < <(jq -r '.provider_sysctl_transfer.keys[].key' "$STATE_FILE")
  [ "$failures" -eq 0 ]
}

verify_settings_common() {
  local failures=0 key expected actual qhash unit_path
  verify_provider_sysctl_transfer || failures=$((failures + 1))
  if ! report_sysctl_conflicts; then
    error '检测到本项目以外的重复 sysctl 配置归属；verify 拒绝通过。'
    failures=$((failures + 1))
  fi
  for key in "${PROFILE_SYSCTL_KEYS[@]}"; do
    expected="$(managed_sysctl_value "$key")"
    actual="$(sysctl -n "$key" 2>/dev/null || true)"
    expected="$(normalize_sysctl_value "$expected")"
    actual="$(normalize_sysctl_value "$actual")"
    [ "$actual" = "$expected" ] || { error "${key}: expected '${expected}', got '${actual}'"; failures=$((failures + 1)); }
  done
  qhash="$(sha256sum "$QDISC_STATE_FILE" | awk '{print $1}')"
  [ "$qhash" = "$(state_get '.qdisc.sha256')" ] || { error 'qdisc 原始状态文件哈希不匹配。'; failures=$((failures + 1)); }
  for key in "$SYSCTL_FILE" "$JOURNAL_FILE" "$FQ_HELPER" "$FQ_SERVICE" "$XUI_DROPIN"; do assert_owned_file "$key"; done
  unit_path="$(systemctl show -p FragmentPath --value "$FQ_SERVICE_NAME" 2>/dev/null || true)"
  [ "$(readlink -f "$unit_path" 2>/dev/null || true)" = "$(readlink -f "$FQ_SERVICE")" ] || {
    error 'fq helper 的 systemd FragmentPath 不匹配。'; failures=$((failures + 1)); }
  verify_current_qdiscs || failures=$((failures + 1))
  if state_get '.swap.created_by_script' | grep -qx true; then
    [ "$(stat -c '%d' "$SWAP_FILE" 2>/dev/null || true)" = "$(state_get '.swap.device')" ] || { error 'swap 设备号与所有权状态不匹配。'; failures=$((failures + 1)); }
    [ "$(stat -c '%i' "$SWAP_FILE" 2>/dev/null || true)" = "$(state_get '.swap.inode')" ] || { error 'swap inode 与所有权状态不匹配。'; failures=$((failures + 1)); }
    swapon --show=NAME --noheadings | awk '{$1=$1;print}' | grep -Fx -- "$SWAP_FILE" >/dev/null || { error '脚本创建的 swap 未激活。'; failures=$((failures + 1)); }
    grep -Fqx "${SWAP_FILE} none swap sw 0 0" /etc/fstab || { error 'swap 的 fstab 行缺失。'; failures=$((failures + 1)); }
  fi
  verify_proxy_services || failures=$((failures + 1))
  show_xray_socket_options
  [ "$failures" -eq 0 ] || return 1
}

verify_settings() {
  local phase verify_state_file="${1:-$STATE_FILE}"
  local STATE_FILE="$verify_state_file"
  state_exists || { error '当前主机尚未安装本项目配置；请先执行 preflight，确认通过后再执行 apply。'; return 1; }
  validate_state_file || return 1
  phase="$(state_get '.state')"
  [ "$phase" = 'APPLIED' ] || [ "$phase" = 'VERIFIED' ] || {
    error "当前状态不允许 verify：${phase}"; return 1; }
  if jq -e '.reconfigure | type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    error '当前状态仍包含未完成的带宽重配置事务；请先执行 recover。'
    return 1
  fi
  verify_settings_common || return 1
  info "验证通过；警告数：${WARNINGS}。"
}

reconfigure_source_state_is_valid() {
  jq -e --arg path "$SYSCTL_FILE" --argjson min_buf "$MIN_BUF_MAX" --argjson max_buf "$MAX_BUF_MAX" \
    --argjson numerator "$BUFFER_TARGET_NUMERATOR" --argjson denominator "$BUFFER_TARGET_DENOMINATOR" '
    def valid_integer($minimum; $maximum):
      type == "number" and . == floor and . >= $minimum and . <= $maximum;
    .state == "VERIFIED" and
    ((.reconfigure? // null) == null) and
    (.network | type == "object") and
    (.network.port_speed_mbps | valid_integer(1; 10000)) and
    (.network.target_rtt_ms | valid_integer(20; 500)) and
    (.network.buffer_target_numerator == $numerator) and
    (.network.buffer_target_denominator == $denominator) and
    (.network.buffer_max_bytes | valid_integer($min_buf; $max_buf)) and
    (.network.buffer_mode | IN("auto", "auto-clamped", "explicit")) and
    ([.managed_files[] | select(.path == $path)] | length == 1)
  ' "$STATE_FILE" >/dev/null
}

sysctl_profile_matches_network() {
  local port="$1" rtt="$2" buf="$3"
  grep -Fqx "# ${PROFILE_LABEL}; provider cap ${port} Mbps; target RTT ${rtt} ms." "$SYSCTL_FILE" || return 1
  [ "$(normalize_sysctl_value "$(managed_sysctl_value net.core.rmem_max)")" = "$buf" ] || return 1
  [ "$(normalize_sysctl_value "$(managed_sysctl_value net.core.wmem_max)")" = "$buf" ] || return 1
  [ "$(normalize_sysctl_value "$(managed_sysctl_value net.ipv4.tcp_rmem)")" = "4096 131072 ${buf}" ] || return 1
  [ "$(normalize_sysctl_value "$(managed_sysctl_value net.ipv4.tcp_wmem)")" = "4096 65536 ${buf}" ] || return 1
}

reconfigure_metadata_file_is_valid() {
  local candidate="$1"
  jq -e --arg state_backup "$RECONFIGURE_STATE_BACKUP" \
    --arg sysctl_backup "$RECONFIGURE_SYSCTL_BACKUP" --arg sysctl_path "$SYSCTL_FILE" \
    --argjson min_buf "$MIN_BUF_MAX" --argjson max_buf "$MAX_BUF_MAX" \
    --argjson numerator "$BUFFER_TARGET_NUMERATOR" --argjson denominator "$BUFFER_TARGET_DENOMINATOR" '
    def valid_hash: type == "string" and test("^[0-9a-f]{64}$");
    def valid_integer($minimum; $maximum):
      type == "number" and . == floor and . >= $minimum and . <= $maximum;
    def valid_network:
      type == "object" and
      (.port_speed_mbps | valid_integer(1; 10000)) and
      (.target_rtt_ms | valid_integer(20; 500)) and
      (.buffer_target_numerator == $numerator) and
      (.buffer_target_denominator == $denominator) and
      (.buffer_max_bytes | valid_integer($min_buf; $max_buf)) and
      (.buffer_mode | IN("auto", "auto-clamped", "explicit"));
    (.state | IN("RECONFIGURING", "DEGRADED")) and
    (.reconfigure | type == "object") and
    (.reconfigure.schema_version == 1) and
    (.reconfigure.old_network | valid_network) and
    (.reconfigure.target_network | valid_network) and
    (.reconfigure.old_network.port_speed_mbps != .reconfigure.target_network.port_speed_mbps) and
    (.reconfigure.old_network.target_rtt_ms == .reconfigure.target_network.target_rtt_ms) and
    (.reconfigure.old_network.buffer_target_numerator == .reconfigure.target_network.buffer_target_numerator) and
    (.reconfigure.old_network.buffer_target_denominator == .reconfigure.target_network.buffer_target_denominator) and
    (.reconfigure.sysctl_values_changed ==
      (.reconfigure.old_network.buffer_max_bytes != .reconfigure.target_network.buffer_max_bytes)) and
    (.reconfigure.state_backup_path == $state_backup) and
    (.reconfigure.sysctl_backup_path == $sysctl_backup) and
    (.reconfigure.state_backup_sha256 | valid_hash) and
    (.reconfigure.sysctl_backup_sha256 | valid_hash) and
    ((.reconfigure.candidate_sysctl_sha256 == null) or
      (.reconfigure.candidate_sysctl_sha256 | valid_hash)) and
    (.reconfigure.started_at | type == "string" and length > 0) and
    ([.managed_files[] | select(.path == $sysctl_path)] | length == 1) and
    (if .reconfigure.candidate_sysctl_sha256 == null then
      .network == .reconfigure.old_network and
      ([.managed_files[] | select(.path == $sysctl_path)][0].sha256 == .reconfigure.sysctl_backup_sha256)
    else
      .network == .reconfigure.target_network and
      ([.managed_files[] | select(.path == $sysctl_path)][0].sha256 == .reconfigure.candidate_sysctl_sha256)
    end)
  ' "$candidate" >/dev/null
}

reconfigure_candidate_is_valid() {
  local expected actual
  reconfigure_metadata_file_is_valid "$STATE_FILE" || return 1
  expected="$(jq -er '.reconfigure.candidate_sysctl_sha256 | select(type == "string")' "$STATE_FILE")" || return 1
  actual="$(sha256sum "$SYSCTL_FILE" | awk '{print $1}')" || return 1
  [ "$actual" = "$expected" ]
}

prepare_reconfigure_backups() {
  local state_hash sysctl_hash path
  for path in "$RECONFIGURE_STATE_BACKUP" "$RECONFIGURE_SYSCTL_BACKUP"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      error "带宽重配置备份路径已存在：${path}"
      return 1
    fi
  done
  if ! install -o root -g root -m 0600 "$STATE_FILE" "$RECONFIGURE_STATE_BACKUP"; then
    return 1
  fi
  if ! install -o root -g root -m 0600 "$SYSCTL_FILE" "$RECONFIGURE_SYSCTL_BACKUP"; then
    rm -f -- "$RECONFIGURE_STATE_BACKUP"
    return 1
  fi
  if ! state_hash="$(sha256sum "$RECONFIGURE_STATE_BACKUP" | awk '{print $1}')" ||
    ! sysctl_hash="$(sha256sum "$RECONFIGURE_SYSCTL_BACKUP" | awk '{print $1}')"; then
    rm -f -- "$RECONFIGURE_STATE_BACKUP" "$RECONFIGURE_SYSCTL_BACKUP"
    return 1
  fi
  if [ "$state_hash" != "$(sha256sum "$STATE_FILE" | awk '{print $1}')" ] ||
    [ "$sysctl_hash" != "$(sha256sum "$SYSCTL_FILE" | awk '{print $1}')" ]; then
    error '带宽重配置备份哈希与原文件不一致。'
    rm -f -- "$RECONFIGURE_STATE_BACKUP" "$RECONFIGURE_SYSCTL_BACKUP"
    return 1
  fi
  RECONFIGURE_STATE_BACKUP_SHA256="$state_hash"
  RECONFIGURE_SYSCTL_BACKUP_SHA256="$sysctl_hash"
}

cleanup_reconfigure_backups() {
  local path
  for path in "$RECONFIGURE_STATE_BACKUP" "$RECONFIGURE_SYSCTL_BACKUP"; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] &&
      [ "$(stat -c '%u' "$path" 2>/dev/null || true)" = '0' ] || {
        error "拒绝清理类型或所有权异常的带宽重配置备份：${path}"
        return 1
      }
  done
  rm -f -- "$RECONFIGURE_STATE_BACKUP" "$RECONFIGURE_SYSCTL_BACKUP"
}

begin_reconfigure_transaction() {
  local target_network="$1" values_changed="$2" tmp now
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! jq --argjson target "$target_network" --argjson values_changed "$values_changed" \
    --arg state_backup "$RECONFIGURE_STATE_BACKUP" --arg sysctl_backup "$RECONFIGURE_SYSCTL_BACKUP" \
    --arg state_hash "$RECONFIGURE_STATE_BACKUP_SHA256" --arg sysctl_hash "$RECONFIGURE_SYSCTL_BACKUP_SHA256" \
    --arg now "$now" '
      .state="RECONFIGURING" |
      .reconfigure={schema_version:1,old_network:.network,target_network:$target,
        sysctl_values_changed:$values_changed,state_backup_path:$state_backup,
        sysctl_backup_path:$sysctl_backup,state_backup_sha256:$state_hash,
        sysctl_backup_sha256:$sysctl_hash,candidate_sysctl_sha256:null,started_at:$now} |
      .timestamps.last_update=$now
    ' "$STATE_FILE" >"$tmp" || ! chmod 0600 "$tmp" || ! chown root:root "$tmp" ||
    ! state_file_path_is_valid "$tmp" || ! reconfigure_metadata_file_is_valid "$tmp" ||
    ! atomic_json_commit "$STATE_FILE" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
}

update_reconfigure_candidate_state() {
  local sysctl_hash tmp now
  sysctl_hash="$(sha256sum "$SYSCTL_FILE" | awk '{print $1}')" || return 1
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! jq --arg path "$SYSCTL_FILE" --arg hash "$sysctl_hash" --arg now "$now" '
      .network=.reconfigure.target_network |
      .managed_files=(.managed_files | map(if .path == $path then .sha256=$hash else . end)) |
      .reconfigure.candidate_sysctl_sha256=$hash |
      .timestamps.last_update=$now
    ' "$STATE_FILE" >"$tmp" || ! chmod 0600 "$tmp" || ! chown root:root "$tmp" ||
    ! state_file_path_is_valid "$tmp" || ! reconfigure_metadata_file_is_valid "$tmp" ||
    ! atomic_json_commit "$STATE_FILE" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
}

finalize_reconfigure_state() {
  local tmp now
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! jq --arg now "$now" '
      .state="VERIFIED" |
      .timestamps.last_reconfigured=$now |
      .timestamps.last_update=$now |
      del(.reconfigure)
    ' "$STATE_FILE" >"$tmp" || ! chmod 0600 "$tmp" || ! chown root:root "$tmp" ||
    ! state_file_path_is_valid "$tmp" ||
    ! jq -e '.state == "VERIFIED" and ((.reconfigure? // null) == null)' "$tmp" >/dev/null ||
    ! atomic_json_commit "$STATE_FILE" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
}

write_reconfigure_failure_evidence() {
  local transaction_json="$1" trigger="$2" original_rc="$3" recovered="$4" stage="$5" tmp
  tmp="$(mktemp "${RECONFIGURE_FAILURE_EVIDENCE}.tmp.XXXXXX")" || return 1
  if ! jq -n --arg trigger "$trigger" --arg stage "$stage" --arg now "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --argjson original_rc "$original_rc" --argjson recovered "$recovered" --argjson transaction "$transaction_json" '
      {schema_version:1,trigger:$trigger,stage:$stage,original_exit_code:$original_rc,
       recovered:$recovered,recorded_at:$now,reconfigure:$transaction}
    ' >"$tmp" || ! atomic_json_commit "$RECONFIGURE_FAILURE_EVIDENCE" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
}

restore_reconfigure_sysctl_backup() {
  local tmp
  tmp="$(mktemp "${SYSCTL_FILE}.reconfigure-restore.XXXXXX")" || return 1
  if ! install -o root -g root -m 0644 "$RECONFIGURE_SYSCTL_BACKUP" "$tmp" ||
    ! mv -f -- "$tmp" "$SYSCTL_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
}

restore_reconfigure_state_backup() {
  local tmp
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! cp -- "$RECONFIGURE_STATE_BACKUP" "$tmp" || ! chmod 0600 "$tmp" || ! chown root:root "$tmp" ||
    ! state_file_path_is_valid "$tmp" || ! jq -e '.state == "VERIFIED" and ((.reconfigure? // null) == null)' "$tmp" >/dev/null ||
    ! atomic_json_commit "$STATE_FILE" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
}

reconfigure_backups_are_valid() {
  local state_hash sysctl_hash path
  reconfigure_metadata_file_is_valid "$STATE_FILE" || return 1
  for path in "$RECONFIGURE_STATE_BACKUP" "$RECONFIGURE_SYSCTL_BACKUP"; do
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    [ "$(stat -c '%u' "$path" 2>/dev/null || true)" = '0' ] || return 1
    [ "$(stat -c '%a' "$path" 2>/dev/null || true)" = '600' ] || return 1
  done
  state_hash="$(sha256sum "$RECONFIGURE_STATE_BACKUP" | awk '{print $1}')" || return 1
  sysctl_hash="$(sha256sum "$RECONFIGURE_SYSCTL_BACKUP" | awk '{print $1}')" || return 1
  [ "$state_hash" = "$(jq -r '.reconfigure.state_backup_sha256' "$STATE_FILE")" ] || return 1
  [ "$sysctl_hash" = "$(jq -r '.reconfigure.sysctl_backup_sha256' "$STATE_FILE")" ] || return 1
  state_file_path_is_valid "$RECONFIGURE_STATE_BACKUP" || return 1
  jq -e --arg path "$SYSCTL_FILE" --arg sysctl_hash "$sysctl_hash" --slurpfile current "$STATE_FILE" '
    .state == "VERIFIED" and
    ((.reconfigure? // null) == null) and
    .network == $current[0].reconfigure.old_network and
    ([.managed_files[] | select(.path == $path and .sha256 == $sysctl_hash)] | length == 1)
  ' "$RECONFIGURE_STATE_BACKUP" >/dev/null || return 1
  grep -Fq "$MANAGED_MARKER" "$RECONFIGURE_SYSCTL_BACKUP"
}

record_reconfigure_recovery_failure() {
  local transaction_json="$1" trigger="$2" original_rc="$3" stage="$4"
  state_set_phase 'DEGRADED' || error '无法把失败的带宽重配置事务标记为 DEGRADED。'
  write_reconfigure_failure_evidence "$transaction_json" "$trigger" "$original_rc" false "$stage" ||
    error "无法写入带宽重配置失败证据：${RECONFIGURE_FAILURE_EVIDENCE}"
  return 0
}

recover_incomplete_reconfigure() {
  local trigger="${1:-manual-recover}" original_rc="${2:-0}" phase transaction_json stage='metadata-validation'
  state_exists || { error '没有需要恢复的带宽重配置事务。'; return 1; }
  state_file_is_valid || { error 'state.json 无法通过当前版本校验；拒绝猜测恢复。'; return 1; }
  phase="$(state_get '.state')"
  case "$phase" in RECONFIGURING | DEGRADED) ;; *) error "当前状态 ${phase} 不是可恢复的带宽重配置事务。"; return 1 ;; esac
  transaction_json="$(jq -c '.reconfigure | select(type == "object")' "$STATE_FILE" 2>/dev/null || true)"
  [ -n "$transaction_json" ] || { error '状态中缺少带宽重配置恢复元数据。'; return 1; }
  if ! reconfigure_backups_are_valid; then
    error '带宽重配置备份或其哈希无效；拒绝覆盖当前配置。'
    record_reconfigure_recovery_failure "$transaction_json" "$trigger" "$original_rc" "$stage"
    return 1
  fi

  stage='restore-sysctl-file'
  if ! restore_reconfigure_sysctl_backup; then
    error '无法原子恢复重配置前的 sysctl 管理文件。'
    record_reconfigure_recovery_failure "$transaction_json" "$trigger" "$original_rc" "$stage"
    return 1
  fi
  stage='apply-restored-sysctl'
  if ! sysctl -p "$SYSCTL_FILE" >/dev/null; then
    error '已恢复旧 sysctl 文件，但无法重新应用其参数。'
    record_reconfigure_recovery_failure "$transaction_json" "$trigger" "$original_rc" "$stage"
    return 1
  fi
  stage='verify-restored-configuration'
  if ! verify_settings "$RECONFIGURE_STATE_BACKUP" >/dev/null; then
    error '旧 sysctl 已恢复，但按旧状态执行完整验证失败。'
    record_reconfigure_recovery_failure "$transaction_json" "$trigger" "$original_rc" "$stage"
    return 1
  fi
  stage='restore-state'
  if ! restore_reconfigure_state_backup; then
    error '旧配置验证通过，但无法原子恢复旧 state.json。'
    record_reconfigure_recovery_failure "$transaction_json" "$trigger" "$original_rc" "$stage"
    return 1
  fi
  write_reconfigure_failure_evidence "$transaction_json" "$trigger" "$original_rc" true 'recovered' ||
    warn "旧配置已恢复，但无法写入失败证据：${RECONFIGURE_FAILURE_EVIDENCE}"
  cleanup_reconfigure_backups || warn '旧配置已恢复，但事务备份未能清理；后续重配置会先拒绝覆盖这些路径。'
  info '带宽重配置失败事务已恢复到原 VERIFIED 配置。'
}

verify_reconfigure_candidate() {
  local target_port target_rtt target_buf
  state_exists || { error '带宽重配置候选缺少管理状态。'; return 1; }
  validate_state_file || return 1
  [ "$(state_get '.state')" = 'RECONFIGURING' ] || {
    error "当前状态不是 RECONFIGURING：$(state_get '.state')"; return 1; }
  reconfigure_candidate_is_valid || { error '带宽重配置候选状态、管理文件或哈希不一致。'; return 1; }
  target_port="$(state_get '.network.port_speed_mbps')"
  target_rtt="$(state_get '.network.target_rtt_ms')"
  target_buf="$(state_get '.network.buffer_max_bytes')"
  sysctl_profile_matches_network "$target_port" "$target_rtt" "$target_buf" || {
    error '带宽重配置候选 sysctl 文件与目标端口、RTT 或 buffer 语义不一致。'
    return 1
  }
  verify_settings_common || return 1
  info "带宽重配置候选验证通过；警告数：${WARNINGS}。"
}

restore_fq_codel() {
  local iface="$1" scope="$2" parent="$3" json="$4" value
  local cmd=(tc qdisc replace dev "$iface")
  if [ "$scope" = 'root' ]; then cmd+=(root); else cmd+=(parent "$parent"); fi
  value="$(jq -r '.handle // empty' <<<"$json")"
  if [ -n "$value" ] && [ "$value" != '0:' ]; then cmd+=(handle "$value"); fi
  cmd+=(fq_codel)
  value="$(jq -r '.options.limit // empty' <<<"$json")"; [ -z "$value" ] || cmd+=(limit "$value")
  value="$(jq -r '.options.flows // empty' <<<"$json")"; [ -z "$value" ] || cmd+=(flows "$value")
  value="$(jq -r '.options.quantum // empty' <<<"$json")"; [ -z "$value" ] || cmd+=(quantum "$value")
  value="$(jq -r '.options.target // empty' <<<"$json")"; if [ -n "$value" ]; then [[ "$value" =~ ^[0-9]+$ ]] && value="${value}us"; cmd+=(target "$value"); fi
  value="$(jq -r '.options.interval // empty' <<<"$json")"; if [ -n "$value" ]; then [[ "$value" =~ ^[0-9]+$ ]] && value="${value}us"; cmd+=(interval "$value"); fi
  value="$(jq -r '.options.memory_limit // empty' <<<"$json")"; [ -z "$value" ] || cmd+=(memory_limit "$value")
  value="$(jq -r '.options.drop_batch // empty' <<<"$json")"; [ -z "$value" ] || cmd+=(drop_batch "$value")
  value="$(jq -r '.options.ce_threshold // empty' <<<"$json")"; if [ -n "$value" ]; then [[ "$value" =~ ^[0-9]+$ ]] && value="${value}us"; cmd+=(ce_threshold "$value"); fi
  if jq -e '.options | has("ecn")' <<<"$json" >/dev/null 2>&1; then
    if jq -e '.options.ecn == true' <<<"$json" >/dev/null 2>&1; then cmd+=(ecn); else cmd+=(noecn); fi
  fi
  if ! "${cmd[@]}"; then
    printf '[x] fq_codel 恢复命令失败：' >&2
    printf '%q ' "${cmd[@]}" >&2
    printf '\n' >&2
    return 1
  fi
}

restore_qdiscs() {
  [ -f "$QDISC_STATE_FILE" ] || { error "qdisc 原始快照不存在：${QDISC_STATE_FILE}"; return 1; }
  local expected_hash actual_hash
  expected_hash="$(state_get '.qdisc.sha256')"
  actual_hash="$(sha256sum "$QDISC_STATE_FILE" | awk '{print $1}')"
  [ "$actual_hash" = "$expected_hash" ] || {
    error "qdisc 原始快照哈希不匹配：expected=${expected_hash} actual=${actual_hash}"
    return 1
  }
  local count i iface root_json root_kind leaf_json parent kind
  local saved_snapshot saved_root_major saved_rows saved_minors current_snapshot current_root_major
  local current_rows current_minors fq_codel_count minor
  count="$(jq 'length' "$QDISC_STATE_FILE")"
  for ((i=0; i<count; i++)); do
    iface="$(jq -r ".[$i].interface" "$QDISC_STATE_FILE")"
    root_json="$(jq -c ".[$i].qdiscs[] | select(.root == true)" "$QDISC_STATE_FILE" | head -n1)"
    root_kind="$(jq -r '.kind' <<<"$root_json")"
    case "$root_kind" in
      fq) : ;;
      fq_codel) restore_fq_codel "$iface" root '' "$root_json" || return 1 ;;
      pfifo_fast) tc qdisc replace dev "$iface" root pfifo_fast || return 1 ;;
      noqueue) ;;
      mq)
        saved_snapshot="$(jq -c ".[$i]" "$QDISC_STATE_FILE")" || return 1
        saved_root_major="$(mq_root_major_from_snapshot "$saved_snapshot")" || return 1
        saved_rows="$(mq_leaf_rows_from_snapshot "$saved_snapshot" "$saved_root_major")"
        mq_leaf_rows_are_supported "$saved_rows" || return 1
        saved_minors="$(mq_leaf_minors_from_rows "$saved_rows")"
        current_snapshot="$(qdisc_snapshot_for_iface "$iface")" || return 1
        [ "$(jq -r '.qdiscs[] | select(.root == true) | .kind' <<<"$current_snapshot" | head -n1)" = 'mq' ] || return 1
        current_root_major="$(mq_root_major_from_snapshot "$current_snapshot")" || return 1
        if [ "$saved_root_major" != '0' ] && [ "$current_root_major" != "$saved_root_major" ]; then
          error "${iface}: 当前 mq root handle 与原始显式 handle 不一致；拒绝恢复。"
          return 1
        fi
        current_rows="$(mq_leaf_rows_from_snapshot "$current_snapshot" "$current_root_major")"
        mq_leaf_rows_are_supported "$current_rows" || return 1
        current_minors="$(mq_leaf_minors_from_rows "$current_rows")"
        [ "$current_minors" = "$saved_minors" ] || {
          error "${iface}: 当前 mq 发送队列 minor 集合与原始快照不一致；拒绝恢复。"
          return 1
        }
        fq_codel_count="$(awk -F '\t' '$2 == "fq_codel" {count++} END {print count+0}' <<<"$saved_rows")"
        if [ "$current_root_major" = '0' ] && [ "$fq_codel_count" -gt 0 ]; then
          current_root_major="$(ensure_addressable_mq_root "$iface" "$saved_minors")" || return 1
        fi
        while IFS=$'\t' read -r minor kind parent; do
          minor="${minor%$'\r'}"
          kind="${kind%$'\r'}"
          parent="${parent%$'\r'}"
          leaf_json="$(jq -c --arg parent "$parent" '.qdiscs[] | select(.parent == $parent)' <<<"$saved_snapshot" | head -n1)"
          [ -n "$minor" ] && [ -n "$kind" ] && [ -n "$leaf_json" ] || return 1
          # 保存的 :N/0:N 只提供队列 minor；恢复命令必须使用当前可寻址的 root major。
          parent="${current_root_major}:${minor}"
          case "$kind" in fq) : ;; fq_codel) restore_fq_codel "$iface" leaf "$parent" "$leaf_json" || return 1 ;; *) return 1 ;; esac
        done <<<"$saved_rows"
        ;;
      *) return 1 ;;
    esac
  done
}

remove_fstab_swap_line() {
  local fstab_file="$FSTAB_FILE" line="${SWAP_FILE} none swap sw 0 0" tmp grep_rc
  [ -f "$fstab_file" ] && [ ! -L "$fstab_file" ] || return 1
  if grep -Fqx "$line" "$fstab_file"; then
    :
  else
    grep_rc=$?
    [ "$grep_rc" -eq 1 ] && return 0
    return 1
  fi
  tmp="$(mktemp "${fstab_file}.proxy-vps-tuning.XXXXXX")" || return 1
  if ! awk -v wanted="$line" '$0 != wanted' "$fstab_file" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ ! -s "$tmp" ] && grep -Fvxq "$line" "$fstab_file"; then
    rm -f -- "$tmp"
    return 1
  fi
  if grep -Fqx "$line" "$tmp" ||
    ! chown --reference="$fstab_file" "$tmp" ||
    ! chmod --reference="$fstab_file" "$tmp" ||
    ! mv -fT -- "$tmp" "$fstab_file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

purge_owned_swap() {
  state_get '.swap.created_by_script' | grep -qx true || return 0
  [ "$(state_get '.swap.path')" = "$SWAP_FILE" ] || return 1
  if [ ! -e "$SWAP_FILE" ]; then
    remove_fstab_swap_line || return 1
    return 0
  fi
  [ -f "$SWAP_FILE" ] && [ ! -L "$SWAP_FILE" ] || return 1
  [ "$(stat -c '%d' "$SWAP_FILE")" = "$(state_get '.swap.device')" ] || return 1
  [ "$(stat -c '%i' "$SWAP_FILE")" = "$(state_get '.swap.inode')" ] || return 1
  if swapon --show=NAME --noheadings | awk '{$1=$1;print}' | grep -Fx -- "$SWAP_FILE" >/dev/null; then
    swapoff "$SWAP_FILE" || return 1
  fi
  remove_fstab_swap_line || return 1
  rm -f -- "$SWAP_FILE"
}

sysctl_defined_elsewhere() {
  local key="$1" file escaped
  escaped="${key//./\\.}"
  shopt -s nullglob
  for file in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
    [ "$file" = "$SYSCTL_FILE" ] && continue
    [ -f "$file" ] || continue
    if grep -Eq "^[[:space:]]*${escaped}[[:space:]]*=" "$file"; then shopt -u nullglob; return 0; fi
  done
  shopt -u nullglob
  return 1
}

provider_sysctl_key_was_transferred() {
  local key="$1"
  jq -e --arg key "$key" '
    .provider_sysctl_transfer.required == true and
    any(.provider_sysctl_transfer.keys[]; .key == $key)
  ' "$STATE_FILE" >/dev/null 2>&1
}

original_sysctl_vectors_are_complete() {
  # 旧快照可能只保存三元组首项；写入单值会被内核接受但不能恢复后两项。
  jq -e '.original_sysctls | all(."net.ipv4.tcp_rmem", ."net.ipv4.tcp_wmem";
    type == "string" and test("^[0-9]+[\\t ]+[0-9]+[\\t ]+[0-9]+$"))' "$STATE_FILE" >/dev/null || {
    error '原始 TCP buffer 三元组不完整；保留状态并停止回滚，不能猜测缺失的原始值。'
    return 1
  }
}

restore_original_sysctls() {
  local key value failures=0
  for key in "${PROFILE_SYSCTL_KEYS[@]}"; do
    if ! provider_sysctl_key_was_transferred "$key" && sysctl_defined_elsewhere "$key"; then
      continue
    fi
    value="$(jq -r --arg key "$key" '.original_sysctls[$key] // empty' "$STATE_FILE")"
    [ -n "$value" ] || continue
    if ! sysctl -q -w "${key}=${value}"; then
      error "回滚步骤失败：无法恢复 sysctl ${key}。"
      failures=$((failures + 1))
    fi
  done
  [ "$failures" -eq 0 ]
}

project_managed_files_exist() {
  local path
  for path in "$SYSCTL_FILE" "$JOURNAL_FILE" "$FQ_HELPER" "$FQ_SERVICE" "$XUI_DROPIN"; do
    if [ -e "$path" ] || [ -L "$path" ]; then return 0; fi
  done
  return 1
}

qdisc_snapshot_file_is_valid() {
  [ -f "$QDISC_STATE_FILE" ] && [ ! -L "$QDISC_STATE_FILE" ] || return 1
  [ "$(stat -c '%u' "$QDISC_STATE_FILE" 2>/dev/null || true)" = '0' ] || return 1
  [ -s "$QDISC_STATE_FILE" ] || return 1
  jq -e -s '
    length == 1 and
    (.[0] | type == "array" and length > 0) and
    all(.[0][];
      (.interface | type == "string") and (.interface | length > 0) and
      (.qdiscs | type == "array") and (.qdiscs | length > 0) and
      ([.qdiscs[] | select(.root == true)] | length == 1))
  ' "$QDISC_STATE_FILE" >/dev/null 2>&1
}

qdisc_snapshot_semantically_matches_current() {
  QDISC_MATCH_REASON=''
  qdisc_snapshot_file_is_valid || { QDISC_MATCH_REASON="快照缺失、为空、所有权异常或结构无效：${QDISC_STATE_FILE}"; return 1; }
  local count i iface saved current filter
  # jq variables must remain literal until jq evaluates this filter.
  # shellcheck disable=SC2016
  filter='
    . as $qdiscs |
    ([ $qdiscs[] | select(.root == true and .kind == "mq") ][0].handle // "") as $mq_handle |
    ($mq_handle | rtrimstr(":") | ascii_downcase) as $mq_major |
    map(
      ((.parent // "") as $parent |
       ($parent | ascii_downcase) as $parent_lower |
       if $parent == "" or $mq_handle == "" then $parent
       elif ($mq_major == "0" and ($parent_lower | test("^(:|0:)[0-9a-f]+$"))) then
         "mq-queue:" + ($parent_lower | sub("^(:|0:)"; ""))
       elif ($mq_major != "0" and ($parent_lower | startswith($mq_major + ":")) and
             (($parent_lower | ltrimstr($mq_major + ":")) | test("^[0-9a-f]+$"))) then
         "mq-queue:" + ($parent_lower | ltrimstr($mq_major + ":"))
       else $parent end) as $canonical_parent |
      {base:{kind,parent:$canonical_parent,root:(.root // false),options:((.options // {}) | del(.target,.interval,.ce_threshold))},handle:(.handle // ""),times:{target:(.options.target // null),interval:(.options.interval // null),ce_threshold:(.options.ce_threshold // null)}}
    ) | sort_by([.base.root,.base.parent,.base.kind])
  '
  count="$(jq 'length' "$QDISC_STATE_FILE")"
  for ((i=0; i<count; i++)); do
    iface="$(jq -r ".[$i].interface" "$QDISC_STATE_FILE")"
    saved="$(jq -cS ".[$i].qdiscs | ${filter}" "$QDISC_STATE_FILE")" || {
      QDISC_MATCH_REASON="无法解析 ${iface} 的原始快照"; return 1;
    }
    current="$(tc -j qdisc show dev "$iface" | jq -cS "$filter")" || {
      QDISC_MATCH_REASON="无法读取 ${iface} 的当前 qdisc"; return 1;
    }
    if ! jq -en --argjson saved "$saved" --argjson current "$current" '
      def close_time($a; $b):
        ($a == $b) or
        (($a | type) == "number" and ($b | type) == "number" and
         (($a - $b) >= -1 and ($a - $b) <= 1));
      def handle_matches($saved_handle; $current_handle):
        ($saved_handle == "" or $saved_handle == "0:" or
         $saved_handle == $current_handle);
      ($saved | length) == ($current | length) and
      all(range(0; $saved | length);
        $saved[.].base == $current[.].base and
        handle_matches($saved[.].handle; $current[.].handle) and
        close_time($saved[.].times.target; $current[.].times.target) and
        close_time($saved[.].times.interval; $current[.].times.interval) and
        close_time($saved[.].times.ce_threshold; $current[.].times.ce_threshold))
    ' >/dev/null; then
      QDISC_MATCH_REASON="${iface} 语义不一致：saved=${saved} current=${current}"
      return 1
    fi
  done
}

qdisc_snapshot_matches_current() {
  QDISC_MATCH_REASON=''
  local expected_hash actual_hash
  expected_hash="$(state_get '.qdisc.sha256')" || { QDISC_MATCH_REASON='状态中缺少 qdisc.sha256'; return 1; }
  actual_hash="$(sha256sum "$QDISC_STATE_FILE" 2>/dev/null | awk '{print $1}')"
  if [ -z "$expected_hash" ] || [ "$actual_hash" != "$expected_hash" ]; then
    QDISC_MATCH_REASON="快照哈希不匹配：expected=${expected_hash:-missing} actual=${actual_hash:-missing}"
    return 1
  fi
  qdisc_snapshot_semantically_matches_current
}

provider_sysctl_transfer_matches_original() {
  state_get '.provider_sysctl_transfer.required' | grep -qx true || return 0
  local source expected actual
  source="$(state_get '.provider_sysctl_transfer.source_path')"
  expected="$(state_get '.provider_sysctl_transfer.original_sha256')"
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  actual="$(sha256sum "$source" 2>/dev/null | awk '{print $1}')"
  [ "$actual" = "$expected" ]
}

provider_sysctl_transfer_is_restorable() {
  state_get '.provider_sysctl_transfer.required' | grep -qx true || return 0
  local phase source backup original_hash backup_hash transferred_hash current_hash
  phase="$(state_get '.provider_sysctl_transfer.state')"
  source="$(state_get '.provider_sysctl_transfer.source_path')"
  backup="$(state_get '.provider_sysctl_transfer.backup_path')"
  original_hash="$(state_get '.provider_sysctl_transfer.original_sha256')"
  backup_hash="$(jq -r '.provider_sysctl_transfer.backup_sha256 // empty' "$STATE_FILE")"
  transferred_hash="$(jq -r '.provider_sysctl_transfer.transferred_sha256 // empty' "$STATE_FILE")"
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  current_hash="$(sha256sum "$source" 2>/dev/null | awk '{print $1}')"
  [ "$current_hash" = "$original_hash" ] && return 0
  case "$phase" in PLANNED | TRANSFERRED) ;; *) return 1 ;; esac
  [ -n "$transferred_hash" ] && [ "$current_hash" = "$transferred_hash" ] || return 1
  [ -f "$backup" ] && [ ! -L "$backup" ] && [ "$(stat -c '%u' "$backup" 2>/dev/null || true)" = '0' ] || return 1
  [ -n "$backup_hash" ] && [ "$backup_hash" = "$original_hash" ] || return 1
  [ "$(sha256sum "$backup" 2>/dev/null | awk '{print $1}')" = "$original_hash" ]
}

restore_provider_sysctl_ownership() {
  state_get '.provider_sysctl_transfer.required' | grep -qx true || return 0
  local phase source backup original_hash backup_hash transferred_hash current_hash uid gid mode tmp
  phase="$(state_get '.provider_sysctl_transfer.state')"
  source="$(state_get '.provider_sysctl_transfer.source_path')"
  backup="$(state_get '.provider_sysctl_transfer.backup_path')"
  original_hash="$(state_get '.provider_sysctl_transfer.original_sha256')"
  backup_hash="$(jq -r '.provider_sysctl_transfer.backup_sha256 // empty' "$STATE_FILE")"
  transferred_hash="$(jq -r '.provider_sysctl_transfer.transferred_sha256 // empty' "$STATE_FILE")"
  uid="$(state_get '.provider_sysctl_transfer.original_uid')"
  gid="$(state_get '.provider_sysctl_transfer.original_gid')"
  mode="$(state_get '.provider_sysctl_transfer.original_mode')"
  [ -f "$source" ] && [ ! -L "$source" ] || { error "无法恢复厂商 sysctl：源文件缺失或类型异常：${source}"; return 1; }
  current_hash="$(sha256sum "$source" | awk '{print $1}')" || return 1

  if [ "$current_hash" = "$original_hash" ]; then
    set_provider_sysctl_transfer_state 'RESTORED' "$backup_hash" "$transferred_hash"
    return $?
  fi
  case "$phase" in
    PLANNED | TRANSFERRED)
      [ -n "$transferred_hash" ] && [ "$current_hash" = "$transferred_hash" ] || {
        error "${source} 在 apply 后发生外部修改；为避免覆盖管理员变更，拒绝恢复。"
        return 1
      }
      ;;
    *)
      error "厂商 sysctl 迁移状态 ${phase} 与当前文件不一致，拒绝恢复。"
      return 1
      ;;
  esac
  [ -f "$backup" ] && [ ! -L "$backup" ] && [ "$(stat -c '%u' "$backup" 2>/dev/null || true)" = '0' ] || {
    error "厂商 sysctl 原始备份缺失或所有权异常：${backup}"; return 1; }
  [ "$(sha256sum "$backup" | awk '{print $1}')" = "$original_hash" ] || {
    error '厂商 sysctl 原始备份哈希不匹配。'; return 1; }
  [ "$backup_hash" = "$original_hash" ] || { error '状态中的厂商 sysctl 备份哈希不匹配。'; return 1; }

  tmp="$(mktemp "${source}.proxy-vps.restore.XXXXXX")" || return 1
  if ! cp -- "$backup" "$tmp" || ! chmod "$mode" "$tmp" || ! chown "${uid}:${gid}" "$tmp" || ! mv -f -- "$tmp" "$source"; then
    rm -f -- "$tmp"
    return 1
  fi
  [ "$(sha256sum "$source" | awk '{print $1}')" = "$original_hash" ] || {
    error '厂商 sysctl 恢复后哈希不匹配。'; return 1; }
  set_provider_sysctl_transfer_state 'RESTORED' "$backup_hash" "$transferred_hash" || return 1
  info "已恢复厂商原始 sysctl 文件：${source}。"
}

original_sysctls_match_current() {
  local key expected actual
  for key in "${PROFILE_SYSCTL_KEYS[@]}"; do
    if ! provider_sysctl_key_was_transferred "$key" && sysctl_defined_elsewhere "$key"; then
      continue
    fi
    expected="$(jq -r --arg key "$key" '.original_sysctls[$key] // empty' "$STATE_FILE")"
    [ -n "$expected" ] || continue
    actual="$(sysctl -n "$key" 2>/dev/null || true)"
    [ "$(normalize_sysctl_value "$actual")" = "$(normalize_sysctl_value "$expected")" ] || return 1
  done
}

rollback_already_restored() {
  project_managed_files_exist && return 1
  state_get '.swap.created_by_script' | grep -qx false || return 1
  provider_sysctl_transfer_matches_original || return 1
  qdisc_snapshot_matches_current || return 1
  original_sysctls_match_current
}

recover_empty_legacy_state() {
  [ "$ALLOW_EMPTY_STATE_RECOVERY" = '1' ] ||
    die "$EXIT_CONFLICT" 'recover 只用于已确认的 rc.2 首次系统写入前空状态；确认历史证据后设置 ALLOW_EMPTY_STATE_RECOVERY=1。'
  state_exists || die "$EXIT_CONFLICT" '没有需要恢复的 state.json。'
  state_file_is_valid && die "$EXIT_CONFLICT" 'state.json 有效；请使用 rollback，不得使用 recover。'
  if [ ! -d "$STATE_DIR" ] || [ -L "$STATE_DIR" ] ||
    [ "$(stat -c '%u' "$STATE_DIR" 2>/dev/null || true)" != '0' ]; then
    die "$EXIT_CONFLICT" "状态目录所有权或类型异常：${STATE_DIR}"
  fi
  if ! jq -e -s 'length == 0' "$STATE_FILE" >/dev/null 2>&1; then
    die "$EXIT_CONFLICT" 'state.json 不是空 JSON 流；拒绝把一般损坏状态当作 rc.2 遗留状态恢复。'
  fi
  project_managed_files_exist &&
    die "$EXIT_CONFLICT" '仍存在项目管理文件；无法证明 rc.2 在首次系统写入前失败。'
  if [ -e "$SWAP_FILE" ] || [ -L "$SWAP_FILE" ]; then
    die "$EXIT_CONFLICT" "检测到 ${SWAP_FILE}；空状态无法证明 swap 所有权，拒绝恢复。"
  fi
  grep -Fqx "${SWAP_FILE} none swap sw 0 0" /etc/fstab 2>/dev/null &&
    die "$EXIT_CONFLICT" "检测到 ${SWAP_FILE} 的 fstab 行；拒绝恢复。"
  if systemctl is-active --quiet "$FQ_SERVICE_NAME" 2>/dev/null; then
    die "$EXIT_CONFLICT" "${FQ_SERVICE_NAME} 仍在运行；拒绝恢复。"
  fi
  if ! qdisc_snapshot_semantically_matches_current; then
    die "$EXIT_CONFLICT" "当前 qdisc 与 rc.2 快照不一致；拒绝恢复：${QDISC_MATCH_REASON}"
  fi
  local quarantine
  quarantine="${STATE_DIR}.recovered-$(date -u +'%Y%m%dT%H%M%SZ')"
  [ ! -e "$quarantine" ] || die "$EXIT_CONFLICT" "恢复证据目录已存在：${quarantine}"
  mv -- "$STATE_DIR" "$quarantine" || die "$EXIT_CONFLICT" '无法隔离空状态目录。'
  info "已隔离 rc.2 空状态；没有删除证据：${quarantine}"
  info 'State: UNMANAGED。现在可重新执行 preflight。'
}

rollback_internal() {
  local force_purge="$1" path failures=0 phase
  validate_state_file || return 1
  phase="$(state_get '.state')"
  if [ "$phase" = 'RECONFIGURING' ] || jq -e '.reconfigure | type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    error '检测到未完成的带宽重配置事务；普通 rollback 不会越过该事务，请先执行 recover。'
    return 1
  fi
  if [ "$phase" = 'SWAP_RETAINED' ]; then
    if [ "$force_purge" = '1' ] || [ "$PURGE_CREATED_SWAP" = '1' ]; then
      purge_owned_swap || { state_set_phase 'DEGRADED' || true; return 1; }
      rm -rf -- "$STATE_DIR"
      info '保留的应急 swap 已清理，管理状态已删除。'
    else
      info "系统配置已处于回滚状态；应急 swap 仍保留：${SWAP_FILE}"
    fi
    return 0
  fi
  original_sysctl_vectors_are_complete || return 1
  case "$phase" in
    PREPARED | ROLLBACK_PENDING | DEGRADED)
      if rollback_already_restored; then
        rm -rf -- "$STATE_DIR"
        info "状态 ${phase} 未检测到仍生效的项目配置；已清理残留事务状态。"
        return 0
      fi
      ;;
  esac
  for path in "$SYSCTL_FILE" "$JOURNAL_FILE" "$FQ_HELPER" "$FQ_SERVICE" "$XUI_DROPIN"; do
    [ -e "$path" ] || continue
    assert_owned_file "$path"
  done
  if ! provider_sysctl_transfer_is_restorable; then
    error '回滚前检查失败：厂商 sysctl 文件或备份已变化；未停止服务、未恢复 qdisc、未删除项目配置。'
    state_set_phase 'DEGRADED' || error '同时无法记录 DEGRADED；原状态文件已保留。'
    return 1
  fi
  state_set_phase 'ROLLBACK_PENDING' || return 1
  if [ -e "$FQ_SERVICE" ]; then
    if ! systemctl disable --now "$FQ_SERVICE_NAME" >/dev/null 2>&1; then
      error "回滚步骤失败：无法停止或禁用 ${FQ_SERVICE_NAME}。"
      failures=$((failures + 1))
    fi
  fi
  if qdisc_snapshot_matches_current; then
    info '当前 qdisc 已与原始快照一致，无需重建。'
  else
    warn "当前 qdisc 与原始快照未判定为一致：${QDISC_MATCH_REASON}"
    if ! restore_qdiscs; then
      error '回滚步骤失败：无法恢复原始 qdisc。'
      failures=$((failures + 1))
    elif ! qdisc_snapshot_semantically_matches_current; then
      error "回滚步骤失败：qdisc 恢复后与原始快照不一致：${QDISC_MATCH_REASON}"
      failures=$((failures + 1))
    else
      info 'qdisc 已恢复并通过原始快照语义验证。'
    fi
  fi
  if ! restore_provider_sysctl_ownership; then
    error '回滚步骤失败：无法安全恢复厂商 sysctl 配置归属。'
    failures=$((failures + 1))
    state_set_phase 'DEGRADED' || error '同时无法记录 DEGRADED；原状态文件已保留。'
    return 1
  fi
  if ! rm -f -- "$SYSCTL_FILE" "$JOURNAL_FILE" "$FQ_HELPER" "$FQ_SERVICE" "$XUI_DROPIN"; then
    error '回滚步骤失败：无法删除一个或多个项目管理文件。'
    failures=$((failures + 1))
  fi
  rmdir -- "$XUI_DROPIN_DIR" >/dev/null 2>&1 || true
  if ! systemctl daemon-reload; then
    error '回滚步骤失败：systemctl daemon-reload。'
    failures=$((failures + 1))
  fi
  if ! sysctl --system >/dev/null; then
    error '回滚步骤失败：sysctl --system；请检查上方内核参数错误。'
    failures=$((failures + 1))
  fi
  restore_original_sysctls || failures=$((failures + 1))
  if ! original_sysctls_match_current; then
    error '回滚步骤失败：sysctl 读回值与原始快照不一致。'
    failures=$((failures + 1))
  fi
  systemctl try-restart systemd-journald.service >/dev/null 2>&1 || true
  if [ "$force_purge" = '1' ] || [ "$PURGE_CREATED_SWAP" = '1' ]; then
    if ! purge_owned_swap; then
      error '回滚步骤失败：无法安全清理脚本创建的 swap。'
      failures=$((failures + 1))
    fi
  fi
  if [ "$failures" -ne 0 ]; then
    state_set_phase 'DEGRADED' || error '同时无法记录 DEGRADED；原状态文件已保留。'
    return 1
  fi
  if state_get '.swap.created_by_script' | grep -qx true && [ -e "$SWAP_FILE" ]; then
    state_set_phase 'SWAP_RETAINED' || return 1
    rm -f -- "$QDISC_STATE_FILE"
    info "系统配置已回滚；应急 swap 保留：${SWAP_FILE}"
  else
    rm -rf -- "$STATE_DIR"
    info '回滚完成，管理状态已清理。'
  fi
}

reconfigure_failure_handler() {
  local rc="$1"
  trap - EXIT ERR INT TERM
  [ "$RECONFIGURE_ACTIVE" -eq 1 ] || exit "$rc"
  error "带宽重配置中断或失败（exit=${rc}）。"
  if recover_incomplete_reconfigure 'automatic-failure' "$rc"; then
    error '已自动恢复到重配置前的 VERIFIED 配置。'
  else
    error "自动恢复不完整；请保留 ${STATE_DIR} 并执行 status，再使用 recover 重试。"
  fi
  exit "$rc"
}

reconfigure_port_settings() {
  local requested_port old_port old_rtt old_buf old_mode target_network values_changed=false
  [ -n "$PORT_SPEED_MBPS_INPUT" ] ||
    die "$EXIT_USAGE" 'reconfigure 必须显式提供 PORT_SPEED_MBPS；通过总控请使用 dvt reconfigure --port <MBPS>。'
  [ -z "$BUFFER_TARGET_RTT_MS_INPUT" ] ||
    die "$EXIT_USAGE" 'reconfigure 只允许改变服务商端口带宽，不接受 BUFFER_TARGET_RTT_MS。'
  [ -z "$BUF_MAX_ENV_WAS_SET" ] ||
    die "$EXIT_USAGE" 'reconfigure 只允许改变服务商端口带宽，不接受 BUF_MAX；显式 buffer 将从现有状态保留。'
  [ "$UPDATE_PREFLIGHT" = '0' ] ||
    die "$EXIT_USAGE" 'reconfigure 不接受 UPDATE_PREFLIGHT=1；升级只读检查与带宽重配置是两个独立操作。'
  [[ "$PORT_SPEED_MBPS_INPUT" =~ ^[0-9]{1,5}$ ]] ||
    die "$EXIT_USAGE" 'PORT_SPEED_MBPS 必须是 1–10000 的整数。'
  requested_port=$((10#$PORT_SPEED_MBPS_INPUT))
  if [ "$requested_port" -lt 1 ] || [ "$requested_port" -gt 10000 ]; then
    die "$EXIT_USAGE" 'PORT_SPEED_MBPS 必须在 1–10000 之间。'
  fi

  ensure_required_tools
  check_supported_os
  check_resource_profile
  state_exists || die "$EXIT_CONFLICT" '当前主机没有本项目管理状态；请先执行 preflight/apply，而不是 reconfigure。'
  validate_state_file
  [ "$(state_get '.state')" = 'VERIFIED' ] || {
    if jq -e '.reconfigure | type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
      die "$EXIT_CONFLICT" '检测到未完成的带宽重配置事务；请先执行 recover。'
    fi
    die "$EXIT_CONFLICT" "reconfigure 只接受 VERIFIED；当前状态为 $(state_get '.state')。"
  }
  reconfigure_source_state_is_valid ||
    die "$EXIT_CONFLICT" '现有 VERIFIED 状态缺少有效网络字段、sysctl 唯一所有权或当前 profile 的缓冲参数契约。'

  old_port="$(state_get '.network.port_speed_mbps')"
  old_rtt="$(state_get '.network.target_rtt_ms')"
  old_buf="$(state_get '.network.buffer_max_bytes')"
  old_mode="$(state_get '.network.buffer_mode')"

  PORT_SPEED_MBPS_INPUT="$old_port"
  BUFFER_TARGET_RTT_MS_INPUT="$old_rtt"
  if [ "$old_mode" = 'explicit' ]; then BUF_MAX_INPUT="$old_buf"; else BUF_MAX_INPUT='auto'; fi
  validate_inputs
  if [ "$PORT_SPEED_MBPS" != "$old_port" ] || [ "$BUFFER_TARGET_RTT_MS" != "$old_rtt" ] ||
    [ "$BUF_MAX" != "$old_buf" ] || [ "$BUF_MAX_MODE" != "$old_mode" ]; then
    die "$EXIT_CONFLICT" '现有状态中的自动/显式缓冲结果不符合当前 profile 推导规则；拒绝重配置。'
  fi
  verify_settings || die "$EXIT_VERIFY" '重配置前完整验证失败；没有写入任何配置。'
  sysctl_profile_matches_network "$old_port" "$old_rtt" "$old_buf" ||
    die "$EXIT_CONFLICT" '现有 sysctl 管理文件与状态中的端口、RTT 或 buffer 语义不一致；拒绝重配置。'

  if [ "$requested_port" -eq "$old_port" ]; then
    info "端口带宽已经是 ${old_port} Mbps；完整验证通过，无需写入。"
    return 0
  fi

  if [ -e "$RECONFIGURE_STATE_BACKUP" ] || [ -L "$RECONFIGURE_STATE_BACKUP" ] ||
    [ -e "$RECONFIGURE_SYSCTL_BACKUP" ] || [ -L "$RECONFIGURE_SYSCTL_BACKUP" ]; then
    cleanup_reconfigure_backups ||
      die "$EXIT_CONFLICT" '检测到无法安全清理的旧重配置备份；拒绝覆盖。'
    info '已清理上一笔成功事务遗留的固定重配置备份。'
  fi

  PORT_SPEED_MBPS_INPUT="$requested_port"
  BUFFER_TARGET_RTT_MS_INPUT="$old_rtt"
  if [ "$old_mode" = 'explicit' ]; then BUF_MAX_INPUT="$old_buf"; else BUF_MAX_INPUT='auto'; fi
  validate_inputs
  target_network="$(jq -cn --argjson port "$PORT_SPEED_MBPS" --argjson rtt "$BUFFER_TARGET_RTT_MS" \
    --argjson numerator "$BUFFER_TARGET_NUMERATOR" --argjson denominator "$BUFFER_TARGET_DENOMINATOR" \
    --argjson buf "$BUF_MAX" --arg mode "$BUF_MAX_MODE" \
    '{port_speed_mbps:$port,target_rtt_ms:$rtt,buffer_target_numerator:$numerator,
      buffer_target_denominator:$denominator,buffer_max_bytes:$buf,buffer_mode:$mode}')" ||
    die "$EXIT_CONFLICT" '无法构造带宽重配置目标状态。'
  if [ "$BUF_MAX" != "$old_buf" ]; then values_changed=true; fi

  prepare_reconfigure_backups || die "$EXIT_CONFLICT" '无法建立并校验带宽重配置备份。'
  if ! begin_reconfigure_transaction "$target_network" "$values_changed"; then
    cleanup_reconfigure_backups || true
    die "$EXIT_CONFLICT" '无法原子记录 RECONFIGURING；原配置未写入。'
  fi
  RECONFIGURE_ACTIVE=1
  trap 'rc=$?; [ "$rc" -eq 0 ] || reconfigure_failure_handler "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  write_sysctl_profile || die "$EXIT_CONFLICT" '无法原子写入新的 sysctl 管理文件。'
  if [ "$values_changed" = true ]; then
    sysctl -p "$SYSCTL_FILE" >/dev/null || die "$EXIT_CONFLICT" '无法应用新的 socket buffer 参数。'
  fi
  update_reconfigure_candidate_state || die "$EXIT_CONFLICT" '无法记录带宽重配置候选状态和管理文件哈希。'
  verify_reconfigure_candidate || die "$EXIT_VERIFY" '带宽重配置候选完整验证失败。'
  finalize_reconfigure_state || die "$EXIT_CONFLICT" '候选验证通过，但无法原子提交 VERIFIED 状态。'

  RECONFIGURE_ACTIVE=0
  trap - EXIT ERR INT TERM
  cleanup_reconfigure_backups || warn '重配置已提交，但固定事务备份未能清理；下次重配置会先安全检查这些路径。'
  if [ "$values_changed" = true ]; then
    info "端口带宽已从 ${old_port} Mbps 重配置为 ${PORT_SPEED_MBPS} Mbps；socket buffer 已从 ${old_buf} 更新为 ${BUF_MAX} 字节。"
  else
    info "端口带宽已从 ${old_port} Mbps 重配置为 ${PORT_SPEED_MBPS} Mbps；有效 sysctl 值不变，未重写运行时参数。"
  fi
  info '未重建 qdisc、未修改 swap/journald/NOFILE。建议在后续维护窗口重启并再次执行 verify。'
}

apply_failure_handler() {
  local rc="$1"
  trap - EXIT ERR INT TERM
  [ "$APPLY_ACTIVE" -eq 1 ] || exit "$rc"
  error "应用中断或失败（exit=${rc}）。"
  if state_exists && rollback_internal 1; then
    error '自动回滚完成。'
  elif ! state_exists && cleanup_uncommitted_state; then
    error '事务状态尚未提交，未写入系统配置；不完整状态已清理。'
  else
    error "自动回滚不完整；请保留 ${STATE_DIR} 并执行 status。"
  fi
  exit "$rc"
}

apply_settings() {
  run_preflight apply
  if state_exists; then
    local state saved_version saved_port saved_rtt saved_buf
    state="$(state_get '.state')"
    saved_version="$(state_get '.script_version')"
    if [ "$saved_version" != "$SCRIPT_VERSION" ]; then
      die "$EXIT_CONFLICT" "已安装状态属于 ${saved_version}，当前脚本为 ${SCRIPT_VERSION}；verify 可继续只读核验，升级配置必须先 rollback。"
    fi
    saved_port="$(state_get '.network.port_speed_mbps')"; saved_rtt="$(state_get '.network.target_rtt_ms')"; saved_buf="$(state_get '.network.buffer_max_bytes')"
    if [ "$saved_port" != "$PORT_SPEED_MBPS" ] || [ "$saved_rtt" != "$BUFFER_TARGET_RTT_MS" ] || [ "$saved_buf" != "$BUF_MAX" ]; then
      die "$EXIT_CONFLICT" "已安装参数与当前参数不同：saved(port=${saved_port},rtt=${saved_rtt},buf=${saved_buf}) current(port=${PORT_SPEED_MBPS},rtt=${BUFFER_TARGET_RTT_MS},buf=${BUF_MAX})。本次 apply 尚未写入配置；若只是输入错误，请按已安装参数重试或直接执行 verify。确需改参时，请用 PURGE_CREATED_SWAP=1 执行 rollback，重启后再用新参数执行 preflight/apply。"
    fi
    if [ "$state" = 'VERIFIED' ]; then verify_settings || die "$EXIT_VERIFY" '已安装配置验证失败。'; info '配置已存在且验证通过，无需重复写入。'; return 0; fi
    die "$EXIT_CONFLICT" "存在状态 ${state}；重新应用前请先完成 rollback，保留 swap 时需显式 purge 后再 apply。"
  fi
  APPLY_ACTIVE=1
  trap 'rc=$?; [ "$rc" -eq 0 ] || apply_failure_handler "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  write_initial_state || die "$EXIT_CONFLICT" '无法建立初始事务状态。'
  state_set_phase 'APPLYING' || die "$EXIT_CONFLICT" '无法记录 APPLYING。'
  transfer_provider_sysctl_ownership || die "$EXIT_CONFLICT" '无法安全迁移厂商 sysctl 配置归属。'
  write_sysctl_profile || die "$EXIT_CONFLICT" '无法写入 sysctl 配置。'
  refresh_managed_files || die "$EXIT_CONFLICT" '无法记录 sysctl 文件所有权。'
  write_journal_profile || die "$EXIT_CONFLICT" '无法写入 journald 配置。'
  refresh_managed_files || die "$EXIT_CONFLICT" '无法记录 journald 文件所有权。'
  write_xui_dropin || die "$EXIT_CONFLICT" '无法预置 x-ui.service 的 LimitNOFILE drop-in。'
  refresh_managed_files || die "$EXIT_CONFLICT" '无法记录 x-ui.service drop-in 所有权。'
  write_fq_helper || die "$EXIT_CONFLICT" '无法写入或记录 fq helper。'
  apply_kernel_settings || die "$EXIT_CONFLICT" '无法应用内核或 systemd 配置。'
  create_swap_if_needed || die "$EXIT_CONFLICT" 'swap 处理失败。'
  state_set_phase 'APPLIED' || die "$EXIT_CONFLICT" '无法记录 APPLIED。'
  refresh_managed_files || die "$EXIT_CONFLICT" '无法刷新管理文件所有权。'
  if ! verify_settings; then
    die "$EXIT_VERIFY" '应用后验证失败。'
  fi
  state_set_phase 'VERIFIED' || die "$EXIT_CONFLICT" '无法记录 VERIFIED。'
  APPLY_ACTIVE=0
  trap - EXIT ERR INT TERM
  info '应用完成。建议重启后再次执行 verify。'
}

show_status() {
  ensure_required_tools
  check_supported_os
  if ! state_exists; then info 'State: UNMANAGED'; return 0; fi
  validate_state_file
  jq '{script_version,state,profile,network,reconfigure,swap,timestamps,managed_files}' "$STATE_FILE"
  if [ -e "$RECONFIGURE_FAILURE_EVIDENCE" ] || [ -L "$RECONFIGURE_FAILURE_EVIDENCE" ]; then
    if [ -f "$RECONFIGURE_FAILURE_EVIDENCE" ] && [ ! -L "$RECONFIGURE_FAILURE_EVIDENCE" ] &&
      [ "$(stat -c '%u' "$RECONFIGURE_FAILURE_EVIDENCE" 2>/dev/null || true)" = '0' ] &&
      jq -e 'type == "object" and .schema_version == 1' "$RECONFIGURE_FAILURE_EVIDENCE" >/dev/null 2>&1; then
      jq '{last_reconfigure_failure:.}' "$RECONFIGURE_FAILURE_EVIDENCE"
    else
      warn "带宽重配置失败证据类型、所有权或 JSON 无效：${RECONFIGURE_FAILURE_EVIDENCE}"
    fi
  fi
  printf '[runtime] congestion_control=%s default_qdisc=%s\n' \
    "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" \
    "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  tc qdisc show 2>/dev/null || true
  swapon --show 2>/dev/null || true
  ss -lntup 2>/dev/null || true
}

softnet_snapshot() {
  local source="${1:-/proc/net/softnet_stat}"
  local cpu=0 processed dropped squeezed
  while IFS=$' \t' read -r processed dropped squeezed _; do
    [ -n "$processed" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$cpu" \
      "$((16#$processed))" "$((16#$dropped))" "$((16#$squeezed))"
    cpu=$((cpu + 1))
  done <"$source"
}

cpu_snapshot() {
  local source="${1:-/proc/stat}"
  awk '$1 == "cpu" {
    printf "user\t%s\nnice\t%s\nsystem\t%s\nidle\t%s\niowait\t%s\nirq\t%s\nsoftirq\t%s\nsteal\t%s\n", \
      $2+0, $3+0, $4+0, $5+0, $6+0, $7+0, $8+0, $9+0
    exit
  }' "$source"
}

show_cpu_delta() {
  local before="$1" after="$2" prefix="$3"
  awk -F '\t' -v prefix="$prefix" '
    NR == FNR {old[$1]=$2; next}
    {
      delta[$1]=$2-(old[$1]+0)
      total+=delta[$1]
    }
    END {
      printf "[%s] total_ticks=%d", prefix, total
      for (i=1; i<=8; i++) {
        key=(i==1 ? "user" : i==2 ? "nice" : i==3 ? "system" : i==4 ? "idle" : i==5 ? "iowait" : i==6 ? "irq" : i==7 ? "softirq" : "steal")
        pct=(total > 0 ? delta[key]*100/total : 0)
        printf " %s_ticks=%d %s_pct=%.2f", key, delta[key], key, pct
      }
      printf "\n"
    }
  ' "$before" "$after"
}

link_counter_snapshot() {
  local ifaces_file="$1" sys_class_root="${2:-/sys/class/net}" iface stat value
  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    for stat in rx_bytes rx_packets rx_dropped rx_errors tx_bytes tx_packets tx_dropped tx_errors; do
      [ -r "${sys_class_root}/${iface}/statistics/${stat}" ] || continue
      IFS= read -r value <"${sys_class_root}/${iface}/statistics/${stat}" || continue
      [[ "$value" =~ ^[0-9]+$ ]] || continue
      printf '%s.%s\t%s\n' "$iface" "$stat" "$value"
    done
  done <"$ifaces_file"
}

ethtool_counter_snapshot() {
  local ifaces_file="$1" iface
  command -v ethtool >/dev/null 2>&1 || return 0
  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    ethtool -S "$iface" 2>/dev/null | awk -v iface="$iface" '
      /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*[0-9]+[[:space:]]*$/ {
        key=$1
        sub(/:$/, "", key)
        lower=tolower(key)
        if (lower ~ /(drop|discard|miss|error|timeout|no.?buffer|overrun)/) {
          print iface "." key "\t" $2
        }
      }
    '
  done <"$ifaces_file"
}

tcp_counter_snapshot() {
  local snmp_file="${1:-/proc/net/snmp}" netstat_file="${2:-/proc/net/netstat}"
  awk '
    FNR % 2 == 1 {
      prefix=$1
      sub(/:$/, "", prefix)
      for (i=2; i<=NF; i++) header[i]=$i
      next
    }
    {
      prefix=$1
      sub(/:$/, "", prefix)
      for (i=2; i<=NF; i++) {
        key=prefix header[i]
        if (key ~ /^(IpInDiscards|IpOutDiscards|TcpRetransSegs|TcpExtListenDrops|TcpExtListenOverflows|TcpExtTCPLostRetransmit|TcpExtTCPTimeouts|TcpExtTCPSpuriousRTOs|TcpExtTCPSynRetrans|TcpExtTCPFastOpenActive|TcpExtTCPFastOpenActiveFail|TcpExtTCPFastOpenPassive|TcpExtTCPFastOpenPassiveFail|TcpExtTCPFastOpenListenOverflow)$/) {
          print key "\t" $i
        }
      }
    }
  ' "$snmp_file" "$netstat_file" 2>/dev/null
}

show_counter_delta() {
  local before="$1" after="$2" prefix="$3"
  awk -F '\t' -v prefix="$prefix" '
    NR == FNR {old[$1]=$2; next}
    {delta=$2-(old[$1]+0); printf "[%s] %s=%d\n", prefix, $1, delta}
  ' "$before" "$after"
}

counter_delta_json() {
  local before="$1" after="$2"
  awk -F '\t' '
    function valid_row(key, value) {
      return key != "" && value ~ /^[0-9]+$/
    }
    FILENAME == ARGV[1] {
      if (!valid_row($1, $2) || ($1 in old)) exit 40
      old[$1]=$2
      old_count++
      next
    }
    {
      if (!valid_row($1, $2) || ($1 in seen_after)) exit 41
      if (!($1 in old)) exit 42
      seen_after[$1]=1
      after_count++
      delta=$2-old[$1]
      if (delta < 0) exit 43
      output[after_count]=$1 "\t" delta
    }
    END {
      if (old_count == 0 || after_count == 0 || old_count != after_count) exit 44
      for (key in old) if (!(key in seen_after)) exit 45
      for (i=1; i<=after_count; i++) print output[i]
    }
  ' "$before" "$after" |
    jq -Rn '[inputs | split("\t") | {key:.[0],value:(.[1] | tonumber)}] | from_entries'
}

link_total_delta() {
  local before="$1" after="$2" suffix="$3"
  local delta_json
  delta_json="$(counter_delta_json "$before" "$after")" || return "$EXIT_VERIFY"
  jq -er --arg suffix "$suffix" '
    [. | to_entries[] | select(.key | endswith($suffix)) | .value] |
    if length > 0 then add else error("required link counters are missing") end
  ' <<<"$delta_json"
}

qdisc_counter_snapshot() {
  local ifaces_file="$1" iface
  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    tc -s -d qdisc show dev "$iface" 2>/dev/null |
      awk -v iface="$iface" '
        /^qdisc / {
          kind=$2
          handle=$3
          scope="other"
          for (header_index=4; header_index<=NF; header_index++) {
            if ($header_index == "root") scope="root"
            else if ($header_index == "parent" &&
                     ($(header_index+1) ~ /^:[0-9]+$/ ||
                      $(header_index+1) ~ /^[0-9]+:[0-9]+$/) &&
                     kind != "ingress" && kind != "clsact") scope="leaf"
          }
          key=iface "." scope "." kind "." handle
          active=1
          next
        }
        active && /^[[:space:]]*Sent / {
          line=$0
          gsub(/[(),]/, "", line)
          count=split(line, field, /[[:space:]]+/)
          bytes=packets=dropped=overlimits=requeues=""
          for (i=1; i<=count; i++) {
            if (field[i] == "Sent") bytes=field[i+1]
            else if (field[i] == "bytes") packets=field[i+1]
            else if (field[i] == "dropped") dropped=field[i+1]
            else if (field[i] == "overlimits") overlimits=field[i+1]
            else if (field[i] == "requeues") requeues=field[i+1]
          }
          if (bytes !~ /^[0-9]+$/ || packets !~ /^[0-9]+$/ || dropped !~ /^[0-9]+$/ ||
              overlimits !~ /^[0-9]+$/ || requeues !~ /^[0-9]+$/) exit 46
          print key ".bytes\t" bytes
          print key ".packets\t" packets
          print key ".dropped\t" dropped
          print key ".overlimits\t" overlimits
          print key ".requeues\t" requeues
          active=0
          emitted++
        }
        END {if (emitted == 0) exit 47}
      '
  done <"$ifaces_file"
}

build_benchmark_phase_summary() {
  local label="$1" reverse="$2" tmp_dir="$3"
  local iperf_json="${tmp_dir}/${label}.iperf3.json"
  local output_tmp="${tmp_dir}/${label}.summary.json.tmp"
  local output="${tmp_dir}/${label}.summary.json"
  local tcp_delta link_delta qdisc_delta tx_bytes rx_bytes
  tcp_delta="$(counter_delta_json "${tmp_dir}/${label}.tcp.before" "${tmp_dir}/${label}.tcp.after")" || return "$EXIT_VERIFY"
  link_delta="$(counter_delta_json "${tmp_dir}/${label}.link.before" "${tmp_dir}/${label}.link.after")" || return "$EXIT_VERIFY"
  qdisc_delta="$(counter_delta_json "${tmp_dir}/${label}.qdisc.before" "${tmp_dir}/${label}.qdisc.after")" || return "$EXIT_VERIFY"
  tx_bytes="$(link_total_delta "${tmp_dir}/${label}.link.before" "${tmp_dir}/${label}.link.after" '.tx_bytes')" || return "$EXIT_VERIFY"
  rx_bytes="$(link_total_delta "${tmp_dir}/${label}.link.before" "${tmp_dir}/${label}.link.after" '.rx_bytes')" || return "$EXIT_VERIFY"

  jq -e --arg phase_label "$label" --argjson reverse "$reverse" \
    --argjson expected_seconds "$BENCHMARK_SECONDS_RESOLVED" \
    --argjson tcp_delta "$tcp_delta" --argjson link_delta "$link_delta" \
    --argjson qdisc_delta "$qdisc_delta" --argjson host_tx_bytes "$tx_bytes" \
    --argjson host_rx_bytes "$rx_bytes" '
      def metric_total($entries; $suffix):
        [$entries[] | select(.key | endswith($suffix)) | .value] |
        if length > 0 then add else error("qdisc metric is missing: " + $suffix) end;
      def totals($entries):
        (metric_total($entries; ".bytes")) as $bytes |
        (metric_total($entries; ".packets")) as $packets |
        (metric_total($entries; ".dropped")) as $dropped |
        (metric_total($entries; ".overlimits")) as $overlimits |
        (metric_total($entries; ".requeues")) as $requeues |
        {
          bytes_delta:$bytes,
          packets_delta:$packets,
          dropped_delta:$dropped,
          overlimits_delta:$overlimits,
          requeues_delta:$requeues,
          dropped_per_gib:(if $bytes > 0 then ($dropped * 1073741824 / $bytes) else null end),
          overlimits_per_gib:(if $bytes > 0 then ($overlimits * 1073741824 / $bytes) else null end)
        };
      def qdisc_interfaces($entries; $scope; $kind):
        [$entries[] |
          select(.key | contains("." + $scope + "." + $kind + ".")) |
          (.key | split("." + $scope + "." + $kind + ".")[0])] | unique;
      def absolute: if . < 0 then -. else . end;
      def relative_error($reported; $computed):
        (($reported - $computed) | absolute) /
        ([$reported, $computed] | map(absolute) | max);
      (.end.sum_sent // null) as $sent |
      (.end.sum_received // null) as $received |
      ($qdisc_delta | to_entries | map(select(.key | contains(".root.")))) as $qdisc_root_entries |
      ($qdisc_delta | to_entries | map(select(.key | contains(".leaf.")))) as $qdisc_leaf_entries |
      ($qdisc_root_entries | length > 0) as $has_root |
      ($qdisc_leaf_entries | length > 0) as $has_leaf |
      ($qdisc_root_entries | any(.key | contains(".root.mq."))) as $root_is_mq |
      ($qdisc_root_entries | any(.key | contains(".root.htb."))) as $root_is_htb |
      (qdisc_interfaces($qdisc_root_entries; "root"; "htb")) as $htb_root_interfaces |
      (qdisc_interfaces($qdisc_leaf_entries; "leaf"; "fq")) as $fq_leaf_interfaces |
      (all($htb_root_interfaces[]; . as $iface | $fq_leaf_interfaces | index($iface) != null)) as $htb_fq_leaf_complete |
      if (.error? != null) then
        error("iperf3 JSON reports an error")
      elif ($sent | type) != "object" or ($received | type) != "object" then
        error("iperf3 JSON lacks end.sum_sent or end.sum_received")
      elif ($sent.bytes | type) != "number" or $sent.bytes <= 0 or
           ($sent.bits_per_second | type) != "number" or $sent.bits_per_second < 0 or
           ($sent.retransmits | type) != "number" or $sent.retransmits < 0 or
           ($sent.seconds | type) != "number" or $sent.seconds <= 0 or
           ($received.bytes | type) != "number" or $received.bytes <= 0 or
           ($received.bits_per_second | type) != "number" or $received.bits_per_second < 0 or
           ($received.seconds | type) != "number" or $received.seconds <= 0 then
        error("iperf3 JSON contains missing, non-numeric or invalid summary fields")
      elif ($has_root | not) then
        error("root qdisc counters are missing")
      elif $root_is_mq and ($has_leaf | not) then
        error("mq root exists but managed leaf qdisc counters are missing")
      elif $root_is_htb and (($has_leaf | not) or ($htb_fq_leaf_complete | not)) then
        error("htb root exists but its expected fq leaf qdisc counters are missing")
      else
        ($sent.bytes * 8 / $sent.seconds) as $sent_computed_bps |
        ($received.bytes * 8 / $received.seconds) as $received_computed_bps |
        (relative_error($sent.bits_per_second; $sent_computed_bps)) as $sent_bps_error |
        (relative_error($received.bits_per_second; $received_computed_bps)) as $received_bps_error |
        ([0.25, ($expected_seconds * 0.05)] | max) as $duration_tolerance |
        ([1048576, ($sent.bytes * 0.01)] | max) as $receiver_bytes_tolerance |
        ([
          if (($sent.seconds - $expected_seconds) | absolute) > $duration_tolerance
          then "sender-duration-mismatch" else empty end,
          if (($received.seconds - $expected_seconds) | absolute) > $duration_tolerance
          then "receiver-duration-mismatch" else empty end,
          if (($sent.seconds - $received.seconds) | absolute) > $duration_tolerance
          then "sender-receiver-window-mismatch" else empty end,
          if $sent_bps_error > 0.01 then "sender-bps-arithmetic-mismatch" else empty end,
          if $received_bps_error > 0.01 then "receiver-bps-arithmetic-mismatch" else empty end,
          if $received.bytes > ($sent.bytes + $receiver_bytes_tolerance)
          then "receiver-bytes-exceed-sender-tolerance" else empty end
        ]) as $measurement_issues |
        (totals($qdisc_root_entries)) as $root_totals |
        (if $has_leaf then totals($qdisc_leaf_entries) else null end) as $leaf_totals |
        (($root_totals.dropped_delta > 0) or
         ($root_totals.requeues_delta > 0) or
         ($leaf_totals != null and
          (($leaf_totals.dropped_delta > 0) or ($leaf_totals.requeues_delta > 0)))) as $qdisc_anomaly |
        {
          schema_version:3,
          direction:$phase_label,
          reverse:($reverse == 1),
          measurement_window:{
            status:(if ($measurement_issues | length) == 0 then "VALID" else "INVALID_MEASUREMENT_WINDOW" end),
            valid:(($measurement_issues | length) == 0),
            expected_seconds:$expected_seconds,
            duration_tolerance_seconds:$duration_tolerance,
            bitrate_relative_error_tolerance:0.01,
            receiver_bytes_tolerance:$receiver_bytes_tolerance,
            issues:$measurement_issues
          },
          sender:{
            bytes:$sent.bytes,
            seconds:$sent.seconds,
            bits_per_second:$sent.bits_per_second,
            computed_bits_per_second:$sent_computed_bps,
            bits_per_second_relative_error:$sent_bps_error,
            mbps:($sent.bits_per_second/1000000),
            retransmits:$sent.retransmits,
            retransmits_per_gib:($sent.retransmits * 1073741824 / $sent.bytes)
          },
          receiver:{
            bytes:$received.bytes,
            seconds:$received.seconds,
            bits_per_second:$received.bits_per_second,
            computed_bits_per_second:$received_computed_bps,
            bits_per_second_relative_error:$received_bps_error,
            mbps:($received.bits_per_second/1000000)
          },
          host:{tx_bytes_delta:$host_tx_bytes,rx_bytes_delta:$host_rx_bytes,tcp_delta:$tcp_delta,link_delta:$link_delta},
          qdisc_delta:$qdisc_delta,
          qdisc_coverage:{
            aggregation_source:(if $root_is_mq then "leaf" else "root" end),
            topology:(if $root_is_htb then "htb-fq" elif $root_is_mq then "mq-leaves" else "root-only" end),
            has_root:$has_root,has_leaf:$has_leaf,root_is_mq:$root_is_mq,root_is_htb:$root_is_htb,
            htb_root_interfaces:$htb_root_interfaces,fq_leaf_interfaces:$fq_leaf_interfaces,
            htb_fq_leaf_complete:$htb_fq_leaf_complete
          },
          qdisc_root_totals:$root_totals,
          qdisc_leaf_totals:$leaf_totals,
          qdisc_active_totals:(if $root_is_mq then totals($qdisc_leaf_entries) else totals($qdisc_root_entries) end),
          qdisc_health:{
            status:(if $qdisc_anomaly then "LOCAL_QUEUE_ANOMALY" else "NO_LOCAL_QUEUE_DROP_OR_REQUEUE" end),
            any_drop_or_requeue:$qdisc_anomaly,
            root:{dropped_delta:$root_totals.dropped_delta,requeues_delta:$root_totals.requeues_delta},
            leaf:(if $leaf_totals == null then null else
              {dropped_delta:$leaf_totals.dropped_delta,requeues_delta:$leaf_totals.requeues_delta} end)
          },
          interpretation:{
            iperf_sender_retransmits:"sender-side iperf3 statistic for this direction",
            host_tcp_delta:"host-wide counters; may include unrelated traffic",
            qdisc_active_totals:"leaf counters are used for mq traffic totals; otherwise root counters are used; root and leaf bytes are never added",
            qdisc_health:"root and leaf drops/requeues are checked independently; local qdisc health does not describe downstream or remote-path loss"
          }
        }
      end
    ' "$iperf_json" >"$output_tmp" || { rm -f -- "$output_tmp"; return "$EXIT_VERIFY"; }
  chmod 0600 "$output_tmp" || { rm -f -- "$output_tmp"; return "$EXIT_VERIFY"; }
  mv -f -- "$output_tmp" "$output" || return "$EXIT_VERIFY"
  printf '[benchmark-%s-summary] sender_mbps=%s sender_retransmits=%s sender_retransmits_per_gib=%s host_tcp_retrans_delta=%s host_tx_bytes_delta=%s qdisc_root_drop_delta=%s qdisc_leaf_drop_delta=%s qdisc_health=%s qdisc_source=%s\n' \
    "$label" \
    "$(jq -r '.sender.mbps // "null"' "$output")" \
    "$(jq -r '.sender.retransmits // "null"' "$output")" \
    "$(jq -r '.sender.retransmits_per_gib // "null"' "$output")" \
    "$(jq -r '.host.tcp_delta.TcpRetransSegs // "null"' "$output")" \
    "$(jq -r '.host.tx_bytes_delta' "$output")" \
    "$(jq -r '.qdisc_root_totals.dropped_delta' "$output")" \
    "$(jq -r '.qdisc_leaf_totals.dropped_delta // "null"' "$output")" \
    "$(jq -r '.qdisc_health.status' "$output")" \
    "$(jq -r '.qdisc_coverage.aggregation_source' "$output")"
}

show_softnet_delta() {
  local before="$1" after="$2"
  awk -F '\t' '
    NR == FNR {processed[$1]=$2; dropped[$1]=$3; squeezed[$1]=$4; next}
    {
      printf "[softnet-delta] cpu=%s processed=%d dropped=%d time_squeeze=%d\n",
        $1, $2-(processed[$1]+0), $3-(dropped[$1]+0), $4-(squeezed[$1]+0)
    }
  ' "$before" "$after"
}

show_proxy_process_evidence() {
  local phase="$1" unit active main_pid role pid fd_count row
  local -a pids=()
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    [ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)" = 'loaded' ] || continue
    active="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
    main_pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
    printf '[process-%s] unit=%s active=%s main_pid=%s\n' "$phase" "$unit" "${active:-unknown}" "${main_pid:-0}"
    [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] || continue
    for role in main child; do
      if [ "$role" = 'main' ]; then
        pids=("$main_pid")
      else
        mapfile -t pids < <(pgrep -P "$main_pid" 2>/dev/null || true)
      fi
      for pid in "${pids[@]}"; do
        [ -r "/proc/${pid}/stat" ] || continue
        fd_count="$({ find "/proc/${pid}/fd" -mindepth 1 -maxdepth 1 2>/dev/null || true; } | wc -l)"
        row="$({ ps -p "$pid" -o pid=,ppid=,etimes=,time=,rss=,nlwp=,comm= 2>/dev/null || true; } | awk '{$1=$1; print; exit}')"
        [ -n "$row" ] || continue
        printf '[process-%s] unit=%s role=%s fd_count=%s ps=%s\n' "$phase" "$unit" "$role" "$fd_count" "$row"
      done
    done
  done < <(profile_service_units)
}

show_queue_cpu_evidence() {
  local iface="$1" queue file value
  for queue in "/sys/class/net/${iface}/queues"/rx-*; do
    [ -d "$queue" ] || continue
    printf '[queue] %s/%s' "$iface" "${queue##*/}"
    for file in rps_cpus rps_flow_cnt; do
      if [ -r "${queue}/${file}" ]; then
        IFS= read -r value <"${queue}/${file}" || value='unreadable'
        printf ' %s=%s' "$file" "$value"
      fi
    done
    printf '\n'
  done
  for queue in "/sys/class/net/${iface}/queues"/tx-*; do
    [ -d "$queue" ] || continue
    printf '[queue] %s/%s' "$iface" "${queue##*/}"
    for file in xps_cpus xps_rxqs; do
      if [ -r "${queue}/${file}" ]; then
        IFS= read -r value <"${queue}/${file}" || value='unreadable'
        printf ' %s=%s' "$file" "$value"
      fi
    done
    printf '\n'
  done
  awk -v iface="$iface" 'index($0, iface) {print "[interrupt] " $0}' /proc/interrupts 2>/dev/null || true
}

show_xray_socket_options() {
  local config='/usr/local/x-ui/bin/config.json' tfo keep_idle keep_interval
  if [ ! -r "$config" ]; then
    printf '[xray] generated_config=%s status=not-readable-or-not-installed\n' "$config"
    return 0
  fi
  if ! jq -e 'type == "object"' "$config" >/dev/null 2>&1; then
    printf '[xray] generated_config=%s status=invalid-json\n' "$config"
    return 0
  fi
  tfo="$(jq -r '[.. | objects | select(has("tcpFastOpen")) | .tcpFastOpen] | unique | map(tostring) | join(",")' "$config")"
  keep_idle="$(jq -r '[.. | objects | select(has("tcpKeepAliveIdle")) | .tcpKeepAliveIdle] | unique | map(tostring) | join(",")' "$config")"
  keep_interval="$(jq -r '[.. | objects | select(has("tcpKeepAliveInterval")) | .tcpKeepAliveInterval] | unique | map(tostring) | join(",")' "$config")"
  if [ -n "$tfo" ]; then
    printf '[xray] tcpFastOpen=%s source=generated-config\n' "$tfo"
  else
    printf '[xray] tcpFastOpen=not-explicit; kernel net.ipv4.tcp_fastopen alone does not prove Xray listener TFO\n'
  fi
  printf '[xray] tcpKeepAliveIdle=%s tcpKeepAliveInterval=%s source=generated-config\n' \
    "${keep_idle:-not-explicit}" "${keep_interval:-not-explicit}"
}

show_readonly_tcp_settings() {
  local window_scaling moderate_rcvbuf slow_start_after_idle mtu_probing limit_output_bytes notsent_lowat

  window_scaling="$(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null || true)"
  moderate_rcvbuf="$(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null || true)"
  slow_start_after_idle="$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || true)"
  mtu_probing="$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || true)"
  limit_output_bytes="$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || true)"
  notsent_lowat="$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || true)"

  printf '[tcp-readonly] window_scaling=%s moderate_rcvbuf=%s slow_start_after_idle=%s mtu_probing=%s limit_output_bytes=%s notsent_lowat=%s\n' \
    "$window_scaling" "$moderate_rcvbuf" "$slow_start_after_idle" "$mtu_probing" "$limit_output_bytes" "$notsent_lowat"

  if [ "$window_scaling" != '1' ]; then
    if [ -n "$window_scaling" ]; then
      warn "只读诊断：net.ipv4.tcp_window_scaling 当前值为 ${window_scaling}，预期值为 1；该键不受本项目管理，脚本不会自动修改。"
    else
      warn '只读诊断：无法确认 net.ipv4.tcp_window_scaling 当前值，预期值为 1；该键不受本项目管理，脚本不会自动修改。'
    fi
  fi
  if [ "$moderate_rcvbuf" != '1' ]; then
    if [ -n "$moderate_rcvbuf" ]; then
      warn "只读诊断：net.ipv4.tcp_moderate_rcvbuf 当前值为 ${moderate_rcvbuf}，预期值为 1；该键不受本项目管理，脚本不会自动修改。"
    else
      warn '只读诊断：无法确认 net.ipv4.tcp_moderate_rcvbuf 当前值，预期值为 1；该键不受本项目管理，脚本不会自动修改。'
    fi
  fi
}

show_diagnostics() {
  local diagnostic_state='UNMANAGED' iface tmp_dir
  ensure_required_tools
  check_supported_os
  if ! report_sysctl_conflicts; then
    warn '只读诊断发现重复 sysctl 配置归属；请先按文件归属合并或移除，再执行 verify/apply。'
  fi
  [[ "$DIAG_INTERVAL_SECONDS" =~ ^[0-9]{1,2}$ ]] ||
    die "$EXIT_USAGE" 'DIAG_INTERVAL_SECONDS 必须是 1–60 的整数。'
  DIAG_INTERVAL_SECONDS=$((10#$DIAG_INTERVAL_SECONDS))
  if [ "$DIAG_INTERVAL_SECONDS" -lt 1 ] || [ "$DIAG_INTERVAL_SECONDS" -gt 60 ]; then
    die "$EXIT_USAGE" 'DIAG_INTERVAL_SECONDS 必须在 1–60 之间。'
  fi
  is_bool "$DIAG_INCLUDE_SOCKET_DETAILS" ||
    die "$EXIT_USAGE" 'DIAG_INCLUDE_SOCKET_DETAILS 只能为 0 或 1。'
  umask 077
  tmp_dir="$(mktemp -d)" || die "$EXIT_UNSUPPORTED" '无法创建诊断临时目录。'
  trap 'rm -rf -- "$tmp_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  default_route_ifaces >"${tmp_dir}/ifaces"
  softnet_snapshot '/proc/net/softnet_stat' >"${tmp_dir}/softnet.before"
  tcp_counter_snapshot '/proc/net/snmp' '/proc/net/netstat' >"${tmp_dir}/tcp.before"
  cpu_snapshot '/proc/stat' >"${tmp_dir}/cpu.before"
  link_counter_snapshot "${tmp_dir}/ifaces" >"${tmp_dir}/link.before"
  ethtool_counter_snapshot "${tmp_dir}/ifaces" >"${tmp_dir}/ethtool.before"
  if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
    diagnostic_state="$(jq -er '.state | select(type == "string")' "$STATE_FILE" 2>/dev/null || printf 'INVALID')"
  fi
  info '只读诊断：不会修改 sysctl、qdisc、systemd、swap 或代理服务。'
  printf '[system] version=%s profile=%s kernel=%s arch=%s cpu=%s memory_mib=%s\n' \
    "$SCRIPT_VERSION" "$PROFILE_ID" "$(uname -r)" "$(uname -m)" "$(nproc)" "$(memory_mib)"
  printf '[system] root_fs=%s state=%s\n' \
    "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" \
    "$diagnostic_state"
  printf '[network] congestion_control=%s available_cc=%s default_qdisc=%s\n' \
    "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" \
    "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)" \
    "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  show_readonly_tcp_settings
  ip -br address show 2>/dev/null || true
  ip -4 route show default 2>/dev/null || true
  ip -6 route show default 2>/dev/null || true
  detect_policy_routing
  show_policy_routing_evidence
  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    printf '[interface] %s rx_queues=%s tx_queues=%s\n' "$iface" \
      "$(find "/sys/class/net/${iface}/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | wc -l)" \
      "$(find "/sys/class/net/${iface}/queues" -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | wc -l)"
    ip -s link show dev "$iface" 2>/dev/null || true
    printf '[qdisc-before] interface=%s\n' "$iface"
    tc -s -d qdisc show dev "$iface" 2>/dev/null || true
    show_queue_cpu_evidence "$iface"
    if command -v ethtool >/dev/null 2>&1; then
      ethtool -k "$iface" 2>/dev/null | grep -E '^(receive-hashing|tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload):' || true
      ethtool -S "$iface" 2>/dev/null |
        grep -Ei 'drop|discard|miss|error|timeout|no.?buffer|overrun' || true
    fi
  done <"${tmp_dir}/ifaces"
  show_xray_socket_options
  show_proxy_process_evidence before
  ss -s 2>/dev/null || true
  if [ "$DIAG_INCLUDE_SOCKET_DETAILS" = '1' ]; then
    ss -tinp 2>/dev/null || true
  fi
  info "开始 ${DIAG_INTERVAL_SECONDS} 秒增量采样；期间可复现实际 VLESS + REALITY + TCP 负载。"
  sleep "$DIAG_INTERVAL_SECONDS"
  softnet_snapshot '/proc/net/softnet_stat' >"${tmp_dir}/softnet.after"
  tcp_counter_snapshot '/proc/net/snmp' '/proc/net/netstat' >"${tmp_dir}/tcp.after"
  cpu_snapshot '/proc/stat' >"${tmp_dir}/cpu.after"
  link_counter_snapshot "${tmp_dir}/ifaces" >"${tmp_dir}/link.after"
  ethtool_counter_snapshot "${tmp_dir}/ifaces" >"${tmp_dir}/ethtool.after"
  show_counter_delta "${tmp_dir}/tcp.before" "${tmp_dir}/tcp.after" 'tcp-delta'
  show_softnet_delta "${tmp_dir}/softnet.before" "${tmp_dir}/softnet.after"
  show_cpu_delta "${tmp_dir}/cpu.before" "${tmp_dir}/cpu.after" 'cpu-delta'
  show_counter_delta "${tmp_dir}/link.before" "${tmp_dir}/link.after" 'link-delta'
  show_counter_delta "${tmp_dir}/ethtool.before" "${tmp_dir}/ethtool.after" 'ethtool-delta'
  show_proxy_process_evidence after
  ip -4 route show default 2>/dev/null || true
  ip -6 route show default 2>/dev/null || true
  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    printf '[qdisc-after] interface=%s\n' "$iface"
    tc -s -d qdisc show dev "$iface" 2>/dev/null || true
  done <"${tmp_dir}/ifaces"
  swapon --show 2>/dev/null || true
  rm -rf -- "$tmp_dir"
  trap - EXIT INT TERM
  info '诊断完成；增量计数是采样证据，不单独证明端到端业务性能。'
}

benchmark_reap_active_child() {
  local pid="${BENCHMARK_ACTIVE_CHILD_PID:-}" pgid="${BENCHMARK_ACTIVE_CHILD_PGID:-}" target='' attempt
  [ -n "$pid" ] || return 0
  if [[ "$pgid" =~ ^[0-9]+$ ]] && [ "$pgid" -gt 1 ] && [ "$pgid" = "$pid" ]; then
    if kill -0 -- "-${pgid}" 2>/dev/null; then
      target="-${pgid}"
    fi
  fi
  if [ -z "$target" ] && [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null; then
    target="$pid"
  fi
  if [ -n "$target" ]; then
    kill -TERM -- "$target" 2>/dev/null || true
    attempt=0
    while [ "$attempt" -lt "$BENCHMARK_TIMEOUT_TERMINATE_GRACE_SECONDS" ]; do
      kill -0 -- "$target" 2>/dev/null || break
      sleep 1
      attempt=$((attempt + 1))
    done
    if kill -0 -- "$target" 2>/dev/null; then
      kill -KILL -- "$target" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
  BENCHMARK_ACTIVE_CHILD_PID=''
  BENCHMARK_ACTIVE_CHILD_PGID=''
  return 0
}

benchmark_handle_signal() {
  local signal_name="$1" exit_code="$2"
  benchmark_failure_stage="signal-${signal_name}"
  benchmark_reap_active_child
  exit "$exit_code"
}

run_iperf3_with_timeout() {
  local output_file="$1"
  shift
  local rc=0 started_at="$SECONDS" elapsed=0
  BENCHMARK_ACTIVE_CHILD_PID=''
  BENCHMARK_ACTIVE_CHILD_PGID=''
  setsid timeout --foreground --signal=TERM \
    --kill-after="${BENCHMARK_TIMEOUT_TERMINATE_GRACE_SECONDS}s" \
    "${BENCHMARK_PHASE_TIMEOUT_RESOLVED}s" iperf3 "$@" >"$output_file" &
  BENCHMARK_ACTIVE_CHILD_PID=$!
  BENCHMARK_ACTIVE_CHILD_PGID="$BENCHMARK_ACTIVE_CHILD_PID"
  if wait "$BENCHMARK_ACTIVE_CHILD_PID"; then
    rc=0
  else
    rc=$?
  fi
  elapsed=$((SECONDS - started_at))
  if [ "$rc" -eq 0 ]; then
    BENCHMARK_ACTIVE_CHILD_PID=''
    BENCHMARK_ACTIVE_CHILD_PGID=''
  else
    benchmark_reap_active_child
  fi
  case "$rc" in
    124)
      warn "iperf3 超过 ${BENCHMARK_PHASE_TIMEOUT_RESOLVED} 秒硬上限；已终止隔离进程组并保留失败证据。"
      ;;
    137)
      if [ "$elapsed" -ge "$BENCHMARK_PHASE_TIMEOUT_RESOLVED" ]; then
        warn "iperf3 超过 ${BENCHMARK_PHASE_TIMEOUT_RESOLVED} 秒硬上限且 TERM 后仍未退出；已升级到 KILL、回收进程组并保留失败证据。"
      else
        warn 'iperf3 在硬上限前返回 137；进程可能收到外部 SIGKILL，已回收进程组并保留失败证据。'
      fi
      ;;
  esac
  return "$rc"
}

run_benchmark_phase() {
  local label="$1" reverse="$2" tmp_dir="$3" ifaces_file="$4"
  local current_rc=0 iface
  local -a rate_args=()
  if declare -p BENCHMARK_RATE_ARGS >/dev/null 2>&1; then
    rate_args=("${BENCHMARK_RATE_ARGS[@]}")
  fi
  softnet_snapshot '/proc/net/softnet_stat' >"${tmp_dir}/${label}.softnet.before" || return "$EXIT_VERIFY"
  tcp_counter_snapshot '/proc/net/snmp' '/proc/net/netstat' >"${tmp_dir}/${label}.tcp.before" || return "$EXIT_VERIFY"
  cpu_snapshot '/proc/stat' >"${tmp_dir}/${label}.cpu.before" || return "$EXIT_VERIFY"
  link_counter_snapshot "$ifaces_file" >"${tmp_dir}/${label}.link.before" || return "$EXIT_VERIFY"
  qdisc_counter_snapshot "$ifaces_file" >"${tmp_dir}/${label}.qdisc.before" || return "$EXIT_VERIFY"
  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    printf '[benchmark-%s-qdisc-before] interface=%s\n' "$label" "$iface"
    tc -s -d qdisc show dev "$iface" 2>/dev/null | tee -a "${tmp_dir}/${label}.qdisc.raw.before" || true
  done <"$ifaces_file"

  if [ "$reverse" = '1' ]; then
    if run_iperf3_with_timeout "${tmp_dir}/${label}.iperf3.json" \
      --client "$BENCHMARK_HOST_RESOLVED" --port "$BENCHMARK_PORT_RESOLVED" \
      --time "$BENCHMARK_SECONDS_RESOLVED" --omit "$BENCHMARK_OMIT_RESOLVED" \
      --parallel "$BENCHMARK_PARALLEL_RESOLVED" "${BENCHMARK_FAMILY_ARGS[@]}" \
      "${rate_args[@]}" --reverse --json; then
      current_rc=0
    else
      current_rc=$?
    fi
  else
    if run_iperf3_with_timeout "${tmp_dir}/${label}.iperf3.json" \
      --client "$BENCHMARK_HOST_RESOLVED" --port "$BENCHMARK_PORT_RESOLVED" \
      --time "$BENCHMARK_SECONDS_RESOLVED" --omit "$BENCHMARK_OMIT_RESOLVED" \
      --parallel "$BENCHMARK_PARALLEL_RESOLVED" "${BENCHMARK_FAMILY_ARGS[@]}" \
      "${rate_args[@]}" --json; then
      current_rc=0
    else
      current_rc=$?
    fi
  fi
  cat "${tmp_dir}/${label}.iperf3.json" 2>/dev/null || true

  softnet_snapshot '/proc/net/softnet_stat' >"${tmp_dir}/${label}.softnet.after" || current_rc="$EXIT_VERIFY"
  tcp_counter_snapshot '/proc/net/snmp' '/proc/net/netstat' >"${tmp_dir}/${label}.tcp.after" || current_rc="$EXIT_VERIFY"
  cpu_snapshot '/proc/stat' >"${tmp_dir}/${label}.cpu.after" || current_rc="$EXIT_VERIFY"
  link_counter_snapshot "$ifaces_file" >"${tmp_dir}/${label}.link.after" || current_rc="$EXIT_VERIFY"
  qdisc_counter_snapshot "$ifaces_file" >"${tmp_dir}/${label}.qdisc.after" || current_rc="$EXIT_VERIFY"
  show_counter_delta "${tmp_dir}/${label}.tcp.before" "${tmp_dir}/${label}.tcp.after" "benchmark-${label}-tcp-delta" || current_rc="$EXIT_VERIFY"
  show_softnet_delta "${tmp_dir}/${label}.softnet.before" "${tmp_dir}/${label}.softnet.after" |
    sed "s/^\[softnet-delta\]/[benchmark-${label}-softnet-delta]/" || current_rc="$EXIT_VERIFY"
  show_cpu_delta "${tmp_dir}/${label}.cpu.before" "${tmp_dir}/${label}.cpu.after" "benchmark-${label}-cpu-delta" || current_rc="$EXIT_VERIFY"
  show_counter_delta "${tmp_dir}/${label}.link.before" "${tmp_dir}/${label}.link.after" "benchmark-${label}-link-delta" || current_rc="$EXIT_VERIFY"
  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    printf '[benchmark-%s-qdisc-after] interface=%s\n' "$label" "$iface"
    tc -s -d qdisc show dev "$iface" 2>/dev/null | tee -a "${tmp_dir}/${label}.qdisc.raw.after" || true
  done <"$ifaces_file"
  if [ "$current_rc" -eq 0 ]; then
    build_benchmark_phase_summary "$label" "$reverse" "$tmp_dir" || current_rc="$EXIT_VERIFY"
  fi
  return "$current_rc"
}

benchmark_traffic_estimate_json() {
  local cap_mbps="$1" cap_source="$2" seconds="$3" omit="$4" direction="$5"
  local direction_count per_direction_seconds total_seconds upper_bound_bytes
  case "$direction" in
    upload | download) direction_count=1 ;;
    both) direction_count=2 ;;
    *) return 1 ;;
  esac
  per_direction_seconds=$((seconds + omit))
  total_seconds=$((per_direction_seconds * direction_count))
  if [ -z "$cap_mbps" ]; then
    jq -nc \
      --arg source unavailable \
      --argjson direction_count "$direction_count" \
      --argjson per_direction_seconds "$per_direction_seconds" \
      --argjson total_seconds "$total_seconds" \
      '{available:false,cap_mbps:null,cap_source:$source,
        direction_count:$direction_count,per_direction_seconds:$per_direction_seconds,
        total_seconds:$total_seconds,payload_upper_bound_bytes:null,
        protocol_overhead_included:false}'
    return
  fi
  [[ "$cap_mbps" =~ ^[0-9]+$ ]] || return 1
  upper_bound_bytes=$((cap_mbps * 125000 * total_seconds))
  jq -nc \
    --argjson cap_mbps "$cap_mbps" \
    --arg source "$cap_source" \
    --argjson direction_count "$direction_count" \
    --argjson per_direction_seconds "$per_direction_seconds" \
    --argjson total_seconds "$total_seconds" \
    --argjson upper_bound_bytes "$upper_bound_bytes" \
    '{available:true,cap_mbps:$cap_mbps,cap_source:$source,
      direction_count:$direction_count,per_direction_seconds:$per_direction_seconds,
      total_seconds:$total_seconds,payload_upper_bound_bytes:$upper_bound_bytes,
      payload_upper_bound_mib:($upper_bound_bytes/1048576),
      payload_upper_bound_gib:($upper_bound_bytes/1073741824),
      protocol_overhead_included:false}'
}

run_network_benchmark() {
  local host="${BENCHMARK_HOST:-}" port="${BENCHMARK_PORT:-5201}"
  local seconds="${BENCHMARK_SECONDS:-10}" parallel="${BENCHMARK_PARALLEL:-1}"
  local omit="${BENCHMARK_OMIT_SECONDS:-3}" family="${BENCHMARK_IP_FAMILY:-auto}"
  local direction="${BENCHMARK_DIRECTION:-both}" run_id="${BENCHMARK_RUN_ID:-}" output_dir="${BENCHMARK_OUTPUT_DIR:-}"
  local cap_input="${BENCHMARK_RATE_CAP_MBPS:-}" cap_mbps='' cap_source='unavailable' traffic_estimate
  local enforce_rate_cap="${BENCHMARK_ENFORCE_RATE_CAP:-0}" rate_cap_enforced=false rate_cap_per_stream_bps=0
  local phase_timeout="${BENCHMARK_PHASE_TIMEOUT_SECONDS:-}" phase_timeout_default=0
  local tmp_dir rc=0 current_rc=0 persistent_output=0 result_tmp manifest_sha result_sha trap_rc=0
  local benchmark_failure_stage='initialization'
  local script_hash state_phase state_network iperf_version boot_id
  local budget_bypass="${DVT_TRAFFIC_BUDGET_BYPASS:-0}" budget_tool="${DVT_TRAFFIC_BUDGET_TOOL:-}"
  local budget_ledger="${DVT_TRAFFIC_LEDGER:-}" budget_window="${DVT_TRAFFIC_WINDOW_ID:-}"
  local budget_bytes="${DVT_TRAFFIC_BUDGET_BYTES:-}" budget_reservation="benchmark-${run_id:-pending}"
  local budget_reserved=0 planned_payload=0 actual_payload=0
  ensure_required_tools
  check_supported_os
  command -v iperf3 >/dev/null 2>&1 ||
    die "$EXIT_UNSUPPORTED" 'benchmark 需要已安装 iperf3；脚本不会自动安装软件包。'
  if ! command -v setsid >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    die "$EXIT_UNSUPPORTED" 'benchmark 需要 util-linux setsid 和 GNU coreutils timeout。'
  fi
  [ -n "$host" ] || die "$EXIT_USAGE" 'benchmark 必须显式设置 BENCHMARK_HOST。'
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._:%-]*$ ]] ||
    die "$EXIT_USAGE" 'BENCHMARK_HOST 含不支持的字符。'
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "$EXIT_USAGE" 'BENCHMARK_PORT 必须是 1–65535 的整数。'
  port=$((10#$port))
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    die "$EXIT_USAGE" 'BENCHMARK_PORT 必须在 1–65535 之间。'
  fi
  [[ "$seconds" =~ ^[0-9]{1,3}$ ]] || die "$EXIT_USAGE" 'BENCHMARK_SECONDS 必须是 5–120 的整数。'
  seconds=$((10#$seconds))
  if [ "$seconds" -lt 5 ] || [ "$seconds" -gt 120 ]; then
    die "$EXIT_USAGE" 'BENCHMARK_SECONDS 必须在 5–120 之间。'
  fi
  [[ "$parallel" =~ ^[0-9]$ ]] || die "$EXIT_USAGE" 'BENCHMARK_PARALLEL 必须是 1–4 的整数。'
  parallel=$((10#$parallel))
  if [ "$parallel" -lt 1 ] || [ "$parallel" -gt 4 ]; then
    die "$EXIT_USAGE" 'BENCHMARK_PARALLEL 必须在 1–4 之间。'
  fi
  [[ "$omit" =~ ^[0-9]{1,2}$ ]] || die "$EXIT_USAGE" 'BENCHMARK_OMIT_SECONDS 必须是 0–10 的整数。'
  omit=$((10#$omit))
  if [ "$omit" -lt 0 ] || [ "$omit" -gt 10 ]; then
    die "$EXIT_USAGE" 'BENCHMARK_OMIT_SECONDS 必须在 0–10 之间。'
  fi
  phase_timeout_default=$((seconds + omit + 15))
  if [ -z "$phase_timeout" ]; then
    phase_timeout="$phase_timeout_default"
  else
    [[ "$phase_timeout" =~ ^[0-9]{1,3}$ ]] ||
      die "$EXIT_USAGE" 'BENCHMARK_PHASE_TIMEOUT_SECONDS 必须是 1–300 的整数。'
    phase_timeout=$((10#$phase_timeout))
    [ "$phase_timeout" -ge 1 ] && [ "$phase_timeout" -le 300 ] ||
      die "$EXIT_USAGE" 'BENCHMARK_PHASE_TIMEOUT_SECONDS 必须在 1–300 之间。'
  fi
  BENCHMARK_FAMILY_ARGS=()
  case "$family" in
    auto) ;;
    4) BENCHMARK_FAMILY_ARGS=(--version4) ;;
    6) BENCHMARK_FAMILY_ARGS=(--version6) ;;
    *) die "$EXIT_USAGE" 'BENCHMARK_IP_FAMILY 只能为 auto、4 或 6。' ;;
  esac
  case "$direction" in upload | download | both) ;; *) die "$EXIT_USAGE" 'BENCHMARK_DIRECTION 只能为 upload、download 或 both。' ;; esac
  is_bool "$enforce_rate_cap" ||
    die "$EXIT_USAGE" 'BENCHMARK_ENFORCE_RATE_CAP 只能为 0 或 1。'
  if [ -n "$cap_input" ]; then
    [[ "$cap_input" =~ ^[0-9]{1,6}$ ]] ||
      die "$EXIT_USAGE" 'BENCHMARK_RATE_CAP_MBPS 必须是 1–100000 的整数。'
    cap_mbps=$((10#$cap_input))
    [ "$cap_mbps" -ge 1 ] && [ "$cap_mbps" -le 100000 ] ||
      die "$EXIT_USAGE" 'BENCHMARK_RATE_CAP_MBPS 必须在 1–100000 之间。'
    cap_source='explicit'
  fi
  BENCHMARK_RATE_ARGS=()
  if [ "$enforce_rate_cap" = '1' ]; then
    [ -n "$cap_mbps" ] ||
      die "$EXIT_USAGE" '启用 BENCHMARK_ENFORCE_RATE_CAP 时必须显式设置 BENCHMARK_RATE_CAP_MBPS。'
    rate_cap_per_stream_bps=$((cap_mbps * 1000000 / parallel))
    BENCHMARK_RATE_ARGS=(--bitrate "$rate_cap_per_stream_bps")
    rate_cap_enforced=true
  fi
  if [ -n "$output_dir" ]; then
    [[ "$output_dir" = /* ]] || die "$EXIT_USAGE" 'BENCHMARK_OUTPUT_DIR 必须是绝对路径。'
    [ ! -e "$output_dir" ] && [ ! -L "$output_dir" ] ||
      die "$EXIT_CONFLICT" "BENCHMARK_OUTPUT_DIR 已存在，拒绝覆盖：${output_dir}"
    [ -d "$(dirname "$output_dir")" ] || die "$EXIT_USAGE" 'BENCHMARK_OUTPUT_DIR 的父目录不存在。'
  fi
  if [ -z "$run_id" ]; then
    run_id="${SCRIPT_VERSION}-${PROFILE_ID}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  [[ "$run_id" =~ ^[A-Za-z0-9._:-]{1,96}$ ]] ||
    die "$EXIT_USAGE" 'BENCHMARK_RUN_ID 只能包含字母、数字、点、下划线、冒号和连字符，长度 1–96。'

  BENCHMARK_HOST_RESOLVED="$host"
  BENCHMARK_PORT_RESOLVED="$port"
  BENCHMARK_SECONDS_RESOLVED="$seconds"
  BENCHMARK_OMIT_RESOLVED="$omit"
  BENCHMARK_PARALLEL_RESOLVED="$parallel"
  BENCHMARK_PHASE_TIMEOUT_RESOLVED="$phase_timeout"

  info 'benchmark 不修改系统配置，但会向用户指定的 iperf3 服务器产生高带宽 TCP 流量。'
  info '该测试测量 VPS 到 iperf3 服务端的直连 TCP，不等同于 VLESS + REALITY + TCP 业务链路。'
  info "每个 iperf3 方向使用独立进程组，硬超时为 ${phase_timeout} 秒，超时后最多 ${BENCHMARK_TIMEOUT_TERMINATE_GRACE_SECONDS} 秒升级到 KILL。"
  umask 077
  if [ -n "$output_dir" ]; then
    mkdir -m 0700 -- "$output_dir" || die "$EXIT_UNSUPPORTED" '无法创建 BENCHMARK_OUTPUT_DIR。'
    tmp_dir="$output_dir"
    persistent_output=1
    printf 'status=INCOMPLETE\nstage=%s\nrun_id=%s\nutc=%s\n' \
      "$benchmark_failure_stage" "$run_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${tmp_dir}/INCOMPLETE"
    trap 'trap_rc=$?; benchmark_reap_active_child; if [ -d "$tmp_dir" ] && [ ! -f "${tmp_dir}/COMPLETED" ]; then printf "status=INCOMPLETE\nstage=%s\nrun_id=%s\nexit_code=%s\nutc=%s\n" "$benchmark_failure_stage" "$run_id" "$trap_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${tmp_dir}/INCOMPLETE.tmp" 2>/dev/null && mv -f "${tmp_dir}/INCOMPLETE.tmp" "${tmp_dir}/INCOMPLETE" 2>/dev/null || true; fi; exit "$trap_rc"' EXIT
    trap 'benchmark_handle_signal INT 130' INT
    trap 'benchmark_handle_signal TERM 143' TERM
  else
    tmp_dir="$(mktemp -d)" || die "$EXIT_UNSUPPORTED" '无法创建 benchmark 临时目录。'
    trap 'trap_rc=$?; benchmark_reap_active_child; rm -rf -- "$tmp_dir"; exit "$trap_rc"' EXIT
    trap 'benchmark_handle_signal INT 130' INT
    trap 'benchmark_handle_signal TERM 143' TERM
  fi
  benchmark_failure_stage='metadata'
  default_route_ifaces >"${tmp_dir}/ifaces"
  script_hash="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
  iperf_version="$(iperf3 --version 2>&1 | awk 'NR == 1 {print; exit}')"
  boot_id="$(awk 'NR == 1 {print; exit}' /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  state_phase='UNMANAGED'
  state_network='{}'
  if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
    if state_file_is_valid; then
      state_phase="$(jq -r '.state' "$STATE_FILE")"
      state_network="$(jq -c '.network' "$STATE_FILE")"
      if [ -z "$cap_mbps" ]; then
        cap_mbps="$(jq -r 'if (.network.port_speed_mbps | type) == "number" and (.network.port_speed_mbps | floor) == .network.port_speed_mbps and .network.port_speed_mbps >= 1 and .network.port_speed_mbps <= 100000 then .network.port_speed_mbps else empty end' "$STATE_FILE")"
        [ -z "$cap_mbps" ] || cap_source='managed-state'
      fi
    else
      state_phase='INVALID'
    fi
  fi
  traffic_estimate="$(benchmark_traffic_estimate_json "$cap_mbps" "$cap_source" "$seconds" "$omit" "$direction")" ||
    die "$EXIT_VERIFY" '无法计算 benchmark 流量估算。'
  if jq -e '.available == true' <<<"$traffic_estimate" >/dev/null; then
    info "benchmark payload 估算上界：$(jq -r '.payload_upper_bound_bytes' <<<"$traffic_estimate") 字节 ($(jq -r '.payload_upper_bound_gib | tostring' <<<"$traffic_estimate") GiB)，依据 $(jq -r '.cap_mbps' <<<"$traffic_estimate") Mbps / $(jq -r '.total_seconds' <<<"$traffic_estimate") 秒 / cap_source=$(jq -r '.cap_source' <<<"$traffic_estimate")。"
    info '该值是按配置带宽上限估算的 iperf payload，不含 TCP/IP/链路层开销；实际计费流量可能不同。'
  else
    die "$EXIT_USAGE" '未提供 BENCHMARK_RATE_CAP_MBPS，且管理状态中没有可信 port_speed_mbps；rc.16 拒绝无法量化并保留预算的测试。'
  fi
  planned_payload="$(jq -r '.payload_upper_bound_bytes' <<<"$traffic_estimate")"
  budget_reservation="benchmark-${run_id}"
  if [ "$budget_bypass" != 1 ]; then
    [ -n "$budget_tool" ] && [[ "$budget_tool" = /* ]] && [ -f "$budget_tool" ] && [ ! -L "$budget_tool" ] ||
      die "$EXIT_USAGE" 'benchmark 必须通过 DVT_TRAFFIC_BUDGET_TOOL 指定经校验的绝对路径预算工具。'
    [ -n "$budget_ledger" ] && [ -n "$budget_window" ] && [ -n "$budget_bytes" ] ||
      die "$EXIT_USAGE" 'benchmark 必须设置 DVT_TRAFFIC_LEDGER、DVT_TRAFFIC_WINDOW_ID 和 DVT_TRAFFIC_BUDGET_BYTES。'
    bash "$budget_tool" reserve --ledger "$budget_ledger" --window-id "$budget_window" \
      --budget-bytes "$budget_bytes" --tool benchmark --run-id "$run_id" \
      --reservation-id "$budget_reservation" --planned-bytes "$planned_payload" >/dev/null ||
      die "$EXIT_CONFLICT" 'benchmark 未能保留共享流量预算；没有开始网络测试。'
    budget_reserved=1
  fi
  printf '[benchmark-meta] run_id=%s utc=%s script_version=%s profile=%s script_sha256=%s boot_id=%s state=%s\n' \
    "$run_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCRIPT_VERSION" "$PROFILE_ID" "$script_hash" "${boot_id:-unknown}" "$state_phase"
  printf '[benchmark-meta] host=%s port=%s family=%s direction=%s seconds=%s omit_seconds=%s parallel=%s iperf3=%s\n' \
    "$host" "$port" "$family" "$direction" "$seconds" "$omit" "$parallel" "$iperf_version"
  printf '[benchmark-meta] phase_timeout_seconds=%s terminate_grace_seconds=%s process_group_isolated=true\n' \
    "$phase_timeout" "$BENCHMARK_TIMEOUT_TERMINATE_GRACE_SECONDS"
  printf '[benchmark-meta] state_network=%s congestion_control=%s default_qdisc=%s\n' \
    "$state_network" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" \
    "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  ip -4 route show default 2>/dev/null || true
  ip -6 route show default 2>/dev/null || true
  detect_policy_routing
  show_policy_routing_evidence 2>&1 | tee "${tmp_dir}/policy-routing.txt"
  jq -n --arg run_id "$run_id" --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg script_version "$SCRIPT_VERSION" --arg profile "$PROFILE_ID" --arg script_sha256 "$script_hash" \
    --arg boot_id "${boot_id:-unknown}" --arg state "$state_phase" --argjson state_network "$state_network" \
    --arg host "$host" --argjson port "$port" --arg family "$family" --arg direction "$direction" \
    --argjson seconds "$seconds" --argjson omit_seconds "$omit" --argjson parallel "$parallel" \
    --arg iperf3 "$iperf_version" --argjson phase_timeout_seconds "$phase_timeout" \
    --argjson terminate_grace_seconds "$BENCHMARK_TIMEOUT_TERMINATE_GRACE_SECONDS" \
    --arg policy_routing_ipv4 "$POLICY_ROUTING_IPV4_STATE" --arg policy_routing_ipv6 "$POLICY_ROUTING_IPV6_STATE" \
    --argjson traffic_estimate "$traffic_estimate" \
    --argjson rate_cap_enforced "$rate_cap_enforced" --argjson rate_cap_per_stream_bps "$rate_cap_per_stream_bps" \
    --arg budget_window "$budget_window" --arg budget_reservation "$budget_reservation" --argjson budget_bypass "$budget_bypass" \
    '{schema_version:1,run_id:$run_id,utc:$utc,script_version:$script_version,profile:$profile,script_sha256:$script_sha256,boot_id:$boot_id,state:$state,state_network:$state_network,benchmark:{host:$host,port:$port,family:$family,direction:$direction,seconds:$seconds,omit_seconds:$omit_seconds,parallel:$parallel,iperf3:$iperf3,phase_timeout_seconds:$phase_timeout_seconds,terminate_grace_seconds:$terminate_grace_seconds,process_group_isolated:true,traffic_estimate:$traffic_estimate,rate_cap_enforced:$rate_cap_enforced,rate_cap_method:(if $rate_cap_enforced then "iperf3-bitrate" else null end),rate_cap_scope:(if $rate_cap_enforced then "aggregate-target-divided-across-streams" else null end),rate_cap_per_stream_bps:(if $rate_cap_enforced then $rate_cap_per_stream_bps else null end)},policy_routing:{ipv4_custom_rule_state:$policy_routing_ipv4,ipv6_custom_rule_state:$policy_routing_ipv6,evidence_file:"policy-routing.txt",interface_discovery:"conventional-default-routes-only"},traffic_budget:{parent_reserved:($budget_bypass==1),window_id:(if $budget_window=="" then null else $budget_window end),reservation_id:(if $budget_bypass==1 then null else $budget_reservation end),planned_payload_bytes:$traffic_estimate.payload_upper_bound_bytes,protocol_overhead_included:false}}' \
    >"${tmp_dir}/benchmark-meta.json"
  printf '%s\n' 'null' >"${tmp_dir}/upload.summary.json"
  printf '%s\n' 'null' >"${tmp_dir}/download.summary.json"

  benchmark_failure_stage='upload-phase'
  if [ "$direction" = 'upload' ] || [ "$direction" = 'both' ]; then
    run_benchmark_phase upload 0 "$tmp_dir" "${tmp_dir}/ifaces" || current_rc=$?
    [ "$current_rc" -eq 0 ] || rc="$current_rc"
    current_rc=0
  fi
  benchmark_failure_stage='download-phase'
  if [ "$direction" = 'download' ] || [ "$direction" = 'both' ]; then
    run_benchmark_phase download 1 "$tmp_dir" "${tmp_dir}/ifaces" || current_rc=$?
    [ "$current_rc" -eq 0 ] || rc="$current_rc"
  fi

  if [ "$persistent_output" -eq 1 ]; then
    benchmark_failure_stage='evidence-manifest'
    (
      cd "$tmp_dir" || exit "$EXIT_VERIFY"
      : >SHA256SUMS.tmp
      while IFS= read -r -d '' file; do
        sha256sum "${file#./}" >>SHA256SUMS.tmp || exit "$EXIT_VERIFY"
      done < <(find . -maxdepth 1 -type f \
        ! -name SHA256SUMS ! -name SHA256SUMS.tmp \
        ! -name benchmark-result.json ! -name 'benchmark-result.json.tmp' \
        ! -name INCOMPLETE ! -name INCOMPLETE.tmp \
        ! -name COMPLETED ! -name COMPLETED.tmp -print0 | sort -z)
      [ -s SHA256SUMS.tmp ] || exit "$EXIT_VERIFY"
      chmod 0600 SHA256SUMS.tmp || exit "$EXIT_VERIFY"
      mv -f SHA256SUMS.tmp SHA256SUMS || exit "$EXIT_VERIFY"
      sha256sum -c SHA256SUMS
    ) || rc="$EXIT_VERIFY"
  fi

  benchmark_failure_stage='final-result'
  manifest_sha=''
  if [ "$persistent_output" -eq 1 ] && [ -f "${tmp_dir}/SHA256SUMS" ]; then
    manifest_sha="$(sha256sum "${tmp_dir}/SHA256SUMS" | awk '{print $1}')" || rc="$EXIT_VERIFY"
  fi
  result_tmp="${tmp_dir}/benchmark-result.json.tmp"
  jq -n --slurpfile meta "${tmp_dir}/benchmark-meta.json" \
    --slurpfile upload "${tmp_dir}/upload.summary.json" \
    --slurpfile download "${tmp_dir}/download.summary.json" \
    --argjson exit_code "$rc" --arg evidence_manifest_sha256 "$manifest_sha" \
    '{schema_version:1,metadata:$meta[0],phases:{upload:($upload[0] // null),download:($download[0] // null)},evidence_manifest_sha256:(if $evidence_manifest_sha256 == "" then null else $evidence_manifest_sha256 end),exit_code:$exit_code,status:(if $exit_code == 0 then "PASS" else "FAIL" end)}' \
    >"$result_tmp" || rc="$EXIT_VERIFY"
  if [ -s "$result_tmp" ] && jq -e 'type == "object" and .schema_version == 1 and (.status == "PASS" or .status == "FAIL")' "$result_tmp" >/dev/null 2>&1; then
    chmod 0600 "$result_tmp" || rc="$EXIT_VERIFY"
    mv -f -- "$result_tmp" "${tmp_dir}/benchmark-result.json" || rc="$EXIT_VERIFY"
  else
    rm -f -- "$result_tmp"
    rc="$EXIT_VERIFY"
  fi

  benchmark_failure_stage='budget-commit'
  if [ "$budget_reserved" -eq 1 ]; then
    if [ "$rc" -eq 0 ]; then
      actual_payload="$(jq '[.phases.upload.sender.bytes?,.phases.download.sender.bytes?] | map(select(type=="number")) | add // 0' "${tmp_dir}/benchmark-result.json")"
      if ! bash "$budget_tool" commit --ledger "$budget_ledger" --reservation-id "$budget_reservation" --actual-bytes "$actual_payload" >/dev/null; then
        warn 'benchmark 已完成采集，但预算 actual-byte 提交失败；reservation 保持占用。'
        rc="$EXIT_VERIFY"
      else
        budget_reserved=0
      fi
    else
      if bash "$budget_tool" fail --ledger "$budget_ledger" --reservation-id "$budget_reservation" >/dev/null 2>&1; then
        budget_reserved=0
      else
        warn 'benchmark 失败且预算保守结算失败；reservation 保持占用。'
      fi
    fi
  fi

  if [ "$persistent_output" -eq 1 ] && [ "$rc" -eq 0 ]; then
    benchmark_failure_stage='completion-commit'
    result_sha="$(sha256sum "${tmp_dir}/benchmark-result.json" | awk '{print $1}')" || rc="$EXIT_VERIFY"
    if [ "$rc" -eq 0 ]; then
      printf 'status=COMPLETED\nrun_id=%s\nevidence_manifest_sha256=%s\nresult_sha256=%s\nutc=%s\n' \
        "$run_id" "$manifest_sha" "$result_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${tmp_dir}/COMPLETED.tmp" || rc="$EXIT_VERIFY"
    fi
    if [ "$rc" -eq 0 ]; then
      chmod 0600 "${tmp_dir}/COMPLETED.tmp" && mv -f "${tmp_dir}/COMPLETED.tmp" "${tmp_dir}/COMPLETED" && rm -f "${tmp_dir}/INCOMPLETE" || rc="$EXIT_VERIFY"
    fi
  fi

  if [ "$rc" -ne 0 ] && [ -f "${tmp_dir}/benchmark-result.json" ]; then
    benchmark_failure_stage='failure-result'
    jq --argjson exit_code "$EXIT_VERIFY" '.exit_code=$exit_code | .status="FAIL"' \
      "${tmp_dir}/benchmark-result.json" >"${tmp_dir}/benchmark-result.json.tmp" 2>/dev/null &&
      chmod 0600 "${tmp_dir}/benchmark-result.json.tmp" &&
      mv -f "${tmp_dir}/benchmark-result.json.tmp" "${tmp_dir}/benchmark-result.json" || true
    rm -f -- "${tmp_dir}/COMPLETED" "${tmp_dir}/COMPLETED.tmp"
  fi
  if [ "$persistent_output" -eq 1 ] && [ "$rc" -ne 0 ]; then
    printf 'status=INCOMPLETE\nstage=%s\nrun_id=%s\nexit_code=%s\nutc=%s\n' \
      "$benchmark_failure_stage" "$run_id" "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${tmp_dir}/INCOMPLETE.tmp" 2>/dev/null &&
      mv -f "${tmp_dir}/INCOMPLETE.tmp" "${tmp_dir}/INCOMPLETE" 2>/dev/null || true
  fi
  [ -f "${tmp_dir}/benchmark-result.json" ] && cat "${tmp_dir}/benchmark-result.json"
  if [ "$persistent_output" -eq 0 ]; then
    rm -rf -- "$tmp_dir"
  fi
  trap - EXIT INT TERM
  [ "$rc" -eq 0 ] || die "$EXIT_VERIFY" "iperf3 benchmark 失败，退出码：${rc}。"
  info 'benchmark 完成；请结合业务流量下的 diagnose 和客户端指标判断。'
}

usage() {
  cat <<EOF_USAGE
Usage: $0 {preflight|apply|reconfigure|verify|status|diagnose|benchmark|rollback|recover}

Environment:
  PORT_SPEED_MBPS=1..10000       default 200; reconfigure requires an explicit value
  BUFFER_TARGET_RTT_MS=20..500    default 200
  BUF_MAX=auto|262144..${MAX_BUF_MAX}   default auto; profile memory cap
  ENABLE_SWAP=0|1                 default 1
  SWAP_MB=512..${SWAP_MAX_MIB}             default 1024
  PURGE_CREATED_SWAP=0|1          default 0
  ALLOW_EMPTY_STATE_RECOVERY=0|1  default 0; only for confirmed rc.2 pre-write empty state
  PROXY_SERVICE_UNITS='x-ui.service ...'
  REQUIRE_PROXY_SERVICE=0|1       default 0
  DIAG_INTERVAL_SECONDS=1..60     default 5
  DIAG_INCLUDE_SOCKET_DETAILS=0|1 default 0; 1 may expose peer addresses/processes
  BENCHMARK_HOST=host             required by benchmark; user-authorized iperf3 server
  BENCHMARK_PORT=1..65535         default 5201
  BENCHMARK_SECONDS=5..120        default 10
  BENCHMARK_OMIT_SECONDS=0..10    default 3; warm-up excluded from statistics
  BENCHMARK_PHASE_TIMEOUT_SECONDS=1..300 default seconds + omit + 15; per direction
  BENCHMARK_PARALLEL=1..4         default 1
  BENCHMARK_IP_FAMILY=auto|4|6    default auto
  BENCHMARK_DIRECTION=upload|download|both   default both
  BENCHMARK_RUN_ID=id             optional reproducibility label; safe characters only
  BENCHMARK_OUTPUT_DIR=/absolute/new/path   optional persistent JSON/evidence directory; must not exist
  BENCHMARK_RATE_CAP_MBPS=1..100000 optional traffic-estimate cap; installed state is fallback
  BENCHMARK_ENFORCE_RATE_CAP=0|1 default 0; 1 requires explicit rate cap and passes iperf3 --bitrate
EOF_USAGE
}

main() {
  local action="${1:-}"
  # 旧状态兼容只服务只读预检；不能借环境变量进入其他动作。
  [ "$UPDATE_PREFLIGHT" = '0' ] || [ "$action" = 'preflight' ] ||
    die "$EXIT_USAGE" 'UPDATE_PREFLIGHT 只能用于 preflight，不能用于其他动作。'
  case "$action" in
    preflight)
      need_root; acquire_lock; run_preflight
      ;;
    apply)
      need_root; acquire_lock; apply_settings
      ;;
    reconfigure)
      need_root; acquire_lock; reconfigure_port_settings
      ;;
    verify)
      need_root; acquire_lock
      state_exists || die "$EXIT_VERIFY" '当前主机尚未安装本项目配置；请先执行 preflight，确认通过后再执行 apply。'
      ensure_required_tools; check_supported_os; validate_inputs
      validate_state_file
      verify_settings || die "$EXIT_VERIFY" '验证失败。'
      ;;
    status)
      need_root; acquire_lock; show_status
      ;;
    diagnose)
      need_root; acquire_lock; show_diagnostics
      ;;
    benchmark)
      need_root; acquire_lock; run_network_benchmark
      ;;
    rollback)
      need_root; acquire_lock; ensure_required_tools; check_supported_os
      state_exists || { info '没有可回滚的管理状态。'; exit 0; }
      rollback_internal 0 || die "$EXIT_ROLLBACK" '回滚不完整；状态已保留。'
      ;;
    recover)
      need_root; acquire_lock; ensure_required_tools; check_supported_os
      if state_exists && state_file_is_valid; then
        if jq -e '(.state == "RECONFIGURING" or .state == "DEGRADED") and (.reconfigure | type == "object")' \
          "$STATE_FILE" >/dev/null 2>&1; then
          recover_incomplete_reconfigure || die "$EXIT_ROLLBACK" '带宽重配置恢复不完整；状态和备份已保留。'
        else
          die "$EXIT_CONFLICT" "有效状态 $(state_get '.state') 不属于 recover；普通配置回退请使用 rollback。"
        fi
      else
        recover_empty_legacy_state
      fi
      ;;
    -h | --help | help) usage ;;
    *) usage >&2; exit "$EXIT_USAGE" ;;
  esac
}

main "$@"
