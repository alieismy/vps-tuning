#!/usr/bin/env bash
# Advisory-only repeated iperf3 probe. It never changes tuning or qdisc state.

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

PROBE_VERSION='0.2.0'
DEFAULT_PORT=5201
DEFAULT_SAMPLES=3
DEFAULT_SECONDS=5
DEFAULT_OMIT=2
DEFAULT_PARALLEL=1
DEFAULT_DIRECTION='both'
DEFAULT_FAMILY='auto'
DEFAULT_BUDGET_MIB=600
STATE_FILE="${DVT_STATE_FILE:-/var/lib/proxy-vps-tuning/state.json}"

tuning_script=''
profile_id=''
host=''
port="$DEFAULT_PORT"
rate_cap=''
samples="$DEFAULT_SAMPLES"
seconds="$DEFAULT_SECONDS"
omit="$DEFAULT_OMIT"
parallel="$DEFAULT_PARALLEL"
direction="$DEFAULT_DIRECTION"
family="$DEFAULT_FAMILY"
budget_mib="$DEFAULT_BUDGET_MIB"
output_dir=''
budget_tool=''
ledger=''
window_id=''
reservation_id=''
budget_reserved=0
plan_only=0
assume_yes=0
probe_created=0
stage='initialization'

info() { printf '[dvt-probe] %s\n' "$*"; }
warn() { printf '[dvt-probe][WARN] %s\n' "$*" >&2; }
die() { printf '[dvt-probe][FAIL] %s\n' "$*" >&2; exit 2; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

usage() {
  cat <<'EOF'
Usage:
  dvt probe --host AUTHORIZED_IPERF3_HOST [options]

Options:
  --server-port PORT       default 5201
  --rate-cap MBPS          explicit 100..1000; otherwise read verified dvt state
  --samples 2..5           default 3
  --seconds 5..120         measured seconds per direction; default 5
  --omit 0..10             warm-up seconds per direction; default 2
  --parallel 1             fixed at 1 so --bitrate remains an aggregate cap
  --direction upload|download|both   default both
  --family auto|4|6        default auto
  --budget-mib MIB         shared window budget; default 600
  --ledger /absolute/path  required shared traffic ledger
  --window-id ID           required stable budget-window identifier
  --output-dir /absolute/new/path
  --plan-only              print the traffic plan and run no traffic
  --yes                    accept the displayed traffic budget non-interactively

The host must be an iperf3 service you control or are explicitly authorized to
use. Every sample applies iperf3 --bitrate at the declared cap. Reservations include
the hard-timeout and termination windows plus a send-block allowance. Results are
advisory: they do not discover a provider plan cap, tune sysctl, change qdisc,
recommend persistent shaping, or measure the 3X-UI/Xray/client path.
EOF
}

uint_range() {
  local name="$1" value="$2" min="$3" max="$4"
  [[ "$value" =~ ^[0-9]+$ ]] || die "${name} 必须是 ${min}–${max} 的整数。"
  value=$((10#$value))
  [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] ||
    die "${name} 必须在 ${min}–${max} 之间。"
  printf '%s\n' "$value"
}

read_rate_from_state() {
  [ -s "$STATE_FILE" ] || return 1
  jq -er '
    select(.state == "VERIFIED") |
    .network.port_speed_mbps |
    select(type == "number" and floor == . and . >= 100 and . <= 1000)
  ' "$STATE_FILE" 2>/dev/null
}

planned_payload_bytes() {
  local direction_count=1
  [ "$direction" != both ] || direction_count=2
  # 与子 benchmark 的固定硬超时、TERM→KILL 宽限及单流发送余量一致。
  printf '%s\n' "$(((rate_cap * 125000 * (seconds + omit + 15 + 5) + 1048576) * direction_count * samples))"
}

confirm_traffic() {
  local answer
  [ "$assume_yes" -eq 0 ] || return 0
  [ -t 0 ] && [ -t 1 ] || die '非交互执行需要显式添加 --yes。'
  printf '确认向上述已授权服务端产生受限测试流量？[y/N]：'
  IFS= read -r answer
  case "$answer" in y | Y | yes | YES) ;; *) die '用户取消；没有产生 probe 流量。' ;; esac
}

known_payload_bytes() {
  local file
  for file in "${output_dir}"/sample-*/*.iperf3.json; do
    [ -f "$file" ] || continue
    jq -er '.end.sum_sent.bytes | select(type == "number" and . >= 0 and floor == .)' "$file" 2>/dev/null || true
  done | awk '{total += $1} END {printf "%.0f\n", total}'
}

mark_incomplete() {
  local rc=$?
  if [ "$budget_reserved" -eq 1 ]; then
    bash "$budget_tool" fail --ledger "$ledger" --reservation-id "$reservation_id" --known-bytes "$(known_payload_bytes)" >/dev/null 2>&1 || true
    budget_reserved=0
  fi
  if [ "$probe_created" -eq 1 ] && [ ! -f "${output_dir}/COMPLETED" ]; then
    printf 'status=INCOMPLETE\nstage=%s\nexit_code=%s\nutc=%s\n' \
      "$stage" "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${output_dir}/INCOMPLETE.tmp" 2>/dev/null || true
    chmod 0600 "${output_dir}/INCOMPLETE.tmp" 2>/dev/null || true
    mv -f "${output_dir}/INCOMPLETE.tmp" "${output_dir}/INCOMPLETE" 2>/dev/null || true
  fi
  exit "$rc"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tuning-script) [ "$#" -ge 2 ] || die '--tuning-script 缺少参数。'; tuning_script="$2"; shift 2 ;;
      --profile-id) [ "$#" -ge 2 ] || die '--profile-id 缺少参数。'; profile_id="$2"; shift 2 ;;
      --host) [ "$#" -ge 2 ] || die '--host 缺少参数。'; host="$2"; shift 2 ;;
      --server-port | --port) [ "$#" -ge 2 ] || die '--server-port 缺少参数。'; port="$2"; shift 2 ;;
      --rate-cap) [ "$#" -ge 2 ] || die '--rate-cap 缺少参数。'; rate_cap="$2"; shift 2 ;;
      --samples) [ "$#" -ge 2 ] || die '--samples 缺少参数。'; samples="$2"; shift 2 ;;
      --seconds) [ "$#" -ge 2 ] || die '--seconds 缺少参数。'; seconds="$2"; shift 2 ;;
      --omit) [ "$#" -ge 2 ] || die '--omit 缺少参数。'; omit="$2"; shift 2 ;;
      --parallel) [ "$#" -ge 2 ] || die '--parallel 缺少参数。'; parallel="$2"; shift 2 ;;
      --direction) [ "$#" -ge 2 ] || die '--direction 缺少参数。'; direction="$2"; shift 2 ;;
      --family) [ "$#" -ge 2 ] || die '--family 缺少参数。'; family="$2"; shift 2 ;;
      --budget-mib) [ "$#" -ge 2 ] || die '--budget-mib 缺少参数。'; budget_mib="$2"; shift 2 ;;
      --budget-tool) [ "$#" -ge 2 ] || die '--budget-tool 缺少参数。'; budget_tool="$2"; shift 2 ;;
      --ledger) [ "$#" -ge 2 ] || die '--ledger 缺少参数。'; ledger="$2"; shift 2 ;;
      --window-id) [ "$#" -ge 2 ] || die '--window-id 缺少参数。'; window_id="$2"; shift 2 ;;
      --output-dir) [ "$#" -ge 2 ] || die '--output-dir 缺少参数。'; output_dir="$2"; shift 2 ;;
      --plan-only) plan_only=1; shift ;;
      --yes) assume_yes=1; shift ;;
      -h | --help | help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

main() {
  local payload_bytes budget_bytes direction_count=1 sample sample_dir phase
  local result_file rows_file manifest_sha result_sha parent output_name actual_bytes
  parse_args "$@"
  [ "$(id -u)" -eq 0 ] || die '必须在 root shell 中运行。'
  for command in awk bash chmod date find id jq mkdir mv readlink sha256sum sort stat; do need_command "$command"; done
  [ -n "$tuning_script" ] || die '缺少经总控校验的 tuning script。请通过 dvt probe 调用。'
  [[ "$tuning_script" = /* ]] && [ -f "$tuning_script" ] && [ ! -L "$tuning_script" ] ||
    die 'tuning script 必须是绝对路径普通文件，且不能是符号链接。'
  [ "$(stat -c '%u' "$tuning_script")" = 0 ] || die 'tuning script 必须由 root 所有。'
  [ $((8#$(stat -c '%a' "$tuning_script") & 0022)) -eq 0 ] || die 'tuning script 不能被 group/world 写入。'
  [ -n "$profile_id" ] || die '缺少 profile-id。请通过 dvt probe 调用。'
  if [ -z "$host" ] && [ -t 0 ] && [ -t 1 ]; then
    printf '请输入你控制或明确获准使用的 iperf3 host：'
    IFS= read -r host
  fi
  [ -n "$host" ] || die '必须用 --host 显式指定已授权 iperf3 服务端。'
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._:%-]*$ ]] || die 'host 含不支持的字符。'
  port="$(uint_range server-port "$port" 1 65535)"
  samples="$(uint_range samples "$samples" 2 5)"
  seconds="$(uint_range seconds "$seconds" 5 120)"
  omit="$(uint_range omit "$omit" 0 10)"
  parallel="$(uint_range parallel "$parallel" 1 1)"
  budget_mib="$(uint_range budget-mib "$budget_mib" 1 102400)"
  case "$direction" in upload | download) ;; both) direction_count=2 ;; *) die 'direction 只能为 upload、download 或 both。' ;; esac
  case "$family" in auto | 4 | 6) ;; *) die 'family 只能为 auto、4 或 6。' ;; esac
  if [ -z "$rate_cap" ]; then
    rate_cap="$(read_rate_from_state)" || die '未提供 --rate-cap，且没有可用的 VERIFIED 管理状态端口带宽。'
    info "从 VERIFIED 管理状态读取端口带宽：${rate_cap} Mbps。"
  fi
  rate_cap="$(uint_range rate-cap "$rate_cap" 100 1000)"
  payload_bytes="$(planned_payload_bytes)"
  budget_bytes=$((budget_mib * 1024 * 1024))
  [ "$payload_bytes" -le "$budget_bytes" ] ||
    die "计划 payload ${payload_bytes} 字节超过 --budget-mib ${budget_mib} MiB；请缩短测试或显式提高预算。"

  printf '\nDVT advisory probe plan:\n'
  printf '  host/port: %s:%s\n' "$host" "$port"
  printf '  profile: %s\n' "$profile_id"
  printf '  rate cap: %s Mbps (iperf3 --bitrate, every direction)\n' "$rate_cap"
  printf '  samples/direction: %s; directions: %s; measured+omit: %s+%s s\n' "$samples" "$direction_count" "$seconds" "$omit"
  printf '  conservative reservation: %s bytes (%.2f MiB; protocol overhead excluded)\n' \
    "$payload_bytes" "$(awk -v b="$payload_bytes" 'BEGIN {printf "%.2f", b/1048576}')"
  printf '  boundary: advisory-only; no sysctl/qdisc/provider-cap/persistent-HTB change\n\n'
  [ "$plan_only" -eq 0 ] || { info 'plan-only 完成；没有创建证据目录，也没有产生流量。'; return 0; }
  [ -n "$budget_tool" ] && [[ "$budget_tool" = /* ]] && [ -f "$budget_tool" ] && [ ! -L "$budget_tool" ] ||
    die '缺少经总控校验的 --budget-tool。'
  [ -n "$ledger" ] && [ -n "$window_id" ] || die '执行 probe 必须显式设置 --ledger 和 --window-id。'
  confirm_traffic

  if [ -z "$output_dir" ]; then output_dir="/root/dvt-probe-$(date -u +%Y%m%dT%H%M%SZ)"; fi
  [[ "$output_dir" = /* ]] || die 'output-dir 必须是绝对路径。'
  [ ! -e "$output_dir" ] && [ ! -L "$output_dir" ] || die "output-dir 已存在：${output_dir}"
  parent="$(dirname "$output_dir")"
  [ -d "$parent" ] && [ ! -L "$parent" ] || die 'output-dir 父目录不存在或是符号链接。'
  parent="$(readlink -f "$parent")"; output_name="$(basename "$output_dir")"; output_dir="${parent}/${output_name}"
  umask 077
  mkdir -m 0700 "$output_dir"
  probe_created=1
  trap mark_incomplete EXIT
  trap 'stage=signal-INT; exit 130' INT
  trap 'stage=signal-TERM; exit 143' TERM
  printf 'status=INCOMPLETE\nstage=initialization\nutc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${output_dir}/INCOMPLETE"
  reservation_id="probe-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  bash "$budget_tool" reserve --ledger "$ledger" --window-id "$window_id" \
    --budget-bytes "$budget_bytes" --tool probe --run-id "$reservation_id" \
    --reservation-id "$reservation_id" --planned-bytes "$payload_bytes" >/dev/null ||
    die '共享窗口剩余额度不足或 ledger 无效；没有开始 probe。'
  budget_reserved=1

  rows_file="${output_dir}/samples.ndjson"
  : >"$rows_file"

  for ((sample=1; sample<=samples; sample++)); do
    stage="sample-${sample}"
    sample_dir="${output_dir}/sample-$(printf '%02d' "$sample")"
    info "运行 ${stage}/${samples}：${direction}，强制 ${rate_cap} Mbps cap。"
    env BENCHMARK_HOST="$host" BENCHMARK_PORT="$port" \
      BENCHMARK_RATE_CAP_MBPS="$rate_cap" BENCHMARK_ENFORCE_RATE_CAP=1 \
      BENCHMARK_SECONDS="$seconds" BENCHMARK_OMIT_SECONDS="$omit" \
      BENCHMARK_PHASE_TIMEOUT_SECONDS="$((seconds + omit + 15))" \
      BENCHMARK_PARALLEL="$parallel" BENCHMARK_IP_FAMILY="$family" \
      BENCHMARK_DIRECTION="$direction" BENCHMARK_RUN_ID="dvt-probe-${sample}" \
      BENCHMARK_OUTPUT_DIR="$sample_dir" DVT_TRAFFIC_BUDGET_BYPASS=1 \
      bash "$tuning_script" benchmark >/dev/null
    [ -f "${sample_dir}/COMPLETED" ] && [ ! -e "${sample_dir}/INCOMPLETE" ] || die "${stage} 未形成 COMPLETED。"
    (cd "$sample_dir" && sha256sum -c SHA256SUMS >/dev/null) || die "${stage} SHA256SUMS 校验失败。"
    jq -e --argjson cap "$rate_cap" '
      .status == "PASS" and .exit_code == 0 and
      .metadata.benchmark.rate_cap_enforced == true and
      .metadata.benchmark.rate_cap_method == "iperf3-bitrate" and
      .metadata.benchmark.traffic_estimate.cap_mbps == $cap
    ' "${sample_dir}/benchmark-result.json" >/dev/null || die "${stage} 未证明 rate cap 已执行。"
    for phase in upload download; do
      [ "$direction" = both ] || [ "$direction" = "$phase" ] || continue
      jq -c --argjson sample "$sample" --arg phase "$phase" '
        .phases[$phase] as $p |
        {sample:$sample,direction:$phase,
         measurement_window_valid:($p.measurement_window.valid == true),
         sender_mbps:$p.sender.mbps,receiver_mbps:$p.receiver.mbps,
         sender_bytes:$p.sender.bytes,sender_retransmits:$p.sender.retransmits,
         sender_retransmits_per_gib:$p.sender.retransmits_per_gib,
         host_tcp_retrans_delta:($p.host.tcp_delta.TcpRetransSegs // null),
         qdisc_dropped_delta:($p.qdisc_active_totals.dropped_delta // null)}
      ' "${sample_dir}/benchmark-result.json" >>"$rows_file"
    done
  done

  stage='analysis'
  result_file="${output_dir}/probe-result.json"
  jq -s --arg version "$PROBE_VERSION" --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg profile "$profile_id" --arg host "$host" --argjson port "$port" \
    --argjson rate_cap "$rate_cap" --argjson planned_bytes "$payload_bytes" \
    --argjson budget_mib "$budget_mib" --arg window "$window_id" --arg reservation "$reservation_id" '
    def median: sort | if length == 0 then null elif length % 2 == 1 then .[length/2|floor] else (.[length/2-1] + .[length/2])/2 end;
    def stats($rows): {samples:($rows|length),valid_windows:([$rows[]|select(.measurement_window_valid)]|length),
      sender_mbps_median:([$rows[].sender_mbps]|median),receiver_mbps_median:([$rows[].receiver_mbps]|median),
      sender_retransmits_per_gib_median:([$rows[].sender_retransmits_per_gib]|median)};
    . as $rows | ([$rows[]|select(.direction=="upload")]) as $up | ([$rows[]|select(.direction=="download")]) as $down |
    {schema_version:1,probe_version:$version,generated_utc:$utc,status:(if all($rows[];.measurement_window_valid) then "REVIEW_REQUIRED" else "REVIEW_BLOCKED" end),
     advisory_only:true,persistent_shaping_authorized:false,provider_plan_cap_modified:false,
     profile:$profile,endpoint:{host:$host,port:$port,explicitly_supplied:true},
     traffic_control:{rate_cap_mbps:$rate_cap,enforced:true,method:"iperf3-bitrate",planned_payload_bytes:$planned_bytes,window_budget_mib:$budget_mib,window_id:$window,reservation_id:$reservation,protocol_overhead_included:false},
     aggregates:{upload:(if ($up|length)>0 then stats($up) else null end),download:(if ($down|length)>0 then stats($down) else null end)},samples:$rows,
     interpretation:{provider_cap_discovered:false,proxy_business_path_measured:false,production_rate_recommended:false,
       next_gate:"review raw JSON, validated windows, retransmits per exact sender GiB, host counters, qdisc and client business-path evidence"}}
  ' "$rows_file" >"${result_file}.tmp"
  chmod 0600 "${result_file}.tmp"; mv -f "${result_file}.tmp" "$result_file"
  actual_bytes="$(jq -s '[.[].sender_bytes] | add // 0' "$rows_file")"
  stage='budget-commit'
  if [ "$omit" -gt 0 ]; then
    bash "$budget_tool" commit-unknown --ledger "$ledger" --reservation-id "$reservation_id" \
      --known-bytes "$actual_bytes" >/dev/null || die 'probe 完成，但共享预算保守提交失败；reservation 保持占用。'
  else
    bash "$budget_tool" commit --ledger "$ledger" --reservation-id "$reservation_id" \
      --actual-bytes "$actual_bytes" >/dev/null || die 'probe 完成，但共享预算提交失败；reservation 保持占用。'
  fi
  budget_reserved=0
  stage='manifest'
  (cd "$output_dir" && find . -type f ! -name SHA256SUMS ! -name 'SHA256SUMS.tmp' ! -name COMPLETED ! -name INCOMPLETE -print0 |
    sort -z | while IFS= read -r -d '' file; do sha256sum "${file#./}"; done >SHA256SUMS.tmp &&
    test -s SHA256SUMS.tmp && chmod 0600 SHA256SUMS.tmp && mv -f SHA256SUMS.tmp SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null) ||
    die 'probe 证据清单生成或复核失败。'
  manifest_sha="$(sha256sum "${output_dir}/SHA256SUMS" | awk '{print $1}')"
  result_sha="$(sha256sum "$result_file" | awk '{print $1}')"
  printf 'status=COMPLETED\nresult_sha256=%s\nevidence_manifest_sha256=%s\nutc=%s\n' \
    "$result_sha" "$manifest_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${output_dir}/COMPLETED.tmp"
  chmod 0600 "${output_dir}/COMPLETED.tmp"; mv -f "${output_dir}/COMPLETED.tmp" "${output_dir}/COMPLETED"; rm -f "${output_dir}/INCOMPLETE"
  stage='completed'; trap - EXIT INT TERM
  jq '{status,advisory_only,traffic_control,aggregates,interpretation}' "$result_file"
  info "probe 完成：${output_dir}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
