#!/usr/bin/env bash
# Execute an explicitly approved, non-persistent candidate-rate sweep.
# The runner delegates qdisc state transitions to htb-aggregate-experiment.sh
# and traffic/evidence collection to one pinned standalone tuning profile.

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

RUNNER_VERSION='0.5.0'
EXPECTED_TUNING_VERSION='0.2.0-rc.1'
MANAGED_STATE_FILE='/var/lib/proxy-vps-tuning/state.json'
RUNTIME_STATE_DIR='/run/htb-aggregate-experiment'
RUNTIME_STATE_FILE="${RUNTIME_STATE_DIR}/active.json"
RUNNER_LOCK='/run/lock/htb-rate-sweep.lock'

plan_file=''
output_dir=''
tuning_script=''
htb_tool=''
analyzer=''
benchmark_host=''
benchmark_port='5201'
budget_tool=''
traffic_ledger=''
traffic_window_id=''
traffic_budget_bytes=''
traffic_reservation_id=''
traffic_reserved=0
htb_started=0
current_stage='initialization'
session_created=0
socket_sampler_pid=''
managed_profile_id=''
managed_script_version=''
managed_state_sha256_frozen=''
tuning_script_sha256=''

log() { printf '[rate-sweep-run] %s\n' "$*"; }
warn() { printf '[rate-sweep-run][WARN] %s\n' "$*" >&2; }
die() { printf '[rate-sweep-run][FAIL] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  rate-sweep-run.sh --plan /absolute/plan.json
                    --output-dir /absolute/new/evidence-dir
                    --tuning-script /absolute/debian13-1c2g-vps-tuning.sh
                    --htb-tool /usr/local/sbin/htb-aggregate-experiment
                    --analyzer /absolute/rate-sweep-analyze.sh
                    --host AUTHORIZED_IPERF3_HOST [--port 5201]

The runner is non-persistent but it does produce high-bandwidth upload traffic
and temporarily replaces root fq with HTB for every reference/candidate stage. It never
installs packages, chooses a public server, changes sysctl/routing/firewall, or
creates persistent shaping. Every shaped stage is guarded by HTB preflight,
ACTIVE checks, normal stop, and root-fq postflight. The first failed stage stops
the session; an EXIT trap attempts restoration when this runner started HTB.
EOF
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die '必须以 root 运行。'
}

validate_root_owned_file() {
  local name="$1" path="$2" uid mode mode_decimal
  [[ "$path" = /* ]] || die "${name} 必须是绝对路径。"
  [ -f "$path" ] && [ ! -L "$path" ] || die "${name} 不是普通文件或是符号链接：${path}"
  uid="$(stat -c '%u' "$path")"
  mode="$(stat -c '%a' "$path")"
  [ "$uid" = '0' ] || die "${name} 必须由 root 所有：${path}"
  mode_decimal=$((8#$mode))
  [ $((mode_decimal & 0022)) -eq 0 ] || die "${name} 不能被 group/world 写入：${path}"
}

capture_managed_binding() {
  local uid mode mode_decimal
  [ -f "$MANAGED_STATE_FILE" ] && [ ! -L "$MANAGED_STATE_FILE" ] ||
    die "managed state 不是普通文件或是符号链接：${MANAGED_STATE_FILE}"
  uid="$(stat -c '%u' "$MANAGED_STATE_FILE")"
  mode="$(stat -c '%a' "$MANAGED_STATE_FILE")"
  [ "$uid" = '0' ] || die "managed state 必须由 root 所有：${MANAGED_STATE_FILE}"
  mode_decimal=$((8#$mode))
  [ $((mode_decimal & 0022)) -eq 0 ] ||
    die "managed state 不能被 group/world 写入：${MANAGED_STATE_FILE}"
  jq -e --arg version "$EXPECTED_TUNING_VERSION" '
    .schema_version == 4 and .state == "VERIFIED" and
    .script_version == $version and
    ((.profile.id == "debian13-1c1g") or (.profile.id == "debian13-1c2g")) and
    .network.port_speed_mbps == 200
  ' "$MANAGED_STATE_FILE" >/dev/null ||
    die 'managed state 不是 rc.19 schema-4 VERIFIED/debian13-1c1g-or-1c2g/200-Mbps 基线。'
  managed_profile_id="$(jq -r '.profile.id' "$MANAGED_STATE_FILE")"
  managed_script_version="$(jq -r '.script_version' "$MANAGED_STATE_FILE")"
  managed_state_sha256_frozen="$(sha256sum "$MANAGED_STATE_FILE" | awk '{print $1}')"
}

verify_session_managed_binding() {
  local actual_hash actual_profile actual_version actual_state actual_port
  [ -f "$MANAGED_STATE_FILE" ] && [ ! -L "$MANAGED_STATE_FILE" ] ||
    die '扫描期间 managed state 消失或变成符号链接。'
  actual_hash="$(sha256sum "$MANAGED_STATE_FILE" | awk '{print $1}')"
  actual_profile="$(jq -r '.profile.id // empty' "$MANAGED_STATE_FILE" 2>/dev/null)"
  actual_version="$(jq -r '.script_version // empty' "$MANAGED_STATE_FILE" 2>/dev/null)"
  actual_state="$(jq -r '.state // empty' "$MANAGED_STATE_FILE" 2>/dev/null)"
  actual_port="$(jq -r '.network.port_speed_mbps // empty' "$MANAGED_STATE_FILE" 2>/dev/null)"
  [ "$actual_hash" = "$managed_state_sha256_frozen" ] &&
    [ "$actual_profile" = "$managed_profile_id" ] &&
    [ "$actual_version" = "$managed_script_version" ] &&
    [ "$actual_state" = 'VERIFIED' ] && [ "$actual_port" = '200' ] ||
    die '扫描期间 managed profile/version/state/port/hash 发生漂移。'
}

verify_tuning_profile_baseline() {
  local log_file="$1" verify_rc=0
  verify_session_managed_binding
  if bash "$tuning_script" verify >"$log_file" 2>&1; then
    verify_rc=0
  else
    verify_rc=$?
  fi
  [ "$verify_rc" -eq 0 ] ||
    die "所选 tuning script 未通过当前 managed state 的只读 verify；退出码 ${verify_rc}。"
  verify_session_managed_binding
}

verify_benchmark_binding() {
  local benchmark_dir="$1" metadata
  metadata="${benchmark_dir}/benchmark-meta.json"
  [ -s "$metadata" ] || die 'benchmark 缺少 benchmark-meta.json，无法验证 profile/state 绑定。'
  jq -e \
    --arg profile "$managed_profile_id" \
    --arg version "$managed_script_version" \
    --arg script_sha256 "$tuning_script_sha256" '
      .schema_version == 1 and
      .profile == $profile and .script_version == $version and
      .script_sha256 == $script_sha256 and .state == "VERIFIED" and
      .state_network.port_speed_mbps == 200
    ' "$metadata" >/dev/null ||
    die 'benchmark metadata 的 profile/version/script/state/port 与冻结 managed binding 不一致。'
}

validate_plan() {
  jq -e --argjson cooldown "$(jq -r '.controls.minimum_cooldown_seconds' "$plan_file")" '
    type == "object" and .schema_version == 3 and
    ((.mode == "reference-screen") or (.mode == "candidate-sweep")) and
    .scope.provider_port_mbit == 200 and
    .reference_rate_mbit == 200 and
    .scope.direction == "upload" and
    .scope.persistent_shaping_authorized == false and
    (.plan_tool_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.benchmark.seconds | type == "number" and floor == . and . >= 5 and . <= 120) and
    (.benchmark.omit_seconds | type == "number" and floor == . and . >= 0 and . <= 10) and
    (.benchmark.parallel | type == "number" and floor == . and . >= 1 and . <= 4) and
    ((.benchmark.family == "auto") or (.benchmark.family == "4") or (.benchmark.family == "6")) and
    .benchmark.direction == "upload" and
    (.controls.minimum_cooldown_seconds | type == "number" and floor == . and . >= 300 and . <= 3600) and
    (.controls.samples_per_state | type == "number" and floor == . and . >= 2 and . <= 5) and
    .controls.automatic_candidate_persistence == false and
    (.controls.minimum_rate_exposure_ratio | type == "number" and
      . >= 0.9 and . <= 1) and
    (.controls.minimum_cpu_idle_percent | type == "number" and . >= 0 and . <= 100) and
    (.controls.maximum_cpu_steal_percent | type == "number" and . >= 0 and . <= 100) and
    .controls.require_zero_softnet_drops == true and
    .controls.require_zero_softnet_time_squeeze == true and
    .controls.require_zero_link_drops_errors == true and
    (if .mode == "reference-screen" then
       .reference_gate.external_reference_required == false and
       .reference_gate.review_acknowledged == false and
       .reference_gate.evidence_manifest_sha256 == null and
       .reference_gate.analysis_sha256 == null and
       .reference_gate.completed_marker_sha256 == null
     else
       .reference_gate.external_reference_required == true and
       .reference_gate.review_acknowledged == true and
       (.reference_gate.evidence_manifest_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
       (.reference_gate.analysis_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
       (.reference_gate.completed_marker_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
     end) and
    .reference_gate.reference_path_recorded == false and
    .reference_gate.persistence_authorized == false and
    (.rates_mbit | type == "array") and
    ((.rates_mbit | length) == (.rates_mbit | unique | length)) and
    (if .mode == "reference-screen" then
       (.rates_mbit | length) == 0
     else
       (.rates_mbit | length) >= 3 and (.rates_mbit | length) <= 8 and
       all(.rates_mbit[]; type == "number" and floor == . and . >= 100 and . <= 199)
     end) and
    (.stages | type == "array" and length >= 2 and length <= 50) and
    (if .mode == "reference-screen" then
       (.stages | length) == .controls.samples_per_state
     else
       (.stages | length) == (.controls.samples_per_state * ((.rates_mbit | length) + 2))
     end) and
    ([.stages[].sequence] == [range(1; (.stages|length) + 1)]) and
    (([.stages[].label] | length) == ([.stages[].label] | unique | length)) and
    all(.stages[];
      (.label | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,63}$")) and
      (.minimum_cooldown_before_seconds | type == "number" and floor == . and . >= 0 and . <= 3600) and
      (.measurements_per_stage == 1) and
      .traffic_cap_enforced_by == "htb-class-rate-and-ceil" and
      .rate_cap_mbit == .rate_mbit and
      (if .condition == "reference-htb" then
         (.rate_mbit == 200 and
          ((.phase == "reference-screen") or (.phase == "reference-start") or (.phase == "reference-end")))
       elif .condition == "candidate-htb" then
         (.phase == "candidate-sweep" and (.rate_mbit | type == "number" and floor == . and . >= 100 and . <= 199))
       else false end)) and
    .stages[0].minimum_cooldown_before_seconds == 0 and
    all(.stages[1:][]; .minimum_cooldown_before_seconds == $cooldown) and
    (if .mode == "reference-screen" then
       all(.stages[]; .condition == "reference-htb" and .phase == "reference-screen")
     else
       ([.stages[] | select(.phase == "reference-start")] | length) == .controls.samples_per_state and
       ([.stages[] | select(.phase == "reference-end")] | length) == .controls.samples_per_state and
       ([.rates_mbit[] as $rate |
         (([.stages[] | select(.condition == "candidate-htb" and .rate_mbit == $rate)] | length) ==
          .controls.samples_per_state)] | all)
     end) and
    .traffic_budget.enforced_by == "htb-class-rate-and-ceil" and
    .traffic_budget.stage_count == (.stages | length) and
    .traffic_budget.payload_upper_bound_bytes ==
      (([.stages[].rate_mbit] | add) * 125000 *
       (.benchmark.seconds + .benchmark.omit_seconds))
  ' "$plan_file" >/dev/null || die '候选扫描计划 schema、范围或阶段约束无效。'
}

capture_htb_runtime() {
  local destination="$1" file
  install -d -o root -g root -m 0700 "$destination"
  for file in active.json original-qdisc.json start-trace.log; do
    if [ -f "${RUNTIME_STATE_DIR}/${file}" ] && [ ! -L "${RUNTIME_STATE_DIR}/${file}" ]; then
      cp -a -- "${RUNTIME_STATE_DIR}/${file}" "${destination}/${file}"
    fi
  done
}

attempt_restore() {
  local log_file
  [ "$htb_started" -eq 1 ] || return 0
  log_file="${output_dir}/emergency-stop-${current_stage}.log"
  warn "阶段 ${current_stage} 未正常结束；尝试调用受管 HTB stop。"
  if "$htb_tool" stop >"$log_file" 2>&1; then
    htb_started=0
    "$htb_tool" preflight >>"$log_file" 2>&1 || true
    return 0
  fi
  warn "自动 stop 失败；保留运行状态。请从服务商控制台检查 ${RUNTIME_STATE_FILE} 和根 qdisc。"
  return 1
}

finish_incomplete() {
  local rc="$1" utc
  [ "$session_created" -eq 1 ] || return 0
  [ ! -f "${output_dir}/COMPLETED" ] || return 0
  utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'status=INCOMPLETE\nstage=%s\nexit_code=%s\nutc=%s\n' \
    "$current_stage" "$rc" "$utc" >"${output_dir}/INCOMPLETE.tmp" 2>/dev/null || return 0
  chmod 0600 "${output_dir}/INCOMPLETE.tmp" 2>/dev/null || true
  mv -f -- "${output_dir}/INCOMPLETE.tmp" "${output_dir}/INCOMPLETE" 2>/dev/null || true
}

known_payload_bytes() {
  local file
  for file in "${output_dir}"/stages/*/benchmark/*.iperf3.json; do
    [ -f "$file" ] || continue
    jq -er '.end.sum_sent.bytes | select(type == "number" and . >= 0 and floor == .)' "$file" 2>/dev/null || true
  done | awk '{total += $1} END {printf "%.0f\n", total}'
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if [ -n "$socket_sampler_pid" ]; then
    kill "$socket_sampler_pid" 2>/dev/null || true
    wait "$socket_sampler_pid" 2>/dev/null || true
    socket_sampler_pid=''
  fi
  if ! attempt_restore; then
    [ "$rc" -ne 0 ] || rc=1
  fi
  if [ "$traffic_reserved" -eq 1 ]; then
    bash "$budget_tool" fail --ledger "$traffic_ledger" --reservation-id "$traffic_reservation_id" --known-bytes "$(known_payload_bytes)" >/dev/null 2>&1 || true
    traffic_reserved=0
  fi
  finish_incomplete "$rc"
  exit "$rc"
}

on_signal() {
  current_stage="signal-$1"
  case "$1" in INT) exit 130 ;; TERM) exit 143 ;; esac
}

write_stage_result() {
  local stage_dir="$1" stage_json="$2" started_utc="$3" completed_utc="$4"
  local benchmark_sha
  benchmark_sha="$(sha256sum "${stage_dir}/benchmark/benchmark-result.json" | awk '{print $1}')"
  jq -n --argjson plan_stage "$stage_json" \
    --slurpfile plan "$plan_file" \
    --slurpfile metadata "${stage_dir}/benchmark/benchmark-meta.json" \
    --arg started_utc "$started_utc" --arg completed_utc "$completed_utc" \
    --arg benchmark_result_sha256 "$benchmark_sha" \
    --arg managed_profile_id "$managed_profile_id" \
    --arg managed_script_version "$managed_script_version" \
    --arg managed_state_sha256 "$managed_state_sha256_frozen" \
    --arg tuning_script_sha256 "$tuning_script_sha256" \
    '($metadata[0].benchmark) as $benchmark |
      if $benchmark.rate_cap_enforced != true or
         $benchmark.rate_cap_method != "iperf3-bitrate" or
         $benchmark.rate_cap_scope != "aggregate-target-divided-across-streams" or
         $benchmark.rate_cap_per_stream_bps !=
           (($plan_stage.rate_cap_mbit * 1000000 / $plan[0].benchmark.parallel) | floor)
      then error("benchmark software rate-cap metadata does not match the stage")
      else {schema_version:3,status:"PASS",plan_stage:$plan_stage,
      started_utc:$started_utc,completed_utc:$completed_utc,
      benchmark_result_sha256:$benchmark_result_sha256,
      managed_binding:{profile_id:$managed_profile_id,
        script_version:$managed_script_version,state:"VERIFIED",
        port_speed_mbps:200,state_sha256:$managed_state_sha256,
        tuning_script_sha256:$tuning_script_sha256},
      benchmark_binding_valid:true,
      qdisc_rate_mbit:$plan_stage.rate_mbit,
      traffic_cap_enforced_by_htb:true,
      software_rate_cap:($benchmark | {
        rate_cap_enforced,rate_cap_method,rate_cap_scope,rate_cap_per_stream_bps}),
      qdisc_restored_to_root_fq:true,persistent_shaping_created:false} end' \
    >"${stage_dir}/stage-result.json.tmp" || die 'benchmark 软件限速记录与阶段请求不一致。'
  mv -f -- "${stage_dir}/stage-result.json.tmp" "${stage_dir}/stage-result.json"
  chmod 0600 "${stage_dir}/stage-result.json"
}

verify_benchmark_completion() {
  local benchmark_dir="$1" actual_result_sha actual_manifest_sha marker_result_sha marker_manifest_sha
  actual_result_sha="$(sha256sum "${benchmark_dir}/benchmark-result.json" | awk '{print $1}')"
  actual_manifest_sha="$(sha256sum "${benchmark_dir}/SHA256SUMS" | awk '{print $1}')"
  marker_result_sha="$(awk -F= '$1 == "result_sha256" {print $2}' "${benchmark_dir}/COMPLETED")"
  marker_manifest_sha="$(awk -F= '$1 == "evidence_manifest_sha256" {print $2}' "${benchmark_dir}/COMPLETED")"
  [ "$marker_result_sha" = "$actual_result_sha" ] &&
    [ "$marker_manifest_sha" = "$actual_manifest_sha" ]
}

extract_socket_metrics() {
  # Whitelist TCP_INFO-style tokens only. Socket headers, endpoints, ports,
  # PIDs, process names and inodes are never emitted.
  awk '
    function allowed(token) {
      return token ~ /^(rto|backoff|rtt|ato|mss|pmtu|rcvmss|advmss|cwnd|ssthresh|bytes_acked|bytes_received|bytes_sent|bytes_retrans|segs_out|segs_in|data_segs_out|data_segs_in|delivered|app_limited|busy|rwnd_limited|sndbuf_limited|reordering|retrans|minrtt|dsack_dups|rcv_ooopack|snd_wnd|rcv_wnd):/
    }
    function rate_keyword(token) {
      return token == "pacing_rate" || token == "delivery_rate"
    }
    function safe_rate(value) {
      return value ~ /^[0-9]+([.][0-9]+)?[KMGTPE]?bps(\/[0-9]+([.][0-9]+)?[KMGTPE]?bps)?$/
    }
    {
      output=""
      for (i=1; i<=NF; i++) {
        if (allowed($i)) output=output (output == "" ? "" : " ") $i
        else if (rate_keyword($i) && i < NF && safe_rate($(i+1))) {
          output=output (output == "" ? "" : " ") $i ":" $(i+1)
          i++
        }
      }
      if (output != "") {
        rows++
        printf "row=%d %s\n", rows, output
      }
    }
    END {printf "metric_rows=%d\n", rows+0}
  '
}

sample_socket_metrics_window() {
  local output="$1" duration="$2" sample
  : >"$output"
  chmod 0600 "$output"
  for ((sample=1; sample<=duration; sample++)); do
    printf 'sample=%s utc=%s\n' "$sample" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$output"
    ss -tinH state established 2>/dev/null | extract_socket_metrics >>"$output"
    [ "$sample" -eq "$duration" ] || sleep 1
  done
}

run_stage() {
  local stage_json="$1" sequence label condition rate rate_cap cooldown stage_dir
  local started_utc completed_utc benchmark_dir benchmark_rc=0 socket_sample_seconds
  sequence="$(jq -r '.sequence' <<<"$stage_json")"
  label="$(jq -r '.label' <<<"$stage_json")"
  condition="$(jq -r '.condition' <<<"$stage_json")"
  rate="$(jq -r '.rate_mbit // empty' <<<"$stage_json")"
  rate_cap="$(jq -r '.rate_cap_mbit' <<<"$stage_json")"
  cooldown="$(jq -r '.minimum_cooldown_before_seconds' <<<"$stage_json")"
  current_stage="$(printf '%02d-%s' "$sequence" "$label")"
  stage_dir="${output_dir}/stages/${current_stage}"
  benchmark_dir="${stage_dir}/benchmark"
  install -d -o root -g root -m 0700 "$stage_dir"
  jq . <<<"$stage_json" >"${stage_dir}/plan-stage.json"
  chmod 0600 "${stage_dir}/plan-stage.json"

  if [ "$cooldown" -gt 0 ]; then
    log "${current_stage}: 冷却 ${cooldown} 秒。"
    sleep "$cooldown"
  fi
  started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "${current_stage}: condition=${condition} rate=${rate:-none}。"

  verify_session_managed_binding
  "$htb_tool" preflight >"${stage_dir}/htb-preflight-before.log" 2>&1
  verify_session_managed_binding
  htb_started=1
  "$htb_tool" start --rate "$rate" >"${stage_dir}/htb-start.log" 2>&1
  "$htb_tool" assert-active --rate "$rate" >"${stage_dir}/htb-active-before.log" 2>&1
  capture_htb_runtime "${stage_dir}/htb-runtime"

  socket_sample_seconds=$((
    $(jq -r '.benchmark.seconds' "$plan_file") +
    $(jq -r '.benchmark.omit_seconds' "$plan_file") + 2
  ))
  sample_socket_metrics_window "${stage_dir}/socket-metrics.txt" "$socket_sample_seconds" &
  socket_sampler_pid=$!

  if env \
    BENCHMARK_HOST="$benchmark_host" \
    BENCHMARK_PORT="$benchmark_port" \
    BENCHMARK_SECONDS="$(jq -r '.benchmark.seconds' "$plan_file")" \
    BENCHMARK_OMIT_SECONDS="$(jq -r '.benchmark.omit_seconds' "$plan_file")" \
    BENCHMARK_PHASE_TIMEOUT_SECONDS="$(jq -r '.benchmark.seconds + .benchmark.omit_seconds + 15' "$plan_file")" \
    BENCHMARK_ENFORCE_RATE_CAP=1 \
    BENCHMARK_PARALLEL="$(jq -r '.benchmark.parallel' "$plan_file")" \
    BENCHMARK_IP_FAMILY="$(jq -r '.benchmark.family' "$plan_file")" \
    BENCHMARK_DIRECTION='upload' \
    BENCHMARK_RATE_CAP_MBPS="$rate_cap" \
    BENCHMARK_RUN_ID="$current_stage" \
    BENCHMARK_OUTPUT_DIR="$benchmark_dir" \
    DVT_TRAFFIC_BUDGET_BYPASS=1 \
    bash "$tuning_script" benchmark >"${stage_dir}/benchmark.log" 2>&1; then
    benchmark_rc=0
  else
    benchmark_rc=$?
  fi
  wait "$socket_sampler_pid" || benchmark_rc=1
  socket_sampler_pid=''

  "$htb_tool" assert-active --rate "$rate" >"${stage_dir}/htb-active-after.log" 2>&1 || benchmark_rc=1
  capture_htb_runtime "${stage_dir}/htb-runtime-after"
  if "$htb_tool" stop >"${stage_dir}/htb-stop.log" 2>&1; then
    htb_started=0
  else
    benchmark_rc=1
  fi
  "$htb_tool" preflight >"${stage_dir}/htb-preflight-after.log" 2>&1 || benchmark_rc=1
  [ "$benchmark_rc" -eq 0 ] || die "${current_stage} benchmark、ACTIVE gate 或恢复失败；退出码 ${benchmark_rc}。"
  [ -f "${benchmark_dir}/COMPLETED" ] && [ ! -f "${benchmark_dir}/INCOMPLETE" ] ||
    die "${current_stage} benchmark 未形成 COMPLETED 终态。"
  (
    cd "$benchmark_dir"
    sha256sum -c SHA256SUMS
  ) >"${stage_dir}/benchmark-manifest-check.log" 2>&1 ||
    die "${current_stage} benchmark SHA256SUMS 校验失败。"
  verify_benchmark_completion "$benchmark_dir" ||
    die "${current_stage} benchmark COMPLETED 与 result/manifest hash 不匹配。"
  verify_benchmark_binding "$benchmark_dir"
  verify_session_managed_binding
  completed_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_stage_result "$stage_dir" "$stage_json" "$started_utc" "$completed_utc"
}

main() {
  local parent output_name plan_sha runner_sha htb_sha analyzer_sha
  local generated_utc stage_json analysis_sha manifest_sha planned_payload actual_payload software_rate_caps

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plan) [ "$#" -ge 2 ] || die '--plan 缺少参数。'; plan_file="$2"; shift 2 ;;
      --output-dir) [ "$#" -ge 2 ] || die '--output-dir 缺少参数。'; output_dir="$2"; shift 2 ;;
      --tuning-script) [ "$#" -ge 2 ] || die '--tuning-script 缺少参数。'; tuning_script="$2"; shift 2 ;;
      --htb-tool) [ "$#" -ge 2 ] || die '--htb-tool 缺少参数。'; htb_tool="$2"; shift 2 ;;
      --analyzer) [ "$#" -ge 2 ] || die '--analyzer 缺少参数。'; analyzer="$2"; shift 2 ;;
      --host) [ "$#" -ge 2 ] || die '--host 缺少参数。'; benchmark_host="$2"; shift 2 ;;
      --port) [ "$#" -ge 2 ] || die '--port 缺少参数。'; benchmark_port="$2"; shift 2 ;;
      --budget-tool) [ "$#" -ge 2 ] || die '--budget-tool 缺少参数。'; budget_tool="$2"; shift 2 ;;
      --ledger) [ "$#" -ge 2 ] || die '--ledger 缺少参数。'; traffic_ledger="$2"; shift 2 ;;
      --window-id) [ "$#" -ge 2 ] || die '--window-id 缺少参数。'; traffic_window_id="$2"; shift 2 ;;
      --budget-bytes) [ "$#" -ge 2 ] || die '--budget-bytes 缺少参数。'; traffic_budget_bytes="$2"; shift 2 ;;
      -h | --help | help) usage; return 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done

  require_root
  for command in awk bash chmod cp date env find flock id install jq mv readlink \
    sha256sum sleep sort ss stat; do
    need_command "$command"
  done
  [ -n "$plan_file" ] && [ -n "$output_dir" ] && [ -n "$tuning_script" ] &&
    [ -n "$htb_tool" ] && [ -n "$analyzer" ] && [ -n "$benchmark_host" ] &&
    [ -n "$budget_tool" ] && [ -n "$traffic_ledger" ] && [ -n "$traffic_window_id" ] &&
    [ -n "$traffic_budget_bytes" ] || {
      usage >&2
      die '缺少必填参数。'
    }
  validate_root_owned_file plan "$plan_file"
  validate_root_owned_file tuning-script "$tuning_script"
  validate_root_owned_file htb-tool "$htb_tool"
  validate_root_owned_file analyzer "$analyzer"
  validate_root_owned_file budget-tool "$budget_tool"
  validate_root_owned_file runner "${BASH_SOURCE[0]}"
  [[ "$benchmark_host" =~ ^[A-Za-z0-9][A-Za-z0-9._:%-]*$ ]] ||
    die 'host 含不支持的字符。'
  [[ "$benchmark_port" =~ ^[0-9]{1,5}$ ]] || die 'port 必须是 1–65535 的整数。'
  benchmark_port=$((10#$benchmark_port))
  [ "$benchmark_port" -ge 1 ] && [ "$benchmark_port" -le 65535 ] ||
    die 'port 必须在 1–65535 之间。'
  validate_plan
  [[ "$traffic_budget_bytes" =~ ^[0-9]+$ ]] && [ "$((10#$traffic_budget_bytes))" -gt 0 ] ||
    die 'budget-bytes 必须是正整数。'
  traffic_budget_bytes=$((10#$traffic_budget_bytes))

  [[ "$output_dir" = /* ]] || die 'output-dir 必须是绝对路径。'
  [ ! -e "$output_dir" ] && [ ! -L "$output_dir" ] || die "output-dir 已存在：${output_dir}"
  parent="$(dirname "$output_dir")"
  [ -d "$parent" ] && [ ! -L "$parent" ] || die 'output-dir 的父目录不存在或是符号链接。'
  parent="$(readlink -f "$parent")"
  output_name="$(basename "$output_dir")"
  output_dir="${parent}/${output_name}"
  umask 077
  install -d -o root -g root -m 0755 /run/lock
  exec 8>"$RUNNER_LOCK"
  flock -n 8 || die '另一个候选速率扫描正在运行。'
  [ ! -e "$RUNTIME_STATE_FILE" ] || die "已有活动 HTB 状态：${RUNTIME_STATE_FILE}"
  "$htb_tool" preflight >/dev/null
  capture_managed_binding
  tuning_script_sha256="$(sha256sum "$tuning_script" | awk '{print $1}')"
  # 历史计划只含有效窗口和预热；执行预留还覆盖硬超时、终止宽限及每流发送余量。
  planned_payload="$(jq -r '
    ([.stages[].rate_cap_mbit] | add) * 125000 *
      (.benchmark.seconds + .benchmark.omit_seconds + 15 + 5) +
      (.stages | length) * .benchmark.parallel * 1048576
  ' "$plan_file")"
  install -d -o root -g root -m 0700 "$output_dir" "${output_dir}/stages"
  session_created=1
  trap on_exit EXIT
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  traffic_reservation_id="htb-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  bash "$budget_tool" reserve --ledger "$traffic_ledger" --window-id "$traffic_window_id" \
    --budget-bytes "$traffic_budget_bytes" --tool htb --run-id "$traffic_reservation_id" \
    --reservation-id "$traffic_reservation_id" --planned-bytes "$planned_payload" >/dev/null ||
    die 'HTB runner 未能保留完整计划的共享流量预算；没有开始扫描。'
  traffic_reserved=1

  generated_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cp -a -- "$plan_file" "${output_dir}/plan.json"
  plan_file="${output_dir}/plan.json"
  plan_sha="$(sha256sum "$plan_file" | awk '{print $1}')"
  runner_sha="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
  htb_sha="$(sha256sum "$htb_tool" | awk '{print $1}')"
  analyzer_sha="$(sha256sum "$analyzer" | awk '{print $1}')"
  jq -n --arg version "$RUNNER_VERSION" --arg generated_utc "$generated_utc" \
    --arg plan_sha256 "$plan_sha" --arg runner_sha256 "$runner_sha" \
    --arg tuning_script "$tuning_script" --arg tuning_sha256 "$tuning_script_sha256" \
    --arg htb_tool "$htb_tool" --arg htb_sha256 "$htb_sha" \
    --arg analyzer "$analyzer" --arg analyzer_sha256 "$analyzer_sha" \
    --arg managed_profile_id "$managed_profile_id" \
    --arg managed_script_version "$managed_script_version" \
    --arg managed_state_file "$MANAGED_STATE_FILE" \
    --arg managed_state_sha256 "$managed_state_sha256_frozen" \
    --arg host "$benchmark_host" --argjson port "$benchmark_port" \
    --arg budget_window "$traffic_window_id" --arg budget_reservation "$traffic_reservation_id" \
    --argjson budget_bytes "$traffic_budget_bytes" --argjson planned_payload "$planned_payload" \
    '{schema_version:2,runner_version:$version,started_utc:$generated_utc,
      plan_sha256:$plan_sha256,runner_sha256:$runner_sha256,
      tuning_script:{path:$tuning_script,sha256:$tuning_sha256},
      htb_tool:{path:$htb_tool,sha256:$htb_sha256},
      analyzer:{path:$analyzer,sha256:$analyzer_sha256},
      managed_binding:{state_file:$managed_state_file,
        profile_id:$managed_profile_id,script_version:$managed_script_version,
        state:"VERIFIED",port_speed_mbps:200,state_sha256:$managed_state_sha256},
       benchmark_endpoint:{host:$host,port:$port,explicitly_supplied:true},
       software_rate_caps:[],
       traffic_budget:{window_id:$budget_window,reservation_id:$budget_reservation,budget_bytes:$budget_bytes,planned_payload_bytes:$planned_payload,protocol_overhead_included:false},
       persistent_shaping_authorized:false}' >"${output_dir}/session-meta.json"
  chmod 0600 "${output_dir}/plan.json" "${output_dir}/session-meta.json"
  printf 'status=INCOMPLETE\nstage=initialization\nutc=%s\n' "$generated_utc" >"${output_dir}/INCOMPLETE"
  chmod 0600 "${output_dir}/INCOMPLETE"
  current_stage='tuning-profile-verify'
  verify_tuning_profile_baseline "${output_dir}/tuning-profile-verify.log"

  while IFS= read -r stage_json; do
    run_stage "$stage_json"
  done < <(jq -c '.stages[]' "$plan_file")

  software_rate_caps="$(jq -s 'map({sequence:.plan_stage.sequence,
    label:.plan_stage.label,software_rate_cap})' "${output_dir}"/stages/*/stage-result.json)"
  jq --argjson software_rate_caps "$software_rate_caps" \
    '.software_rate_caps=$software_rate_caps' "${output_dir}/session-meta.json" \
    >"${output_dir}/session-meta.json.tmp"
  chmod 0600 "${output_dir}/session-meta.json.tmp"
  mv -f -- "${output_dir}/session-meta.json.tmp" "${output_dir}/session-meta.json"

  current_stage='budget-commit'
  actual_payload="$(jq -s '[.[].phases.upload.sender.bytes?] | map(select(type=="number")) | add // 0' "${output_dir}"/stages/*/benchmark/benchmark-result.json)"
  if [ "$(jq -r '.benchmark.omit_seconds' "$plan_file")" -gt 0 ]; then
    bash "$budget_tool" commit-unknown --ledger "$traffic_ledger" --reservation-id "$traffic_reservation_id" \
      --known-bytes "$actual_payload" >/dev/null || die 'HTB runner 无法保守提交共享预算；reservation 保持占用。'
  else
    bash "$budget_tool" commit --ledger "$traffic_ledger" --reservation-id "$traffic_reservation_id" \
      --actual-bytes "$actual_payload" >/dev/null || die 'HTB runner 无法提交共享预算；reservation 保持占用。'
  fi
  traffic_reserved=0

  current_stage='analysis'
  "$analyzer" "$output_dir" >"${output_dir}/sweep-analysis.json.tmp"
  jq -e '.schema_version == 3 and
    ((.status == "REVIEW_REQUIRED") or (.status == "REVIEW_BLOCKED")) and
    .persistence_authorized == false' \
    "${output_dir}/sweep-analysis.json.tmp" >/dev/null || die '候选扫描分析输出无效。'
  chmod 0600 "${output_dir}/sweep-analysis.json.tmp"
  mv -f -- "${output_dir}/sweep-analysis.json.tmp" "${output_dir}/sweep-analysis.json"

  current_stage='manifest'
  (
    cd "$output_dir"
    : >SHA256SUMS.tmp
    while IFS= read -r -d '' file; do
      sha256sum "${file#./}" >>SHA256SUMS.tmp
    done < <(find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.tmp \
      ! -name manifest-check.log ! -name INCOMPLETE ! -name COMPLETED \
      ! -name COMPLETED.tmp -print0 | sort -z)
    [ -s SHA256SUMS.tmp ]
    chmod 0600 SHA256SUMS.tmp
    mv -f SHA256SUMS.tmp SHA256SUMS
    sha256sum -c SHA256SUMS
  ) >"${output_dir}/manifest-check.log" 2>&1 || die '扫描证据 SHA256SUMS 生成或校验失败。'
  # manifest-check.log is deliberately outside SHA256SUMS because it is written
  # while the manifest is being verified.
  analysis_sha="$(sha256sum "${output_dir}/sweep-analysis.json" | awk '{print $1}')"
  manifest_sha="$(sha256sum "${output_dir}/SHA256SUMS" | awk '{print $1}')"
  printf 'status=COMPLETED\nanalysis_sha256=%s\nevidence_manifest_sha256=%s\nutc=%s\n' \
    "$analysis_sha" "$manifest_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${output_dir}/COMPLETED.tmp"
  chmod 0600 "${output_dir}/COMPLETED.tmp"
  mv -f -- "${output_dir}/COMPLETED.tmp" "${output_dir}/COMPLETED"
  rm -f -- "${output_dir}/INCOMPLETE"
  current_stage='completed'
  trap - EXIT INT TERM
  log "扫描完成：${output_dir}"
  log 'sweep-analysis.json 仅提供人工复核 shortlist；不会授权持久化 HTB。'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
