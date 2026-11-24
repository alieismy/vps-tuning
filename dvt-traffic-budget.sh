#!/usr/bin/env bash
# Transactional, fail-closed traffic budget ledger shared by DVT traffic tools.

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

TOOL_VERSION='0.2.0-rc.1'
SCHEMA_VERSION=1

action=''
ledger=''
window_id=''
budget_bytes=''
tool_name=''
run_id=''
reservation_id=''
planned_bytes=''
actual_bytes=''
known_bytes=''

die() { printf '[dvt-traffic-budget][FAIL] %s\n' "$*" >&2; exit 2; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

usage() {
  cat <<'EOF'
Usage:
  dvt-traffic-budget.sh init    --ledger PATH --window-id ID --budget-bytes N
  dvt-traffic-budget.sh reserve --ledger PATH --window-id ID --budget-bytes N
                                --tool NAME --run-id ID --reservation-id ID
                                --planned-bytes N
  dvt-traffic-budget.sh commit  --ledger PATH --reservation-id ID --actual-bytes N
  dvt-traffic-budget.sh commit-unknown --ledger PATH --reservation-id ID [--known-bytes N]
  dvt-traffic-budget.sh fail    --ledger PATH --reservation-id ID [--known-bytes N]
  dvt-traffic-budget.sh status  --ledger PATH

The ledger accounts application payload only. Protocol, retransmission and ISP
billing overhead remain unknown. A failed reservation is charged at its planned
upper bound so interruption never releases traffic that may already have run.
EOF
}

uint() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "$1 必须是非负整数。"
  printf '%s\n' "$((10#$2))"
}

safe_id() {
  [ -n "$2" ] && [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] ||
    die "$1 只能包含字母、数字、点、下划线、冒号和连字符，长度 1..128。"
}

parse_args() {
  [ "$#" -gt 0 ] || { usage >&2; exit 2; }
  action="$1"; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ledger) [ "$#" -ge 2 ] || die '--ledger 缺少参数。'; ledger="$2"; shift 2 ;;
      --window-id) [ "$#" -ge 2 ] || die '--window-id 缺少参数。'; window_id="$2"; shift 2 ;;
      --budget-bytes) [ "$#" -ge 2 ] || die '--budget-bytes 缺少参数。'; budget_bytes="$2"; shift 2 ;;
      --tool) [ "$#" -ge 2 ] || die '--tool 缺少参数。'; tool_name="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || die '--run-id 缺少参数。'; run_id="$2"; shift 2 ;;
      --reservation-id) [ "$#" -ge 2 ] || die '--reservation-id 缺少参数。'; reservation_id="$2"; shift 2 ;;
      --planned-bytes) [ "$#" -ge 2 ] || die '--planned-bytes 缺少参数。'; planned_bytes="$2"; shift 2 ;;
      --known-bytes) [ "$#" -ge 2 ] || die '--known-bytes 缺少参数。'; known_bytes="$2"; shift 2 ;;
      --actual-bytes) [ "$#" -ge 2 ] || die '--actual-bytes 缺少参数。'; actual_bytes="$2"; shift 2 ;;
      -h | --help | help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

validate_ledger_path() {
  local parent uid mode canonical managed
  [ -n "$ledger" ] && [[ "$ledger" = /* ]] || die '--ledger 必须是绝对路径。'
  [ ! -L "$ledger" ] || die 'ledger 不能是符号链接。'
  if [ "$action" = init ] || [ "$action" = reserve ]; then
    canonical="$(readlink -m -- "$ledger")" || die '无法规范化 ledger 路径。'
    managed="$(readlink -m -- /var/lib/proxy-vps-tuning)" || die '无法规范化受管状态路径。'
    case "$canonical" in
      "$managed" | "$managed"/*)
        die 'ledger 必须放在受管状态目录树之外；先保留并外移既有账本。'
        ;;
    esac
  fi
  parent="$(dirname -- "$ledger")"
  if [ ! -d "$parent" ]; then
    [ "$action" = init ] || [ "$action" = reserve ] || die 'ledger 父目录不存在。'
    install -d -o root -g root -m 0700 -- "$parent"
  fi
  [ ! -L "$parent" ] || die 'ledger 父目录不能是符号链接。'
  uid="$(stat -c '%u' "$parent")"; mode="$(stat -c '%a' "$parent")"
  [ "$uid" = 0 ] || die 'ledger 父目录必须由 root 所有。'
  [ $((8#$mode & 0022)) -eq 0 ] || die 'ledger 父目录不能被 group/world 写入。'
  if [ -e "$ledger" ]; then
    [ -f "$ledger" ] || die 'ledger 必须是普通文件。'
    [ "$(stat -c '%u' "$ledger")" = 0 ] || die 'ledger 必须由 root 所有。'
    [ $((8#$(stat -c '%a' "$ledger") & 0022)) -eq 0 ] || die 'ledger 不能被 group/world 写入。'
  fi
}

validate_ledger_json() {
  jq -e --argjson schema "$SCHEMA_VERSION" '
    .schema_version == $schema and (.tool_version == "0.1.0-rc.19" or .tool_version == "0.2.0-rc.1") and
    (.window_id | type == "string" and length > 0) and
    (.budget_bytes | type == "number" and floor == . and . > 0) and
    (.reserved_bytes | type == "number" and floor == . and . >= 0) and
    (.accounted_bytes | type == "number" and floor == . and . >= 0) and
    (.entries | type == "array") and
    (.reserved_bytes == ([.entries[] | select(.status == "RESERVED") | .planned_bytes] | add // 0)) and
    (.accounted_bytes == ([.entries[] | select(.status != "RESERVED") | .accounted_bytes] | add // 0))
  ' "$ledger" >/dev/null || die 'ledger schema、版本或汇总不变量无效。'
}

atomic_write() {
  local source="$1" temp
  temp="${ledger}.tmp.$$"
  chmod 0600 "$source"
  mv -f -- "$source" "$temp"
  mv -f -- "$temp" "$ledger"
}

initialize_if_needed() {
  local temp now
  [ -n "$window_id" ] || die '缺少 --window-id。'
  safe_id window-id "$window_id"
  [ -n "$budget_bytes" ] || die '缺少 --budget-bytes。'
  budget_bytes="$(uint budget-bytes "$budget_bytes")"
  [ "$budget_bytes" -gt 0 ] || die 'budget-bytes 必须大于 0。'
  if [ ! -e "$ledger" ]; then
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; temp="${ledger}.new.$$"
    jq -n --argjson schema "$SCHEMA_VERSION" --arg version "$TOOL_VERSION" \
      --arg window "$window_id" --argjson budget "$budget_bytes" --arg utc "$now" \
      '{schema_version:$schema,tool_version:$version,window_id:$window,status:"OPEN",budget_bytes:$budget,reserved_bytes:0,accounted_bytes:0,protocol_overhead_included:false,isp_billing_overhead_known:false,created_utc:$utc,updated_utc:$utc,entries:[]}' >"$temp"
    atomic_write "$temp"
  fi
  validate_ledger_json
  jq -e --arg window "$window_id" --argjson budget "$budget_bytes" \
    '.window_id == $window and .budget_bytes == $budget' "$ledger" >/dev/null ||
    die '现有 ledger 的 window-id 或 budget 与请求不一致。'
}

reserve() {
  local temp now
  initialize_if_needed
  safe_id tool "$tool_name"; safe_id run-id "$run_id"; safe_id reservation-id "$reservation_id"
  [ -n "$planned_bytes" ] || die '缺少 --planned-bytes。'
  planned_bytes="$(uint planned-bytes "$planned_bytes")"
  [ "$planned_bytes" -gt 0 ] || die 'planned-bytes 必须大于 0。'
  if jq -e --arg id "$reservation_id" '.entries[] | select(.reservation_id == $id)' "$ledger" >/dev/null; then
    jq -e --arg id "$reservation_id" --arg tool "$tool_name" --arg run "$run_id" --argjson planned "$planned_bytes" \
      '.entries[] | select(.reservation_id == $id and .tool == $tool and .run_id == $run and .planned_bytes == $planned and .status == "RESERVED")' "$ledger" >/dev/null ||
      die 'reservation-id 已存在且契约不同或已结算。'
    jq --arg id "$reservation_id" '{ledger:{window_id:.window_id,budget_bytes:.budget_bytes,reserved_bytes:.reserved_bytes,accounted_bytes:.accounted_bytes},reservation:(.entries[]|select(.reservation_id==$id)),idempotent:true}' "$ledger"
    return 0
  fi
  jq -e --argjson planned "$planned_bytes" '(.budget_bytes - .reserved_bytes - .accounted_bytes) >= $planned' "$ledger" >/dev/null ||
    die '共享窗口剩余额度不足；没有保留额度，也不得开始网络流量。'
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; temp="${ledger}.reserve.$$"
  jq --arg id "$reservation_id" --arg tool "$tool_name" --arg run "$run_id" \
    --arg utc "$now" --argjson planned "$planned_bytes" '
      .entries += [{reservation_id:$id,tool:$tool,run_id:$run,status:"RESERVED",planned_bytes:$planned,actual_known_bytes:null,accounted_bytes:0,reserved_utc:$utc,settled_utc:null}] |
      .reserved_bytes += $planned | .updated_utc=$utc
    ' "$ledger" >"$temp"
  atomic_write "$temp"; validate_ledger_json
  jq --arg id "$reservation_id" '{ledger:{window_id:.window_id,budget_bytes:.budget_bytes,reserved_bytes:.reserved_bytes,accounted_bytes:.accounted_bytes},reservation:(.entries[]|select(.reservation_id==$id)),idempotent:false}' "$ledger"
}

settle() {
  local outcome="$1" temp now planned accounted actual_json
  safe_id reservation-id "$reservation_id"
  validate_ledger_json
  planned="$(jq -er --arg id "$reservation_id" '.entries[] | select(.reservation_id==$id and .status=="RESERVED") | .planned_bytes' "$ledger")" ||
    die '找不到尚未结算的 reservation-id。'
  if [ "$outcome" = COMMITTED ]; then
    [ -n "$actual_bytes" ] || die 'commit 缺少 --actual-bytes。'
    actual_bytes="$(uint actual-bytes "$actual_bytes")"; accounted="$actual_bytes"; actual_json="$actual_bytes"
  else
    accounted="$planned"; actual_json='null'
    if [ -n "$known_bytes" ]; then
      known_bytes="$(uint known-bytes "$known_bytes")"
      [ "$known_bytes" -le "$accounted" ] || accounted="$known_bytes"
    fi
  fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; temp="${ledger}.settle.$$"
  jq --arg id "$reservation_id" --arg status "$outcome" --arg utc "$now" \
    --argjson planned "$planned" --argjson accounted "$accounted" --argjson actual "$actual_json" '
      .entries |= map(if .reservation_id==$id and .status=="RESERVED" then .status=$status | .actual_known_bytes=$actual | .accounted_bytes=$accounted | .settled_utc=$utc else . end) |
      .reserved_bytes -= $planned | .accounted_bytes += $accounted | .updated_utc=$utc |
      .status=(if .accounted_bytes >= .budget_bytes then "EXHAUSTED" else "OPEN" end)
    ' "$ledger" >"$temp"
  atomic_write "$temp"; validate_ledger_json
  jq --arg id "$reservation_id" '{ledger:{window_id:.window_id,status:.status,budget_bytes:.budget_bytes,reserved_bytes:.reserved_bytes,accounted_bytes:.accounted_bytes,remaining_bytes:([.budget_bytes-.reserved_bytes-.accounted_bytes,0]|max)},reservation:(.entries[]|select(.reservation_id==$id))}' "$ledger"
}

main() {
  parse_args "$@"
  [ "$(id -u)" -eq 0 ] || die '必须以 root 运行。'
  for command in date dirname flock install jq mv readlink stat; do need_command "$command"; done
  validate_ledger_path
  exec 9>"${ledger}.lock"
  flock -x 9
  case "$action" in
    init) initialize_if_needed; jq '{window_id,status,budget_bytes,reserved_bytes,accounted_bytes,remaining_bytes:(.budget_bytes-.reserved_bytes-.accounted_bytes),protocol_overhead_included,isp_billing_overhead_known}' "$ledger" ;;
    reserve) reserve ;;
    commit) settle COMMITTED ;;
    commit-unknown) settle COMMITTED_CONSERVATIVE ;;
    fail) settle FAILED_CONSERVATIVE ;;
    status) validate_ledger_json; jq '{window_id,status,budget_bytes,reserved_bytes,accounted_bytes,remaining_bytes:([.budget_bytes-.reserved_bytes-.accounted_bytes,0]|max),protocol_overhead_included,isp_billing_overhead_known,entries}' "$ledger" ;;
    *) usage >&2; die "未知 action：$action" ;;
  esac
}

main "$@"
