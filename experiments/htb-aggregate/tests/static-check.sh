#!/usr/bin/env bash
# Test fixtures intentionally source reviewed scripts through computed paths,
# pass globals into sourced functions, and search source files for literal '$'.
# shellcheck disable=SC1090,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329

set -Eeuo pipefail
IFS=$'\n\t'

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
experiment_dir="$(cd -- "${test_dir}/.." && pwd)"
script="${experiment_dir}/htb-aggregate-experiment.sh"
plan_script="${experiment_dir}/experiment-plan.sh"
rate_sweep_plan_script="${experiment_dir}/rate-sweep-plan.sh"
rate_sweep_runner="${experiment_dir}/rate-sweep-run.sh"
rate_sweep_analyzer="${experiment_dir}/rate-sweep-analyze.sh"
invalid_receiver_fixture="${test_dir}/fixtures/iperf3-invalid-receiver-window.json"
legacy_doc="${experiment_dir}/../../docs/experiments/vmiss-basic-200mbps-htb-aba.md"
basic_campaign_doc="${experiment_dir}/../../docs/experiments/vmiss-basic-1c1g-200mbps-htb-campaign.md"
doc="${experiment_dir}/../../docs/experiments/vmiss-1c2g-200mbps-htb-aba.md"
rate_sweep_doc="${experiment_dir}/../../docs/experiments/htb-candidate-rate-sweep.md"

bash -n "$script"
bash -n "$plan_script"
bash -n "$rate_sweep_plan_script"
bash -n "$rate_sweep_runner"
bash -n "$rate_sweep_analyzer"
awk '
  /^run_htb_block\(\) \($/ { capture=1 }
  capture { print }
  capture && /^\)$/ { exit }
' "$doc" | bash -n
for function_name in verify_decision_file record_stage_state run_tcpquality_once run_a_stage run_b_stage \
  run_business_candidate_window; do
  awk -v function_name="$function_name" '
    $0 == function_name "() {" || $0 == function_name "() (" { capture=1 }
    capture { print }
    capture && ($0 == "}" || $0 == ")") { exit }
  ' "$basic_campaign_doc" | bash -n
done
awk '
  /^run_one_block\(\) \($/ { capture=1 }
  capture { print }
  capture && /^\)$/ { exit }
' "$doc" | bash -n
awk '
  /^run_smoke_gate\(\) \($/ { capture=1 }
  capture { print }
  capture && /^\)$/ { exit }
' "$doc" | bash -n
test_path="$PATH"
source "$script"
PATH="$test_path"

stage_trace="$(mktemp)"
START_TRACE_FILE="$stage_trace"
tc() {
  printf 'mock tc failure\n'
  return 42
}
if run_tc_stage mock-stage qdisc replace dev eth0 root fq; then
  printf 'run_tc_stage hid a tc pipeline failure\n' >&2
  exit 1
fi
grep -Fq 'mock tc failure' "$stage_trace"
rm -f -- "$stage_trace"

QDISC_JSON='[]'
CLASS_JSON='[]'
current_qdisc_json() { printf '%s\n' "$QDISC_JSON"; }
current_class_json() { printf '%s\n' "$CLASS_JSON"; }

QDISC_JSON='[
  {"kind":"htb","handle":"1:","root":true,"options":{"default":16}},
  {"kind":"fq","handle":"10:","parent":"1:10","options":{"limit":10000}},
  {"kind":"ingress","handle":"ffff:","parent":"ffff:fff1"}
]'
CLASS_JSON='[
  {"class":"htb","handle":"1:10","root":true,"leaf":"0x10","rate":23750000,"ceil":23750000}
]'
verify_experiment_topology eth0 190

CLASS_JSON='[
  {"class":"htb","handle":"1:10","root":true,"leaf":"0x10","rate":25000000,"ceil":25000000}
]'
verify_experiment_topology eth0 200

CLASS_JSON='[
  {"kind":"htb","classid":"1:10","root":true,"options":{"rate":23750000,"ceil":23750000}}
]'
verify_experiment_topology eth0 190

CLASS_JSON='[
  {"class":"htb","handle":"1:10","root":true,"rate":22500000,"ceil":22500000}
]'
if verify_experiment_topology eth0 190; then
  printf 'topology validator accepted the wrong HTB rate and ceil\n' >&2
  exit 1
fi

QDISC_JSON='[
  {"kind":"htb","handle":"1:","root":true},
  {"kind":"pfifo","handle":"10:","parent":"1:10"}
]'
if verify_experiment_topology eth0 190; then
  printf 'topology validator accepted a non-fq leaf\n' >&2
  exit 1
fi

QDISC_JSON='[
  {"kind":"htb","handle":"1:","root":true},
  {"kind":"fq","handle":"10:","parent":"1:10"}
]'
CLASS_JSON='[]'
if verify_experiment_topology eth0 190; then
  printf 'topology validator accepted a missing HTB class\n' >&2
  exit 1
fi

QDISC_JSON='[{"kind":"fq","handle":"8001:","root":true}]'
CLASS_JSON='[]'
verify_plain_fq_topology eth0

fixture_dir="$(mktemp -d)"
trap 'rm -rf -- "$fixture_dir"' EXIT
MANAGED_STATE_FILE="${fixture_dir}/managed-state.json"
STATE_FILE="${fixture_dir}/active.json"
normalized_sysctl() {
  case "$1" in
    net.ipv4.tcp_congestion_control) printf 'bbr\n' ;;
    net.core.default_qdisc) printf 'fq\n' ;;
    net.ipv4.tcp_rmem) printf '4096 131072 16777216\n' ;;
    net.ipv4.tcp_wmem) printf '4096 65536 16777216\n' ;;
    *) return 1 ;;
  esac
}
systemctl() {
  [ "$1" = 'is-active' ]
}
write_managed_fixture() {
  local profile="$1" schema="${2:-4}" version="${3:-0.2.0-rc.1}" port="${4:-200}"
  jq -n \
    --arg profile "$profile" \
    --arg version "$version" \
    --argjson schema "$schema" \
    --argjson port "$port" \
    '{schema_version:$schema,script_version:$version,state:"VERIFIED",
      profile:{id:$profile},network:{port_speed_mbps:$port}}' >"$MANAGED_STATE_FILE"
}

write_managed_fixture debian13-1c1g
verify_managed_host_baseline
write_managed_fixture debian13-1c2g
verify_managed_host_baseline
for rejected_profile in debian12-1c2g debian13-2c2g arbitrary-profile; do
  write_managed_fixture "$rejected_profile"
  if (verify_managed_host_baseline) >/dev/null 2>&1; then
    printf 'managed baseline accepted unsupported profile: %s\n' "$rejected_profile" >&2
    exit 1
  fi
done
write_managed_fixture debian13-1c2g 3
if (verify_managed_host_baseline) >/dev/null 2>&1; then
  printf 'managed baseline accepted schema 3\n' >&2
  exit 1
fi
write_managed_fixture debian13-1c2g 4 0.1.0-rc.11
if (verify_managed_host_baseline) >/dev/null 2>&1; then
  printf 'managed baseline accepted rc.11\n' >&2
  exit 1
fi
write_managed_fixture debian13-1c2g 4 0.2.0-rc.1 500
if (verify_managed_host_baseline) >/dev/null 2>&1; then
  printf 'managed baseline accepted 500 Mbps\n' >&2
  exit 1
fi

write_managed_fixture debian13-1c2g
managed_hash="$(managed_state_sha256)"
jq -n --arg hash "$managed_hash" \
  '{managed_profile_id:"debian13-1c2g",managed_state_sha256:$hash}' >"$STATE_FILE"
verify_active_managed_binding
write_managed_fixture debian13-1c1g
if (verify_active_managed_binding) >/dev/null 2>&1; then
  printf 'active binding accepted managed profile/hash drift\n' >&2
  exit 1
fi

grep -Fq 'qdisc replace dev "$iface" parent 1:10 handle 10: fq' "$script"
if grep -Fq 'qdisc add dev ${iface} parent 1:10' "$script"; then
  printf 'legacy leaf qdisc add command is still present\n' >&2
  exit 1
fi
grep -Fq 'start_stage=${stage} action=FAIL' "$script"
grep -Fq 'tc "$@" 2>&1 | tee -a "$START_TRACE_FILE"' "$script"
grep -Fq 'active-check=PASS' "$script"
grep -Fq 'smoke-test=PASS' "$script"
grep -Fq 'rate 必须在 100–200 Mbit/s 之间。' "$script"
if grep -Fq 'rate 必须在 100–199 Mbit/s 之间。' "$script"; then
  printf 'HTB executor still rejects the reviewed 200-Mbit reference rate\n' >&2
  exit 1
fi
grep -Fq '2>&1 | tee "$HTB_START_LOG"' "$doc"
grep -Fq 'HTB_START_RC=${PIPESTATUS[0]}' "$doc"
grep -Fq 'trap cleanup_htb_block EXIT' "$doc"
grep -Fq '2>&1 | tee -a "$HTB_AFTER_LOG"' "$doc"
grep -Fq 'if run_smoke_gate; then' "$doc"
grep -Fq 'SMOKE_GATE=FAIL' "$doc"
grep -Fq 'experiment-plan.sh' "$doc"
grep -Fq 'TCPQUALITY_RUNS=1' "$doc"
grep -Fq -- '--window-order bab' "$doc"
grep -Fq '状态：研究专用协议；默认不执行' "$basic_campaign_doc"
grep -Fq 'TCPQUALITY_RUNS=1' "$basic_campaign_doc"
grep -Fq -- '--samples 5' "$basic_campaign_doc"
grep -Fq -- '--window-order aba' "$basic_campaign_doc"
grep -Fq -- '--window-order bab' "$basic_campaign_doc"
grep -Fq '不授权创建开机持久 HTB' "$basic_campaign_doc"
grep -Fq 'TOOL_VERSION='"'"'0.4.0'"'"'' "$script"
grep -Fq 'managed_state_sha256' "$script"
grep -Fq 'debian13-1c2g' "$script"
grep -Fq 'A1-fq' "$plan_script"
grep -Fq 'B2-htb-candidate' "$plan_script"
grep -Fq 'C1-htb-control' "$plan_script"
grep -Fq 'reference-screen' "$rate_sweep_plan_script"
grep -Fq 'candidate-sweep' "$rate_sweep_plan_script"
grep -Fq 'forward-reverse-candidates-between-repeated-htb200-references' "$rate_sweep_plan_script"
grep -Fq 'BENCHMARK_DIRECTION='"'"'upload'"'"'' "$rate_sweep_runner"
grep -Fq '"$htb_tool" assert-active --rate "$rate"' "$rate_sweep_runner"
grep -Fq '"$htb_tool" stop' "$rate_sweep_runner"
grep -Fq 'fixed_global_retransmission_threshold_used:false' "$rate_sweep_analyzer"
grep -Fq 'persistence_authorized:false' "$rate_sweep_analyzer"
grep -Fq 'rate-sweep-plan.sh' "$rate_sweep_doc"
grep -Fq 'rate-sweep-run.sh' "$rate_sweep_doc"
grep -Fq 'rate-sweep-analyze.sh' "$rate_sweep_doc"
grep -Fq "IPERF_DNS='lax.speedtest.is.cc'" "$rate_sweep_doc"
grep -Fq 'IPERF_PORT=5209' "$rate_sweep_doc"
grep -Fq "ENDPOINT_FILE='/root/htb-iperf-endpoint.json'" "$rate_sweep_doc"
grep -Fq -- '--host "$IPERF_HOST"' "$rate_sweep_doc"
grep -Fq -- '--port "$IPERF_PORT"' "$rate_sweep_doc"
if grep -Fq 'AUTHORIZED_IPERF3_HOST' "$rate_sweep_doc"; then
  printf 'rate sweep SOP still contains an unresolved iperf3 host placeholder\n' >&2
  exit 1
fi
grep -Fq '本 SOP **不是实验入口**' "$doc"
legacy_script_sha256='5b0bd160205f9408514d067e9faeb229f58b800f40e39412b9e221929772ca1a'
grep -Fq "'${legacy_script_sha256}'" "$legacy_doc"
script_sha256="$(sha256sum "$script" | awk '{print $1}')"
grep -Fq "'${script_sha256}'" "$doc"

run_plan_fixture() (
  local inherited_path="$PATH"
  # shellcheck disable=SC1090
  source "$plan_script"
  PATH="$inherited_path"
  main "$@"
)

plan_json="$(run_plan_fixture --window-id basic-window-1 --window-order aba)"
jq -e '
  .schema_version == 2 and .mode == "read-only-plan" and
  (.plan_tool_sha256 | test("^[0-9a-f]{64}$")) and
  .window.id == "basic-window-1" and .window.order == "aba" and
  .window.evidence_directory_must_be_new == true and
  .window.separate_operator_invocation_required == true and
  .candidate.rate_mbit == 190 and
  (.candidate.stages | length) == 3 and
  .candidate.stages[0].label == "A1-fq" and
  .candidate.stages[2].label == "A2-fq" and
  .controls.minimum_cooldown_seconds == 300 and
  .controls.exactly_one_window_per_plan == true and
  .controls.opposite_order_requires_distinct_window_id == true and
  .controls.automatic_execution == false and
  .controls.persistent_shaping_authorized == false and
  .lower_rate_control.enabled == false
' <<<"$plan_json" >/dev/null

plan_json="$(run_plan_fixture --window-id basic-window-2 --window-order bab \
  --candidate-rate 190 --cooldown-seconds 600 --control-rate 180)"
jq -e '
  .window.id == "basic-window-2" and .window.order == "bab" and
  (.candidate.stages | length) == 3 and
  .candidate.stages[0].label == "B2-htb-candidate" and
  .candidate.stages[1].label == "A3-fq" and
  .candidate.stages[2].label == "B3-htb-candidate" and
  .controls.minimum_cooldown_seconds == 600 and
  .lower_rate_control.enabled == true and
  .lower_rate_control.rate_mbit == 180 and
  .lower_rate_control.requires_candidate_result_closed == true and
  (.lower_rate_control.stages | length) == 3
' <<<"$plan_json" >/dev/null

if run_plan_fixture --window-id invalid-control --control-rate 190 >/dev/null 2>&1; then
  printf 'experiment plan accepted control-rate equal to candidate-rate\n' >&2
  exit 1
fi
if run_plan_fixture --window-id invalid-cooldown --cooldown-seconds 299 >/dev/null 2>&1; then
  printf 'experiment plan accepted cooldown below 300 seconds\n' >&2
  exit 1
fi
if run_plan_fixture --window-order aba >/dev/null 2>&1; then
  printf 'experiment plan accepted a missing window-id\n' >&2
  exit 1
fi
if run_plan_fixture --window-id combined --repeat-cycles 2 >/dev/null 2>&1; then
  printf 'experiment plan still accepted a combined two-window plan\n' >&2
  exit 1
fi

run_rate_sweep_plan_fixture() (
  local inherited_path="$PATH"
  # shellcheck disable=SC1090
  source "$rate_sweep_plan_script"
  PATH="$inherited_path"
  main "$@"
)

reference_manifest_fixture_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
reference_analysis_fixture_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
reference_completed_fixture_sha='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
candidate_reference_args=(
  --ack-reference-reviewed
  --reference-manifest-sha256 "$reference_manifest_fixture_sha"
  --reference-analysis-sha256 "$reference_analysis_fixture_sha"
  --reference-completed-sha256 "$reference_completed_fixture_sha"
)

reference_plan_json="$(run_rate_sweep_plan_fixture)"
jq -e '
  .schema_version == 3 and
  .mode == "reference-screen" and
  .scope.provider_port_mbit == 200 and
  .scope.direction == "upload" and
  .scope.persistent_shaping_authorized == false and
  .reference_rate_mbit == 200 and
  .reference_gate.external_reference_required == false and
  .reference_gate.review_acknowledged == false and
  .reference_gate.evidence_manifest_sha256 == null and
  .reference_gate.analysis_sha256 == null and
  .reference_gate.completed_marker_sha256 == null and
  .reference_gate.persistence_authorized == false and
  .rates_mbit == [] and
  .controls.samples_per_state == 3 and
  .controls.minimum_cooldown_seconds == 300 and
  .controls.minimum_rate_exposure_ratio == 0.9 and
  .controls.minimum_cpu_idle_percent == 5 and
  .controls.maximum_cpu_steal_percent == 5 and
  .controls.require_zero_softnet_drops == true and
  .benchmark.direction == "upload" and
  (.stages | length) == 3 and
  .stages[0].label == "R-s1-htb200" and
  .stages[-1].label == "R-s3-htb200" and
  all(.stages[]; .condition == "reference-htb" and .rate_mbit == 200 and
    .rate_cap_mbit == 200 and .traffic_cap_enforced_by == "htb-class-rate-and-ceil") and
  .traffic_budget.enforced_by == "htb-class-rate-and-ceil" and
  .traffic_budget.payload_upper_bound_bytes ==
    ([.stages[].rate_mbit] | add) * 125000 *
    (.benchmark.seconds + .benchmark.omit_seconds) and
  (.interpretation.retransmission_metric | contains("retransmits_per_gib"))
' <<<"$reference_plan_json" >/dev/null

rate_sweep_plan_json="$(run_rate_sweep_plan_fixture --mode candidate-sweep \
  "${candidate_reference_args[@]}")"
jq -e --arg manifest "$reference_manifest_fixture_sha" \
  --arg analysis "$reference_analysis_fixture_sha" \
  --arg completed "$reference_completed_fixture_sha" '
  .schema_version == 3 and .mode == "candidate-sweep" and
  .reference_gate.external_reference_required == true and
  .reference_gate.review_acknowledged == true and
  .reference_gate.evidence_manifest_sha256 == $manifest and
  .reference_gate.analysis_sha256 == $analysis and
  .reference_gate.completed_marker_sha256 == $completed and
  .reference_gate.reference_path_recorded == false and
  .reference_gate.persistence_authorized == false and
  .rates_mbit == [180,190,195] and
  (.stages | length) == 15 and
  .stages[0].label == "A-start-s1-htb200" and
  .stages[3].label == "B-r1-rate180" and
  .stages[6].label == "B-r2-rate195" and
  .stages[-1].label == "A-end-s3-htb200" and
  all(.stages[]; .rate_cap_mbit == .rate_mbit and
    .traffic_cap_enforced_by == "htb-class-rate-and-ceil")
' <<<"$rate_sweep_plan_json" >/dev/null

rate_sweep_plan_json="$(run_rate_sweep_plan_fixture \
  --mode candidate-sweep \
  "${candidate_reference_args[@]}" \
  --rates 150,180,190 --samples-per-state 2 --cooldown-seconds 600 \
  --benchmark-seconds 12 --omit-seconds 0 --parallel 1 --family 6)"
jq -e '
  .rates_mbit == [150,180,190] and
  (.stages | length) == 10 and
  .controls.minimum_cooldown_seconds == 600 and
  .benchmark.seconds == 12 and .benchmark.omit_seconds == 0 and
  .benchmark.family == "6"
' <<<"$rate_sweep_plan_json" >/dev/null

if run_rate_sweep_plan_fixture --mode candidate-sweep >/dev/null 2>&1; then
  printf 'candidate rate plan accepted missing reviewed-reference binding\n' >&2
  exit 1
fi
if run_rate_sweep_plan_fixture --mode candidate-sweep \
  --ack-reference-reviewed \
  --reference-manifest-sha256 "$reference_manifest_fixture_sha" \
  --reference-analysis-sha256 "$reference_analysis_fixture_sha" >/dev/null 2>&1; then
  printf 'candidate rate plan accepted an incomplete reviewed-reference binding\n' >&2
  exit 1
fi
if run_rate_sweep_plan_fixture --mode reference-screen \
  "${candidate_reference_args[@]}" >/dev/null 2>&1; then
  printf 'reference plan accepted candidate-only reviewed-reference binding\n' >&2
  exit 1
fi

for invalid_args in \
  '--port-rate 500' \
  '--mode reference-screen --rates 180,190,195' \
  '--samples-per-state 1' \
  '--cooldown-seconds 299' \
  '--minimum-rate-exposure-percent 89' \
  '--minimum-rate-exposure-percent 101' \
  '--minimum-cpu-idle-percent 101' \
  '--maximum-cpu-steal-percent 101'; do
  # shellcheck disable=SC2086
  if run_rate_sweep_plan_fixture $invalid_args >/dev/null 2>&1; then
    printf 'candidate rate plan accepted invalid arguments: %s\n' "$invalid_args" >&2
    exit 1
  fi
done

for invalid_rates in 150,150,190 99,180,190 150,180,200 150,190; do
  if run_rate_sweep_plan_fixture --mode candidate-sweep \
    "${candidate_reference_args[@]}" --rates "$invalid_rates" >/dev/null 2>&1; then
    printf 'candidate rate plan accepted invalid rates: %s\n' "$invalid_rates" >&2
    exit 1
  fi
done

runner_plan="${fixture_dir}/runner-plan.json"
printf '%s\n' "$rate_sweep_plan_json" >"$runner_plan"
run_runner_plan_validation_fixture() (
  local_path="$PATH"
  # shellcheck disable=SC1090
  source "$rate_sweep_runner"
  PATH="$local_path"
  plan_file="$1"
  validate_plan
)
run_runner_plan_validation_fixture "$runner_plan"
invalid_runner_plan="${fixture_dir}/runner-plan-invalid.json"
jq '.traffic_budget.payload_upper_bound_bytes += 1' "$runner_plan" >"$invalid_runner_plan"
if run_runner_plan_validation_fixture "$invalid_runner_plan" >/dev/null 2>&1; then
  printf 'rate sweep runner accepted a plan with a mismatched traffic budget\n' >&2
  exit 1
fi

socket_metrics_fixture="$(
  (
  inherited_path="$PATH"
  # shellcheck disable=SC1090
  source "$rate_sweep_runner"
  PATH="$inherited_path"
  printf '%s\n' \
    'ESTAB 0 0 198.51.100.10:50123 192.0.2.10:5201 users:(("iperf3",pid=123,fd=4))' \
    ' cubic wscale:7,7 rto:204 rtt:2.5/0.4 mss:1448 pmtu:1500 cwnd:32 bytes_sent:1073741824 bytes_retrans:5792 segs_out:741000 retrans:0/4 reordering:3 pacing_rate 201Mbps delivery_rate 188.5Mbps minrtt:1.9 dsack_dups:2 rcv_ooopack:3 snd_wnd:4194304 rcv_wnd:2097152' |
    extract_socket_metrics
  )
)"
grep -Fq 'rto:204' <<<"$socket_metrics_fixture"
grep -Fq 'rtt:2.5/0.4' <<<"$socket_metrics_fixture"
grep -Fq 'bytes_retrans:5792' <<<"$socket_metrics_fixture"
grep -Fq 'pacing_rate:201Mbps' <<<"$socket_metrics_fixture"
grep -Fq 'delivery_rate:188.5Mbps' <<<"$socket_metrics_fixture"
grep -Fq 'minrtt:1.9' <<<"$socket_metrics_fixture"
grep -Fq 'dsack_dups:2' <<<"$socket_metrics_fixture"
grep -Fq 'rcv_ooopack:3' <<<"$socket_metrics_fixture"
grep -Fq 'snd_wnd:4194304' <<<"$socket_metrics_fixture"
grep -Fq 'rcv_wnd:2097152' <<<"$socket_metrics_fixture"
grep -Fq 'metric_rows=1' <<<"$socket_metrics_fixture"
if grep -Eq '198\.51\.100\.|192\.0\.2\.|5201|iperf3|pid=|fd=' <<<"$socket_metrics_fixture"; then
  printf 'socket metric whitelist leaked endpoint or process details\n' >&2
  exit 1
fi

runner_fixture="${fixture_dir}/runner-execution"
mock_runtime="${runner_fixture}/runtime"
mock_output="${runner_fixture}/evidence"
mock_htb="${runner_fixture}/mock-htb"
mock_tuning="${runner_fixture}/mock-tuning.sh"
mock_managed_state="${runner_fixture}/managed-state.json"
mkdir -p "$runner_fixture" "$mock_runtime" "${mock_output}/stages"
cat >"$mock_htb" <<'EOF_MOCK_HTB'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
  preflight) [ ! -e "${MOCK_RUNTIME_DIR}/active.json" ] ;;
  start)
    printf '%s\n' '{"active":true}' >"${MOCK_RUNTIME_DIR}/active.json"
    printf '%s\n' '[{"kind":"fq","root":true}]' >"${MOCK_RUNTIME_DIR}/original-qdisc.json"
    printf '%s\n' 'mock start trace' >"${MOCK_RUNTIME_DIR}/start-trace.log"
    ;;
  assert-active) [ -s "${MOCK_RUNTIME_DIR}/active.json" ] ;;
  stop) rm -f -- "${MOCK_RUNTIME_DIR}/active.json" ;;
  *) exit 2 ;;
esac
EOF_MOCK_HTB
cat >"$mock_tuning" <<'EOF_MOCK_TUNING'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  verify) exit "${MOCK_VERIFY_RC:-0}" ;;
  benchmark) ;;
  *) exit 2 ;;
esac
mkdir -p -- "$BENCHMARK_OUTPUT_DIR"
printf '%s\n' '{"schema_version":3,"direction":"upload","reverse":false,"measurement_window":{"status":"VALID","valid":true,"issues":[]}}' \
  >"${BENCHMARK_OUTPUT_DIR}/upload.summary.json"
printf '%s\n' '{"schema_version":1,"status":"PASS","exit_code":0,"phases":{"upload":{},"download":null}}' \
  >"${BENCHMARK_OUTPUT_DIR}/benchmark-result.json"
script_sha="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
jq -n --arg script_sha "$script_sha" \
  --argjson enforced "$BENCHMARK_ENFORCE_RATE_CAP" \
  --argjson rate "$BENCHMARK_RATE_CAP_MBPS" --argjson parallel "$BENCHMARK_PARALLEL" \
  '{schema_version:1,script_version:"0.2.0-rc.1",profile:"debian13-1c1g",
    script_sha256:$script_sha,state:"VERIFIED",state_network:{port_speed_mbps:200},
    benchmark:{rate_cap_enforced:($enforced == 1),rate_cap_method:"iperf3-bitrate",
      rate_cap_scope:"aggregate-target-divided-across-streams",
      rate_cap_per_stream_bps:(($rate * 1000000 / $parallel) | floor)}}' \
  >"${BENCHMARK_OUTPUT_DIR}/benchmark-meta.json"
printf 'user\t100\nnice\t0\nsystem\t50\nidle\t100\niowait\t0\nirq\t0\nsoftirq\t10\nsteal\t0\n' \
  >"${BENCHMARK_OUTPUT_DIR}/upload.cpu.before"
printf 'user\t140\nnice\t0\nsystem\t70\nidle\t130\niowait\t0\nirq\t0\nsoftirq\t20\nsteal\t0\n' \
  >"${BENCHMARK_OUTPUT_DIR}/upload.cpu.after"
printf '0\t100\t0\t0\n' >"${BENCHMARK_OUTPUT_DIR}/upload.softnet.before"
printf '0\t200\t0\t0\n' >"${BENCHMARK_OUTPUT_DIR}/upload.softnet.after"
(
  cd "$BENCHMARK_OUTPUT_DIR"
  sha256sum upload.summary.json benchmark-meta.json upload.cpu.before upload.cpu.after \
    upload.softnet.before upload.softnet.after >SHA256SUMS
)
result_sha="$(sha256sum "${BENCHMARK_OUTPUT_DIR}/benchmark-result.json" | awk '{print $1}')"
manifest_sha="$(sha256sum "${BENCHMARK_OUTPUT_DIR}/SHA256SUMS" | awk '{print $1}')"
printf 'status=COMPLETED\nevidence_manifest_sha256=%s\nresult_sha256=%s\n' \
  "$manifest_sha" "$result_sha" >"${BENCHMARK_OUTPUT_DIR}/COMPLETED"
EOF_MOCK_TUNING
chmod 0700 "$mock_htb" "$mock_tuning"
jq -n '{schema_version:4,script_version:"0.2.0-rc.1",state:"VERIFIED",
  profile:{id:"debian13-1c1g"},network:{port_speed_mbps:200}}' >"$mock_managed_state"
if ! (
  inherited_path="$PATH"
  # shellcheck disable=SC1090
  source "$rate_sweep_runner"
  PATH="$inherited_path"
  export MOCK_RUNTIME_DIR="$mock_runtime"
  RUNTIME_STATE_DIR="$mock_runtime"
  RUNTIME_STATE_FILE="${mock_runtime}/active.json"
  MANAGED_STATE_FILE="$mock_managed_state"
  managed_profile_id='debian13-1c1g'
  managed_script_version='0.2.0-rc.1'
  managed_state_sha256_frozen="$(sha256sum "$mock_managed_state" | awk '{print $1}')"
  output_dir="$mock_output"
  plan_file="$runner_plan"
  htb_tool="$mock_htb"
  tuning_script="$mock_tuning"
  tuning_script_sha256="$(sha256sum "$mock_tuning" | awk '{print $1}')"
  benchmark_host='192.0.2.10'
  benchmark_port=5201
  install() {
    local target="${*: -1}"
    mkdir -p -- "$target"
    chmod 0700 "$target"
  }
  sleep() { :; }
  ss() {
    printf '%s\n' \
      'ESTAB 0 0 198.51.100.10:50123 192.0.2.10:5201 users:(("iperf3",pid=123,fd=4))' \
      ' cubic rto:204 rtt:2.5/0.4 mss:1448 cwnd:32 bytes_retrans:5792 retrans:0/4 reordering:3 pacing_rate 201Mbps delivery_rate 188.5Mbps minrtt:1.9 dsack_dups:2 rcv_ooopack:3 snd_wnd:4194304 rcv_wnd:2097152'
  }
  verify_tuning_profile_baseline "${mock_output}/tuning-profile-verify.log"
  shaped_stage="$(jq -c 'first(.stages[])' "$runner_plan")"
  run_stage "$shaped_stage"
  [ "$htb_started" -eq 0 ]
  [ ! -e "$RUNTIME_STATE_FILE" ]
); then
  printf 'mock rate sweep runner stage failed\n' >&2
  for runner_log in "${mock_output}"/stages/*/benchmark.log "${mock_output}"/stages/*/htb-*.log; do
    [ -f "$runner_log" ] || continue
    printf '%s\n' "===== ${runner_log} =====" >&2
    sed -n '1,160p' "$runner_log" >&2
  done
  exit 1
fi
runner_stage_dir="$(printf '%s\n' "${mock_output}"/stages/*/ | head -n 1)"
jq -e '.status == "PASS" and .qdisc_restored_to_root_fq == true and
  .persistent_shaping_created == false and .benchmark_binding_valid == true and
  .managed_binding.profile_id == "debian13-1c1g" and
  .managed_binding.state == "VERIFIED" and
  .software_rate_cap.rate_cap_enforced == true and
  .software_rate_cap.rate_cap_method == "iperf3-bitrate" and
  .software_rate_cap.rate_cap_scope == "aggregate-target-divided-across-streams" and
  .software_rate_cap.rate_cap_per_stream_bps == 200000000' "${runner_stage_dir}/stage-result.json" >/dev/null
grep -Fq 'rtt:2.5/0.4' "${runner_stage_dir}/socket-metrics.txt"
grep -Fq 'pacing_rate:201Mbps' "${runner_stage_dir}/socket-metrics.txt"
grep -Fq 'delivery_rate:188.5Mbps' "${runner_stage_dir}/socket-metrics.txt"
grep -Fq 'minrtt:1.9' "${runner_stage_dir}/socket-metrics.txt"
if grep -Eq '198\.51\.100\.|192\.0\.2\.|5201|iperf3|pid=|fd=' \
  "${runner_stage_dir}/socket-metrics.txt"; then
  printf 'runner socket metric evidence leaked endpoint or process details\n' >&2
  exit 1
fi

mismatch_marker="${runner_fixture}/benchmark-after-failed-verify"
if (
  inherited_path="$PATH"
  # shellcheck disable=SC1090
  source "$rate_sweep_runner"
  PATH="$inherited_path"
  MANAGED_STATE_FILE="$mock_managed_state"
  managed_profile_id='debian13-1c1g'
  managed_script_version='0.2.0-rc.1'
  managed_state_sha256_frozen="$(sha256sum "$mock_managed_state" | awk '{print $1}')"
  tuning_script="$mock_tuning"
  export MOCK_VERIFY_RC=4
  verify_tuning_profile_baseline "${runner_fixture}/mismatched-profile-verify.log"
  : >"$mismatch_marker"
) >/dev/null 2>&1; then
  printf 'runner accepted a tuning profile that failed managed-state verify\n' >&2
  exit 1
fi
[ ! -e "$mismatch_marker" ] || {
  printf 'runner reached the benchmark path after failed profile verify\n' >&2
  exit 1
}

sweep_fixture="${fixture_dir}/sweep-evidence"
mkdir -p "${sweep_fixture}/stages"
cp "$runner_plan" "${sweep_fixture}/plan.json"
fixture_tuning_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
fixture_state_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
jq -n --arg tuning_sha "$fixture_tuning_sha" --arg state_sha "$fixture_state_sha" '
  {schema_version:2,runner_version:"0.3.0",tuning_script:{sha256:$tuning_sha},
   managed_binding:{profile_id:"debian13-1c1g",script_version:"0.2.0-rc.1",
     state:"VERIFIED",port_speed_mbps:200,state_sha256:$state_sha},
   persistent_shaping_authorized:false}' >"${sweep_fixture}/session-meta.json"
while IFS= read -r sweep_stage; do
  sequence="$(jq -r '.sequence' <<<"$sweep_stage")"
  label="$(jq -r '.label' <<<"$sweep_stage")"
  phase="$(jq -r '.phase' <<<"$sweep_stage")"
  rate="$(jq -r '.rate_mbit // 0' <<<"$sweep_stage")"
  stage_dir="${sweep_fixture}/stages/$(printf '%02d-%s' "$sequence" "$label")"
  benchmark_dir="${stage_dir}/benchmark"
  mkdir -p "$benchmark_dir"
  case "$phase:$rate" in
    reference-start:* | reference-end:*) receiver=198; sender=199; retrans_per_gib=100; retrans=10; overlimits=1000 ;;
    candidate-sweep:150) receiver=149; sender=150; retrans_per_gib=10; retrans=1; overlimits=1000 ;;
    candidate-sweep:180) receiver=178; sender=180; retrans_per_gib=20; retrans=2; overlimits=1000 ;;
    candidate-sweep:190) receiver=188; sender=190; retrans_per_gib=40; retrans=4; overlimits=1000 ;;
    *) printf 'unexpected sweep fixture stage: %s\n' "$label" >&2; exit 1 ;;
  esac
  jq -n --argjson sender "$sender" --argjson receiver "$receiver" \
    --argjson retrans "$retrans" --argjson retrans_per_gib "$retrans_per_gib" \
    --argjson overlimits "$overlimits" '
      {schema_version:3,direction:"upload",reverse:false,
       measurement_window:{status:"VALID",valid:true,expected_seconds:10,issues:[]},
       sender:{bytes:1073741824,seconds:10,bits_per_second:($sender*1000000),mbps:$sender,
          retransmits:$retrans,retransmits_per_gib:$retrans_per_gib},
       receiver:{bytes:1073741824,seconds:10,bits_per_second:($receiver*1000000),mbps:$receiver},
       host:{tx_bytes_delta:1073741824,tcp_delta:{TcpRetransSegs:$retrans},
         link_delta:{"eth0.tx_dropped":0,"eth0.rx_dropped":0,
           "eth0.tx_errors":0,"eth0.rx_errors":0}},
       qdisc_coverage:{aggregation_source:"root",topology:"htb-fq",has_root:true,
         has_leaf:true,root_is_mq:false,root_is_htb:true,
         htb_root_interfaces:["eth0"],fq_leaf_interfaces:["eth0"],
         htb_fq_leaf_complete:true},
       qdisc_root_totals:{dropped_delta:0,overlimits_delta:$overlimits,requeues_delta:0},
       qdisc_leaf_totals:{dropped_delta:0,overlimits_delta:0,requeues_delta:0},
       qdisc_active_totals:{dropped_delta:0,overlimits_delta:$overlimits,requeues_delta:0},
       qdisc_health:{status:"NO_LOCAL_QUEUE_DROP_OR_REQUEUE",any_drop_or_requeue:false,
         root:{dropped_delta:0,requeues_delta:0},leaf:{dropped_delta:0,requeues_delta:0}}}
    ' >"${benchmark_dir}/upload.summary.json"
  printf '%s\n' '{"schema_version":1,"status":"PASS","exit_code":0,"phases":{"upload":{},"download":null}}' \
    >"${benchmark_dir}/benchmark-result.json"
  jq -n --arg tuning_sha "$fixture_tuning_sha" '
    {schema_version:1,script_version:"0.2.0-rc.1",profile:"debian13-1c1g",
     script_sha256:$tuning_sha,state:"VERIFIED",state_network:{port_speed_mbps:200}}' \
    >"${benchmark_dir}/benchmark-meta.json"
  printf 'user\t100\nnice\t0\nsystem\t50\nidle\t100\niowait\t0\nirq\t0\nsoftirq\t10\nsteal\t0\n' \
    >"${benchmark_dir}/upload.cpu.before"
  printf 'user\t140\nnice\t0\nsystem\t70\nidle\t130\niowait\t0\nirq\t0\nsoftirq\t20\nsteal\t0\n' \
    >"${benchmark_dir}/upload.cpu.after"
  printf '0\t100\t0\t0\n' >"${benchmark_dir}/upload.softnet.before"
  printf '0\t200\t0\t0\n' >"${benchmark_dir}/upload.softnet.after"
  (
    cd "$benchmark_dir"
    sha256sum upload.summary.json benchmark-result.json benchmark-meta.json \
      upload.cpu.before upload.cpu.after upload.softnet.before upload.softnet.after >SHA256SUMS
  )
  benchmark_result_sha="$(sha256sum "${benchmark_dir}/benchmark-result.json" | awk '{print $1}')"
  benchmark_manifest_sha="$(sha256sum "${benchmark_dir}/SHA256SUMS" | awk '{print $1}')"
  printf 'status=COMPLETED\nevidence_manifest_sha256=%s\nresult_sha256=%s\n' \
    "$benchmark_manifest_sha" "$benchmark_result_sha" >"${benchmark_dir}/COMPLETED"
  jq -n --arg sha "$benchmark_result_sha" --argjson plan_stage "$sweep_stage" \
    --arg tuning_sha "$fixture_tuning_sha" --arg state_sha "$fixture_state_sha" '
    {schema_version:3,status:"PASS",plan_stage:$plan_stage,
      benchmark_result_sha256:$sha,qdisc_rate_mbit:$plan_stage.rate_mbit,
      managed_binding:{profile_id:"debian13-1c1g",script_version:"0.2.0-rc.1",
        state:"VERIFIED",port_speed_mbps:200,state_sha256:$state_sha,
        tuning_script_sha256:$tuning_sha},benchmark_binding_valid:true,
      traffic_cap_enforced_by_htb:true,qdisc_restored_to_root_fq:true,
      persistent_shaping_created:false}' \
    >"${stage_dir}/stage-result.json"
done < <(jq -c '.stages[]' "$runner_plan")

run_rate_sweep_analyzer_fixture() (
  local inherited_path="$PATH"
  # shellcheck disable=SC1090
  source "$rate_sweep_analyzer"
  PATH="$inherited_path"
  main "$@"
)

refresh_benchmark_completion() {
  local benchmark_dir="$1" result_sha manifest_sha
  (
    cd "$benchmark_dir"
    sha256sum upload.summary.json benchmark-result.json benchmark-meta.json \
      upload.cpu.before upload.cpu.after upload.softnet.before upload.softnet.after >SHA256SUMS
  )
  result_sha="$(sha256sum "${benchmark_dir}/benchmark-result.json" | awk '{print $1}')"
  manifest_sha="$(sha256sum "${benchmark_dir}/SHA256SUMS" | awk '{print $1}')"
  printf 'status=COMPLETED\nevidence_manifest_sha256=%s\nresult_sha256=%s\n' \
    "$manifest_sha" "$result_sha" >"${benchmark_dir}/COMPLETED"
}

candidate_summary_for_rate() {
  local target_rate="$1" stage_result
  for stage_result in "${sweep_fixture}"/stages/*/stage-result.json; do
    if jq -e --argjson rate "$target_rate" '
      .plan_stage.condition == "candidate-htb" and .plan_stage.rate_mbit == $rate
    ' "$stage_result" >/dev/null; then
      printf '%s\n' "$(dirname "$stage_result")/benchmark/upload.summary.json"
      return 0
    fi
  done
  return 1
}

sweep_analysis="$(run_rate_sweep_analyzer_fixture "$sweep_fixture")"
jq -e '
  .schema_version == 3 and .status == "REVIEW_REQUIRED" and
  .plan_mode == "candidate-sweep" and
  .measurement_gate.valid == true and
  .evidence_contract_gate.valid == true and
  .shaping_exposure_gate.valid == true and
  .qdisc_health_gate.valid == true and
  .resource_gate.valid == true and
  .persistence_authorized == false and
  .source_reference_gate.external_reference_required == true and
  .source_reference_gate.review_acknowledged == true and
  .source_reference_gate.evidence_manifest_sha256 ==
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  .source_reference_gate.analysis_sha256 ==
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
  .source_reference_gate.completed_marker_sha256 ==
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" and
  .metric_contract.packet_loss_percentage_inferred == false and
  .metric_contract.fixed_mss_assumed == false and
  .metric_contract.fixed_global_retransmission_threshold_used == false and
  .reference.comparable_by_sender_median_mad_overlap == true and
  .review_shortlist.rate_mbit == 190 and
  .review_shortlist.eligible_rates_mbit == [190] and
  (.rates | length) == 3 and
  (.rates[] | select(.rate_mbit == 190) |
     .review_flags.retransmission_below_reference_dispersion == true and
     .review_flags.sender_goodput_within_observed_best_dispersion == true and
     .review_flags.all_evidence_contracts_valid == true and
     .review_flags.all_receiver_measurement_windows_valid == true and
     .review_flags.all_local_qdisc_health_samples_valid == true and
     .review_flags.all_htb_overlimit_samples_positive == true and
     .review_flags.all_sender_rate_exposure_samples_valid == true and
     .review_flags.all_resource_samples_valid == true)
' <<<"$sweep_analysis" >/dev/null

# 候选 sender 更高但 receiver 更低时，仅增加复核提示，不改 shortlist。
jq -e 'all(.rates[]; .receiver_divergence_review.status == "NO_DIVERGENCE_OBSERVED")' \
  <<<"$sweep_analysis" >/dev/null
while IFS= read -r summary_path; do
  if jq -e '.sender.mbps == 190' "$summary_path" >/dev/null; then
    cp "$summary_path" "${summary_path}.receiver-valid"
    jq '.receiver.mbps=120 | .receiver.bits_per_second=120000000 | .receiver.bytes=150000000' \
      "${summary_path}.receiver-valid" >"$summary_path"
    refresh_benchmark_completion "$(dirname "$summary_path")"
  fi
done < <(printf '%s\n' "${sweep_fixture}"/stages/*/benchmark/upload.summary.json)
divergent_analysis="$(run_rate_sweep_analyzer_fixture "$sweep_fixture")"
jq -e '.review_shortlist.rate_mbit == 190 and
  (.rates[] | select(.rate_mbit==190) | .receiver_divergence_review |
    .status=="REVIEW_REQUIRED" and .compared_rates_mbit==[150,180] and .changes_shortlist==false)' \
  <<<"$divergent_analysis" >/dev/null
for saved_summary in "${sweep_fixture}"/stages/*/benchmark/upload.summary.json.receiver-valid; do
  mv "$saved_summary" "${saved_summary%.receiver-valid}"
  refresh_benchmark_completion "$(dirname "$saved_summary")"
done

invalid_summary="$(printf '%s\n' "${sweep_fixture}"/stages/*/benchmark/upload.summary.json | head -n 1)"
cp "$invalid_summary" "${invalid_summary}.valid"
jq '.measurement_window = {
  status:"INVALID_MEASUREMENT_WINDOW",valid:false,expected_seconds:10,
  issues:["receiver-duration-mismatch","sender-receiver-window-mismatch"]
} | .receiver.seconds = 11.14133 | .receiver.mbps = 184.561227' \
  "${invalid_summary}.valid" >"$invalid_summary"
invalid_benchmark_dir="$(dirname "$invalid_summary")"
refresh_benchmark_completion "$invalid_benchmark_dir"
blocked_analysis="$(run_rate_sweep_analyzer_fixture "$sweep_fixture")"
jq -e '
  .status == "REVIEW_BLOCKED" and
  .measurement_gate.valid == false and
  .measurement_gate.invalid_sample_count == 1 and
  all(.rates[]; .receiver_divergence_review.status == "NOT_EVALUATED") and
  .review_shortlist.rate_mbit == null and
  .review_shortlist.eligible_rates_mbit == [] and
  (.measurement_gate.invalid_samples[0].issues | index("receiver-duration-mismatch") != null)
' <<<"$blocked_analysis" >/dev/null
mv "${invalid_summary}.valid" "$invalid_summary"
refresh_benchmark_completion "$invalid_benchmark_dir"

exposure_summary="$(candidate_summary_for_rate 190)"
exposure_benchmark_dir="$(dirname "$exposure_summary")"
cp "$exposure_summary" "${exposure_summary}.valid"
jq '.qdisc_root_totals.overlimits_delta = 0 | .qdisc_active_totals.overlimits_delta = 0' \
  "${exposure_summary}.valid" >"$exposure_summary"
refresh_benchmark_completion "$exposure_benchmark_dir"
blocked_analysis="$(run_rate_sweep_analyzer_fixture "$sweep_fixture")"
jq -e '
  .status == "REVIEW_BLOCKED" and
  .measurement_gate.valid == true and
  .shaping_exposure_gate.valid == false and
  .shaping_exposure_gate.invalid_sample_count == 1 and
  .resource_gate.valid == true and
  .review_shortlist.rate_mbit == null and
  .review_shortlist.eligible_rates_mbit == [] and
  (.shaping_exposure_gate.invalid_samples[0] |
    .rate_mbit == 190 and .qdisc_root_overlimits_delta == 0)
' <<<"$blocked_analysis" >/dev/null
mv "${exposure_summary}.valid" "$exposure_summary"
refresh_benchmark_completion "$exposure_benchmark_dir"

cp "$exposure_summary" "${exposure_summary}.valid"
jq '.sender.mbps = 100 | .sender.bits_per_second = 100000000' \
  "${exposure_summary}.valid" >"$exposure_summary"
refresh_benchmark_completion "$exposure_benchmark_dir"
blocked_analysis="$(run_rate_sweep_analyzer_fixture "$sweep_fixture")"
jq -e '
  .status == "REVIEW_BLOCKED" and
  .shaping_exposure_gate.valid == false and
  .shaping_exposure_gate.minimum_sender_rate_exposure_ratio == 0.9 and
  .shaping_exposure_gate.invalid_sample_count == 1 and
  .review_shortlist.rate_mbit == null and
  .review_shortlist.eligible_rates_mbit == [] and
  (.shaping_exposure_gate.invalid_samples[0] |
    .rate_mbit == 190 and .qdisc_root_overlimits_delta > 0 and
    .sender_rate_exposure_ratio < 0.9)
' <<<"$blocked_analysis" >/dev/null
mv "${exposure_summary}.valid" "$exposure_summary"
refresh_benchmark_completion "$exposure_benchmark_dir"

cp "$exposure_summary" "${exposure_summary}.valid"
jq '.qdisc_leaf_totals.dropped_delta = 1 |
    .qdisc_health.leaf.dropped_delta = 1 |
    .qdisc_health.any_drop_or_requeue = true |
    .qdisc_health.status = "LOCAL_QUEUE_ANOMALY"' \
  "${exposure_summary}.valid" >"$exposure_summary"
refresh_benchmark_completion "$exposure_benchmark_dir"
blocked_analysis="$(run_rate_sweep_analyzer_fixture "$sweep_fixture")"
jq -e '
  .status == "REVIEW_BLOCKED" and
  .evidence_contract_gate.valid == true and
  .qdisc_health_gate.valid == false and
  .qdisc_health_gate.invalid_sample_count == 1 and
  .review_shortlist.eligible_rates_mbit == [] and
  (.qdisc_health_gate.invalid_samples[0] |
    .rate_mbit == 190 and .qdisc_leaf_dropped_delta == 1 and
    .qdisc_health_status == "LOCAL_QUEUE_ANOMALY")
' <<<"$blocked_analysis" >/dev/null
mv "${exposure_summary}.valid" "$exposure_summary"
refresh_benchmark_completion "$exposure_benchmark_dir"

cp "$exposure_summary" "${exposure_summary}.valid"
jq '.qdisc_root_totals.requeues_delta = 1 |
    .qdisc_health.root.requeues_delta = 1 |
    .qdisc_health.any_drop_or_requeue = true |
    .qdisc_health.status = "LOCAL_QUEUE_ANOMALY"' \
  "${exposure_summary}.valid" >"$exposure_summary"
refresh_benchmark_completion "$exposure_benchmark_dir"
blocked_analysis="$(run_rate_sweep_analyzer_fixture "$sweep_fixture")"
jq -e '
  .status == "REVIEW_BLOCKED" and
  .evidence_contract_gate.valid == true and
  .qdisc_health_gate.valid == false and
  .qdisc_health_gate.invalid_sample_count == 1 and
  .review_shortlist.eligible_rates_mbit == [] and
  (.qdisc_health_gate.invalid_samples[0] |
    .rate_mbit == 190 and .qdisc_root_requeues_delta == 1 and
    .qdisc_health_status == "LOCAL_QUEUE_ANOMALY")
' <<<"$blocked_analysis" >/dev/null
mv "${exposure_summary}.valid" "$exposure_summary"
refresh_benchmark_completion "$exposure_benchmark_dir"

cp "$exposure_summary" "${exposure_summary}.valid"
jq '.schema_version = 2 |
    del(.qdisc_health, .qdisc_root_totals, .qdisc_leaf_totals)' \
  "${exposure_summary}.valid" >"$exposure_summary"
refresh_benchmark_completion "$exposure_benchmark_dir"
blocked_analysis="$(run_rate_sweep_analyzer_fixture "$sweep_fixture")"
jq -e '
  .status == "REVIEW_BLOCKED" and
  .evidence_contract_gate.valid == false and
  .evidence_contract_gate.required_upload_summary_schema == 3 and
  .evidence_contract_gate.invalid_sample_count == 1 and
  .review_shortlist.rate_mbit == null and
  .review_shortlist.eligible_rates_mbit == []
' <<<"$blocked_analysis" >/dev/null
mv "${exposure_summary}.valid" "$exposure_summary"
refresh_benchmark_completion "$exposure_benchmark_dir"

resource_cpu_after="${exposure_benchmark_dir}/upload.cpu.after"
cp "$resource_cpu_after" "${resource_cpu_after}.valid"
printf 'user\t140\nnice\t0\nsystem\t70\nidle\t130\niowait\t0\nirq\t0\nsoftirq\t20\nsteal\t20\n' \
  >"$resource_cpu_after"
refresh_benchmark_completion "$exposure_benchmark_dir"
blocked_analysis="$(run_rate_sweep_analyzer_fixture "$sweep_fixture")"
jq -e '
  .status == "REVIEW_BLOCKED" and
  .measurement_gate.valid == true and
  .shaping_exposure_gate.valid == true and
  .resource_gate.valid == false and
  .resource_gate.invalid_sample_count == 1 and
  .review_shortlist.rate_mbit == null and
  .review_shortlist.eligible_rates_mbit == [] and
  (.resource_gate.invalid_samples[0] |
    .rate_mbit == 190 and .cpu.steal_percent > 5)
' <<<"$blocked_analysis" >/dev/null
mv "${resource_cpu_after}.valid" "$resource_cpu_after"
refresh_benchmark_completion "$exposure_benchmark_dir"

cp "$resource_cpu_after" "${resource_cpu_after}.valid"
printf 'user\t140\nnice\t0\nsystem\t70\nidle\t130\niowait\t0\nirq\t0\nsoftirq\t20\nidle\t131\n' \
  >"$resource_cpu_after"
refresh_benchmark_completion "$exposure_benchmark_dir"
if malformed_cpu_output="$(run_rate_sweep_analyzer_fixture "$sweep_fixture" 2>&1)"; then
  printf 'rate sweep analyzer accepted duplicate/missing CPU counter keys\n' >&2
  exit 1
fi
grep -Fq '无法解析 CPU 增量' <<<"$malformed_cpu_output"
mv "${resource_cpu_after}.valid" "$resource_cpu_after"
refresh_benchmark_completion "$exposure_benchmark_dir"

resource_softnet_after="${exposure_benchmark_dir}/upload.softnet.after"
cp "$resource_softnet_after" "${resource_softnet_after}.valid"
printf '0\t200\tnot-a-number\t0\n' >"$resource_softnet_after"
refresh_benchmark_completion "$exposure_benchmark_dir"
if malformed_softnet_output="$(run_rate_sweep_analyzer_fixture "$sweep_fixture" 2>&1)"; then
  printf 'rate sweep analyzer accepted a non-numeric softnet counter\n' >&2
  exit 1
fi
grep -Fq '无法解析 softnet 增量' <<<"$malformed_softnet_output"
mv "${resource_softnet_after}.valid" "$resource_softnet_after"
refresh_benchmark_completion "$exposure_benchmark_dir"

profile_meta="${exposure_benchmark_dir}/benchmark-meta.json"
cp "$profile_meta" "${profile_meta}.valid"
jq '.profile = "debian13-1c2g"' "${profile_meta}.valid" >"$profile_meta"
refresh_benchmark_completion "$exposure_benchmark_dir"
if profile_mismatch_output="$(run_rate_sweep_analyzer_fixture "$sweep_fixture" 2>&1)"; then
  printf 'rate sweep analyzer accepted a mismatched benchmark profile\n' >&2
  exit 1
fi
grep -Fq 'benchmark-meta profile/state 绑定无效' <<<"$profile_mismatch_output"
mv "${profile_meta}.valid" "$profile_meta"
refresh_benchmark_completion "$exposure_benchmark_dir"

missing_completed="$(printf '%s\n' "${sweep_fixture}"/stages/*/benchmark/COMPLETED | head -n 1)"
mv "$missing_completed" "${missing_completed}.fixture-missing"
if run_rate_sweep_analyzer_fixture "$sweep_fixture" >/dev/null 2>&1; then
  printf 'rate sweep analyzer accepted a benchmark without COMPLETED\n' >&2
  exit 1
fi
mv "${missing_completed}.fixture-missing" "$missing_completed"

cp "${sweep_fixture}/plan.json" "${sweep_fixture}/plan.json.valid"
jq '(.stages[] | select(.condition == "candidate-htb") | .phase) = "reference-start"' \
  "${sweep_fixture}/plan.json.valid" >"${sweep_fixture}/plan.json"
if invalid_plan_output="$(run_rate_sweep_analyzer_fixture "$sweep_fixture" 2>&1)"; then
  printf 'rate sweep analyzer accepted candidate stages with an invalid phase\n' >&2
  exit 1
fi
grep -Fq 'plan.json 不符合 HTB reference/candidate schema' <<<"$invalid_plan_output"
mv "${sweep_fixture}/plan.json.valid" "${sweep_fixture}/plan.json"

if [ "${RUN_LOCAL_SHELLCHECK:-0}" = 1 ]; then
  command -v shellcheck >/dev/null 2>&1 || {
    printf 'RUN_LOCAL_SHELLCHECK=1 but shellcheck was not found\n' >&2
    exit 1
  }
  shellcheck -x "$script" "$plan_script" "$rate_sweep_plan_script" \
    "$rate_sweep_runner" "$rate_sweep_analyzer" "$0"
fi

printf 'HTB aggregate experiment static checks passed\n'
