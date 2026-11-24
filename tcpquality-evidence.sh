#!/usr/bin/env bash

# Explicit TcpQuality evidence harness. This wrapper contains no host tuning,
# package-manager or service mutations and never overwrites an evidence set.
# The pinned upstream --all workload performs network I/O and temporarily
# creates/removes iptables/ip6tables counter chains; this requires an explicit
# acknowledgement below because chroot does not isolate the network namespace.

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 077

TOOL_VERSION='0.2.0-rc.1'
SUPPORTED_RELEASE_TAG='v1.00013'
SUPPORTED_COMMIT='73606e2460bde21bb2e253842971f8ca8c9eb51c'
SUPPORTED_RUN_SHA256='3e9e08792b441d9d74aeb64630a657f6904821dd2a911a379fcea538ebdbd5c2'
SUPPORTED_ROOTFS_RUNNER_SHA256='af62690d2631658dcd279cd15c7356c1c091a39309e3666e3c32c211331ed3ba'
SUPPORTED_CORE_SHA256='78f3a5247717a0b856737da5c5a9fdc87ee39a93423906e5eaa47948bb79d628'
SUPPORTED_ROOTFS_MANIFEST_SHA256='555a53df40cbdd2778771c089d1bc2c2e1c0a52b5565ad15d2e01d52b90dd0f6'
SUPPORTED_ROOTFS_SHA256='c624b5cc611b7177c42608110024764e59dfd0a88150257137ae4e6d7f9f9d18'
SUPPORTED_ROOTFS_SIZE='140748758'
SUPPORTED_TCP_INFO_HELPER_SHA256='159d31efc9dbfda7b5f552455d160ebde295c937dcc3f8b24d21fb5934cd8253'
SUPPORTED_TCP_INFO_HELPER_SIZE='14152'
SUPPORTED_RETRANS_SEQ_SHA256='4ab10e0993becb37c5bff64e1f0ae4860959ff2ad16b372578701ffcf5c36aab'
SUPPORTED_RETRANS_SEQ_SIZE='1865'
SUPPORTED_RETRANS_SKB_SHA256='b84d979a000b86515c3eb8b776d3e2b276031e418a659aa828eb7afbdab4bd89'
SUPPORTED_RETRANS_SKB_SIZE='819'
GET_NODES_URL="${TCPQUALITY_GET_NODES_URL:-https://tcpquality.ibsgss.uk/getNodes}"
PIN_DIR="${TCPQUALITY_PIN_DIR:-}"
EVIDENCE_DIR="${TCPQUALITY_EVIDENCE_DIR:-}"
COMMIT="${TCPQUALITY_COMMIT:-}"
ROOTFS_SHA256="${TCPQUALITY_ROOTFS_SHA256:-}"
MODE="${TCPQUALITY_MODE:-}"
ACK_TRANSIENT_FIREWALL="${TCPQUALITY_ACK_TRANSIENT_FIREWALL:-0}"
RUNS="${TCPQUALITY_RUNS:-3}"
DELAY_SECONDS="${TCPQUALITY_DELAY_SECONDS:-60}"
COUNT="${TCPQUALITY_COUNT:-30}"
PACKET_SIZE="${TCPQUALITY_PACKET_SIZE:-0}"
PARALLEL="${TCPQUALITY_PARALLEL:-16}"
DVT_TRAFFIC_BUDGET_TOOL="${DVT_TRAFFIC_BUDGET_TOOL:-}"
DVT_TRAFFIC_LEDGER="${DVT_TRAFFIC_LEDGER:-}"
DVT_TRAFFIC_WINDOW_ID="${DVT_TRAFFIC_WINDOW_ID:-}"
DVT_TRAFFIC_BUDGET_BYTES="${DVT_TRAFFIC_BUDGET_BYTES:-}"
TCPQUALITY_PLANNED_PAYLOAD_BYTES="${TCPQUALITY_PLANNED_PAYLOAD_BYTES:-}"
TRAFFIC_RESERVATION_ID=''
TRAFFIC_RESERVED=0

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少必要命令：$1"
}

validate_integer() {
  local name="$1" value="$2" minimum="$3" maximum="$4"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "${name} 必须是整数。"
  value=$((10#$value))
  [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ] ||
    fail "${name} 必须在 ${minimum}–${maximum} 之间。"
}

write_incomplete_marker() {
  local signal="$1"
  if [ "$TRAFFIC_RESERVED" -eq 1 ]; then
    bash "$DVT_TRAFFIC_BUDGET_TOOL" fail --ledger "$DVT_TRAFFIC_LEDGER" \
      --reservation-id "$TRAFFIC_RESERVATION_ID" >/dev/null 2>&1 || true
    TRAFFIC_RESERVED=0
  fi
  if [ -n "$EVIDENCE_DIR" ] && [ -d "$EVIDENCE_DIR" ]; then
    printf 'status=INCOMPLETE\nsignal=%s\nutc=%s\n' \
      "$signal" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${EVIDENCE_DIR}/INCOMPLETE"
  fi
}

snapshot_nodes() {
  local scope="$1" output="$2"
  local tmp="${output}.tmp"
  curl -4 --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 5 --max-time 30 \
    "${GET_NODES_URL}?format=tsv&scope=${scope}" >"$tmp" || { rm -f -- "$tmp"; return 1; }
  awk -F '\t' -v expected_scope="$scope" '
    NR == 1 {
      expected="type\tfamily\tprovince\tisp\thost\tip\tport\ttarget\tbackup_host\tbackup_ip\tbackup_port\tbackup_target"
      if ($0 != expected || NF != 12) exit 50
      next
    }
    {
      if (NF != 12 || $1 == "" || $2 !~ /^[46]$/ || $5 == "" || $6 == "" || $7 !~ /^[0-9]+$/) exit 51
      if (expected_scope == "tos" && $1 != "tos") exit 52
      rows++
    }
    END {if (rows == 0) exit 53}
  ' "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$output" || { rm -f -- "$tmp"; return 1; }
}

record_node_snapshot() {
  local run="$1" scope="$2" phase="$3" file="$4" hash
  hash="$(sha256sum "$file" | awk '{print $1}')" || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$run" "$scope" "$phase" "${file##*/}" "$hash" \
    >>"${EVIDENCE_DIR}/node-inventory.tsv" || return 1
}

logical_node_keys() {
  local source="$1"
  awk -F '\t' '
    NR == 1 {
      for (i=1; i<=NF; i++) keep[i]=($i != "ip" && $i != "backup_ip")
      next
    }
    {
      key=""
      for (i=1; i<=NF; i++) if (keep[i]) key=key (key == "" ? "" : "\t") $i
      print key
    }
  ' "$source" | LC_ALL=C sort -u
}

node_ip_change_count() {
  local before="$1" after="$2"
  awk -F '\t' '
    NR == FNR {
      if (FNR == 1) {
        for (i=1; i<=NF; i++) {
          keep_before[i]=($i != "ip" && $i != "backup_ip")
          if ($i == "ip") ip_before=i
          if ($i == "backup_ip") backup_before=i
        }
        next
      }
      key=""
      for (i=1; i<=NF; i++) if (keep_before[i]) key=key (key == "" ? "" : "\t") $i
      address_before[key]=$(ip_before) "|" $(backup_before)
      next
    }
    FNR == 1 {
      for (i=1; i<=NF; i++) {
        keep_after[i]=($i != "ip" && $i != "backup_ip")
        if ($i == "ip") ip_after=i
        if ($i == "backup_ip") backup_after=i
      }
      next
    }
    {
      key=""
      for (i=1; i<=NF; i++) if (keep_after[i]) key=key (key == "" ? "" : "\t") $i
      if (key in address_before && address_before[key] != $(ip_after) "|" $(backup_after)) changed++
    }
    END {print changed+0}
  ' "$before" "$after"
}

record_node_drift() {
  local run="$1" scope="$2" before="$3" after="$4"
  local before_keys="${EVIDENCE_DIR}/.nodes-${scope}-r${run}-before.keys"
  local after_keys="${EVIDENCE_DIR}/.nodes-${scope}-r${run}-after.keys"
  local removed added ip_changed exact_equal=0
  logical_node_keys "$before" >"$before_keys" || return 1
  logical_node_keys "$after" >"$after_keys" || return 1
  removed="$(comm -23 "$before_keys" "$after_keys" | wc -l)" || return 1
  added="$(comm -13 "$before_keys" "$after_keys" | wc -l)" || return 1
  ip_changed="$(node_ip_change_count "$before" "$after")" || return 1
  cmp -s "$before" "$after" && exact_equal=1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run" "$scope" "$(( $(wc -l <"$before") - 1 ))" "$(( $(wc -l <"$after") - 1 ))" \
    "$removed" "$added" "$ip_changed" "$exact_equal" >>"${EVIDENCE_DIR}/node-drift.tsv" || return 1
  rm -f -- "$before_keys" "$after_keys" || return 1
}

capture_host_state() {
  local phase="$1"
  printf '== %s host state ==\n' "$phase"
  printf 'utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'boot_id=%s\n' "$(awk 'NR == 1 {print; exit}' /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  uname -a || return 1
  uptime || return 1
  free -h || return 1
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
    net.ipv4.tcp_window_scaling net.ipv4.tcp_moderate_rcvbuf \
    net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_limit_output_bytes net.ipv4.tcp_notsent_lowat || return 1
  printf '\n== default routes and reference egress ==\n'
  ip -4 route show default 2>/dev/null || true
  ip -6 route show default 2>/dev/null || true
  ip -4 route get 1.1.1.1 2>/dev/null || true
  ip -6 route get 2606:4700:4700::1111 2>/dev/null || true
  printf '\n== aggregate CPU counters ==\n'
  awk '$1 == "cpu" {print; exit}' /proc/stat || return 1
  printf '\n== per-CPU softnet counters ==\n'
  awk '{print}' /proc/net/softnet_stat || return 1
  printf '\n== socket summary ==\n'
  ss -s || return 1
  ip -s -s link show || return 1
  tc -s -d qdisc show || return 1
  nstat -az || return 1
  swapon --show --bytes || return 1
}

find_csv_inventory() {
  find "$EVIDENCE_DIR" -maxdepth 1 -type f -name 'zstatic_nping_*.csv' -printf '%f\n' | LC_ALL=C sort
}

find_debug_inventory() {
  find "$EVIDENCE_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' | LC_ALL=C sort
}

meta_value() {
  local key="$1"
  awk -F= -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "")
      gsub(/[\t\r\n]/, " ")
      print
      exit
    }
  '
}

is_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_integer() {
  is_nonnegative_integer "$1" && [ "$((10#$1))" -gt 0 ]
}

is_percentage() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?%$ ]]
}

record_retransmission_evidence() {
  local run="$1" archive="$2" entries entry content
  local probe_type server_ip result metric_source tcp_info_retrans tcp_info_data_segs_out
  local tcp_info_segs_out tcp_info_bytes_retrans ebpf_unique ratio_denominator ratio
  local fallback_reason trace_available trace_valid measurement_status loop_status=0
  entries="${EVIDENCE_DIR}/.retrans-meta-r${run}.list"
  if ! tar -tzf "$archive" | awk '/\/speedtest\.[^/]+\/result\.(download|upload)\.meta$/ {print}' >"$entries"; then
    rm -f -- "$entries"
    return 1
  fi
  [ -s "$entries" ] || { rm -f -- "$entries"; return 1; }
  while IFS= read -r entry; do
    case "/$entry/" in
      */../* | /*//* ) loop_status=1; break ;;
    esac
    if ! content="$(tar -xOzf "$archive" "$entry")"; then
      loop_status=1
      break
    fi
    probe_type="$(meta_value probe_type <<<"$content")"
    server_ip="$(meta_value server_ip <<<"$content")"
    result="$(meta_value result <<<"$content")"
    metric_source="$(meta_value retrans_source <<<"$content")"
    tcp_info_retrans="$(meta_value tcp_info_retrans <<<"$content")"
    tcp_info_data_segs_out="$(meta_value tcp_info_data_segs_out <<<"$content")"
    tcp_info_segs_out="$(meta_value tcp_info_segs_out <<<"$content")"
    tcp_info_bytes_retrans="$(meta_value tcp_info_bytes_retrans <<<"$content")"
    trace_available="$(meta_value retrans_trace_available <<<"$content")"
    trace_valid="$(meta_value retrans_trace_valid <<<"$content")"
    ebpf_unique="$(meta_value retrans_trace_unique <<<"$content")"
    case "$metric_source" in
      ebpf_seq | ebpf_skb)
        ratio_denominator="$(meta_value retrans_trace_ratio_denominator <<<"$content")"
        ratio="$(meta_value retrans_trace_ratio <<<"$content")"
        if ! is_nonnegative_integer "$ebpf_unique" ||
          ! is_positive_integer "$ratio_denominator" || ! is_percentage "$ratio"; then
          printf '[tcpquality-evidence][FAIL] eBPF 重传元数据字段无效：%s\n' "$entry" >&2
          loop_status=1
          break
        fi
        fallback_reason='none'
        measurement_status='FLOW_LEVEL'
        ;;
      tcp_info_getsockopt | tcp_info_ss)
        ratio_denominator="$(meta_value tcp_info_ratio_denominator <<<"$content")"
        ratio="$(meta_value tcp_info_ratio <<<"$content")"
        if ! is_nonnegative_integer "$tcp_info_retrans" ||
          ! is_positive_integer "$ratio_denominator" || ! is_percentage "$ratio"; then
          printf '[tcpquality-evidence][FAIL] TCP_INFO 重传元数据字段无效：%s\n' "$entry" >&2
          loop_status=1
          break
        fi
        if [ "$trace_available" != '1' ]; then
          fallback_reason='ebpf_unavailable'
        elif [ "$trace_valid" != '1' ]; then
          fallback_reason='ebpf_trace_invalid'
        else
          fallback_reason='ebpf_not_selected'
        fi
        measurement_status='FLOW_LEVEL'
        ;;
      nstat)
        ratio_denominator='-'
        ratio='-'
        fallback_reason='tcp_info_unavailable'
        measurement_status='MEASUREMENT_DEGRADED'
        ;;
      *)
        ratio_denominator='-'
        ratio='-'
        fallback_reason='unknown_metric_source'
        measurement_status='MEASUREMENT_DEGRADED'
        ;;
    esac
    [ "$result" != 'failed' ] || measurement_status='PROBE_FAILED'
    if ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$run" "${archive##*/}" "$entry" "${probe_type:--}" "${server_ip:--}" "${result:--}" \
      "${metric_source:--}" "${tcp_info_retrans:--}" "${tcp_info_data_segs_out:--}" \
      "${tcp_info_segs_out:--}" "${tcp_info_bytes_retrans:--}" "${ebpf_unique:--}" \
      "$ratio_denominator" "$ratio" "$fallback_reason" "$measurement_status" \
      >>"${EVIDENCE_DIR}/retransmission-evidence.tsv"; then
      loop_status=1
      break
    fi
  done <"$entries"
  rm -f -- "$entries"
  [ "$loop_status" -eq 0 ]
}

run_one() {
  local run="$1" log debug_archive debug_hash
  local -a upstream_args
  log="${EVIDENCE_DIR}/tcpquality-r${run}.log"
  local all_before="${EVIDENCE_DIR}/nodes-all-r${run}-before.tsv"
  local tos_before="${EVIDENCE_DIR}/nodes-tos-r${run}-before.tsv"
  local all_after="${EVIDENCE_DIR}/nodes-all-r${run}-after.tsv"
  local tos_after="${EVIDENCE_DIR}/nodes-tos-r${run}-after.tsv"
  local csv_before="${EVIDENCE_DIR}/.csv-r${run}-before" csv_after="${EVIDENCE_DIR}/.csv-r${run}-after"
  local debug_before="${EVIDENCE_DIR}/.debug-r${run}-before" debug_after="${EVIDENCE_DIR}/.debug-r${run}-after"
  local new_csv csv_hash rc=0

  find_csv_inventory >"$csv_before" || return 1
  find_debug_inventory >"$debug_before" || return 1
  upstream_args=(-c "$COUNT" -s "$PACKET_SIZE" -p "$PARALLEL" --all --debug)
  [ "$MODE" != 'local-evidence' ] || upstream_args+=(--no-rank-upload)
  {
    printf 'tool_version=%s\nrun=%s\nutc_start=%s\n' "$TOOL_VERSION" "$run" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'tcpquality_commit=%s\nmode=%s\n' "$COMMIT" "$MODE"
    printf 'args='
    printf '%q ' "${upstream_args[@]}"
    printf '\n'
    printf '\n== pinned assets ==\n'
    (cd "$PIN_DIR" && sha256sum -c SHA256SUMS) || return 1
    printf '\n== node snapshots before ==\n'
    snapshot_nodes all "$all_before" || return 1
    snapshot_nodes tos "$tos_before" || return 1
    sha256sum "$all_before" "$tos_before" || return 1
    record_node_snapshot "$run" all before "$all_before" || return 1
    record_node_snapshot "$run" tos before "$tos_before" || return 1
    printf '\n'
    capture_host_state pre-run || return 1
    printf '\n== TcpQuality output ==\n'
    set +e
    env TERM=xterm \
      TCPQUALITY_RAW_BASE="https://raw.githubusercontent.com/ibsgss/TcpQuality/${COMMIT}" \
      TCPQUALITY_ROOTFS_URL="file://${PIN_DIR}/tcpquality-rootfs-amd64.tar.gz" \
      TCPQUALITY_ROOTFS_SHA256="$ROOTFS_SHA256" \
      TCPQUALITY_OUTPUT_DIR="$EVIDENCE_DIR" \
      GET_NODES_URL="$GET_NODES_URL" \
      bash "${PIN_DIR}/runTcpQuality.sh" "${upstream_args[@]}"
    rc=$?
    set -e
    printf 'tcpquality_exit=%s\n' "$rc"
    printf '\n== node snapshots after ==\n'
    snapshot_nodes all "$all_after" || rc=1
    snapshot_nodes tos "$tos_after" || rc=1
    if [ -s "$all_after" ] && [ -s "$tos_after" ]; then
      sha256sum "$all_after" "$tos_after" || rc=1
      record_node_snapshot "$run" all after "$all_after" || rc=1
      record_node_snapshot "$run" tos after "$tos_after" || rc=1
    else
      rc=1
    fi
    printf '\n'
    capture_host_state post-run || rc=1
    printf 'utc_end=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$log" 2>&1

  find_csv_inventory >"$csv_after" || return 1
  find_debug_inventory >"$debug_after" || return 1
  new_csv="$(comm -13 "$csv_before" "$csv_after")" || return 1
  debug_archive="$(comm -13 "$debug_before" "$debug_after")" || return 1
  rm -f -- "$csv_before" "$csv_after" "$debug_before" "$debug_after"
  [ "$rc" -eq 0 ] || return "$rc"
  [ "$(printf '%s\n' "$new_csv" | sed '/^$/d' | wc -l)" -eq 1 ] || {
    printf '[FAIL] run %s 未产生且仅产生一个新 CSV。\n' "$run" >>"$log"
    return 1
  }
  [ -s "${EVIDENCE_DIR}/${new_csv}" ] || return 1
  [ "$(printf '%s\n' "$debug_archive" | sed '/^$/d' | wc -l)" -eq 1 ] || {
    printf '[FAIL] run %s 未产生且仅产生一个新 debug archive。\n' "$run" >>"$log"
    return 1
  }
  [ -s "${EVIDENCE_DIR}/${debug_archive}" ] || return 1
  csv_hash="$(sha256sum "${EVIDENCE_DIR}/${new_csv}" | awk '{print $1}')" || return 1
  printf '%s  %s\n' "$csv_hash" "${EVIDENCE_DIR}/${new_csv}" >>"$log" || return 1
  printf '%s\t%s\t%s\n' "$run" "$new_csv" "$csv_hash" \
    >>"${EVIDENCE_DIR}/csv-inventory.tsv" || return 1
  debug_hash="$(sha256sum "${EVIDENCE_DIR}/${debug_archive}" | awk '{print $1}')" || return 1
  printf '%s\t%s\t%s\n' "$run" "$debug_archive" "$debug_hash" \
    >>"${EVIDENCE_DIR}/debug-inventory.tsv" || return 1
  record_retransmission_evidence "$run" "${EVIDENCE_DIR}/${debug_archive}" || return 1
  record_node_drift "$run" all "$all_before" "$all_after" || return 1
  record_node_drift "$run" tos "$tos_before" "$tos_after" || return 1
}

finalize_manifest() {
  (
    cd "$EVIDENCE_DIR" || return 1
    : >SHA256SUMS.tmp || return 1
    while IFS= read -r -d '' file; do
      sha256sum "${file#./}" >>SHA256SUMS.tmp || return 1
    done < <(find . -maxdepth 1 -type f \
      ! -name SHA256SUMS ! -name SHA256SUMS.tmp \
      ! -name INCOMPLETE ! -name COMPLETED ! -name COMPLETED.tmp -print0 | sort -z)
    [ -s SHA256SUMS.tmp ] || return 1
    chmod 0600 SHA256SUMS.tmp || return 1
    mv -f SHA256SUMS.tmp SHA256SUMS || return 1
    sha256sum -c SHA256SUMS || return 1
  )
}

main() {
  local run successful=0 run_rc=0 manifest_sha
  [ "$(id -u)" -eq 0 ] || fail '必须以 root 运行。'
  for command in awk bash chmod cmp comm curl date dirname find free grep id ip mv nstat sed sha256sum sleep sort ss swapon sysctl tar tc tr uptime wc; do
    need_command "$command"
  done
  [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail 'TCPQUALITY_COMMIT 必须是 40 位小写十六进制 commit。'
  [[ "$ROOTFS_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail 'TCPQUALITY_ROOTFS_SHA256 必须是 64 位小写十六进制 SHA256。'
  [ "$COMMIT" = "$SUPPORTED_COMMIT" ] || fail "本版工具只接受已审计 commit：${SUPPORTED_COMMIT}。"
  [ "$ROOTFS_SHA256" = "$SUPPORTED_ROOTFS_SHA256" ] || fail 'rootfs SHA256 不属于本版已审计依赖。'
  case "$MODE" in
    local-evidence | public-report) ;;
    *) fail 'TCPQUALITY_MODE 必须显式设为 local-evidence 或 public-report。' ;;
  esac
  [ "$ACK_TRANSIENT_FIREWALL" = '1' ] ||
    fail 'v1.00013 会临时创建/删除 iptables 计数链；确认维护边界后设置 TCPQUALITY_ACK_TRANSIENT_FIREWALL=1。'
  [ -n "$PIN_DIR" ] && [[ "$PIN_DIR" = /* ]] || fail 'TCPQUALITY_PIN_DIR 必须是绝对路径。'
  [ -d "$PIN_DIR" ] && [ ! -L "$PIN_DIR" ] || fail 'TCPQUALITY_PIN_DIR 不存在或是符号链接。'
  [ -n "$EVIDENCE_DIR" ] && [[ "$EVIDENCE_DIR" = /* ]] || fail 'TCPQUALITY_EVIDENCE_DIR 必须是绝对路径。'
  [ ! -e "$EVIDENCE_DIR" ] && [ ! -L "$EVIDENCE_DIR" ] || fail '证据目录已经存在，拒绝覆盖。'
  [ -d "$(dirname "$EVIDENCE_DIR")" ] || fail '证据目录的父目录不存在。'
  validate_integer TCPQUALITY_RUNS "$RUNS" 1 10
  validate_integer TCPQUALITY_DELAY_SECONDS "$DELAY_SECONDS" 0 3600
  validate_integer TCPQUALITY_COUNT "$COUNT" 1 600
  validate_integer TCPQUALITY_PACKET_SIZE "$PACKET_SIZE" 0 65535
  validate_integer TCPQUALITY_PARALLEL "$PARALLEL" 1 31
  validate_integer TCPQUALITY_PLANNED_PAYLOAD_BYTES "$TCPQUALITY_PLANNED_PAYLOAD_BYTES" 1 1099511627776
  validate_integer DVT_TRAFFIC_BUDGET_BYTES "$DVT_TRAFFIC_BUDGET_BYTES" 1 1099511627776
  [ -n "$DVT_TRAFFIC_BUDGET_TOOL" ] && [[ "$DVT_TRAFFIC_BUDGET_TOOL" = /* ]] &&
    [ -f "$DVT_TRAFFIC_BUDGET_TOOL" ] && [ ! -L "$DVT_TRAFFIC_BUDGET_TOOL" ] ||
    fail '必须通过 DVT_TRAFFIC_BUDGET_TOOL 指定经校验的预算工具。'
  [ -n "$DVT_TRAFFIC_LEDGER" ] && [ -n "$DVT_TRAFFIC_WINDOW_ID" ] ||
    fail '必须设置 DVT_TRAFFIC_LEDGER 和 DVT_TRAFFIC_WINDOW_ID。'
  [[ "$GET_NODES_URL" =~ ^https://[A-Za-z0-9._:-]+(/[A-Za-z0-9._~:/%+-]*)?$ ]] ||
    fail 'TCPQUALITY_GET_NODES_URL 必须是不含查询参数、片段、userinfo 或空白的 HTTPS URL。'
  RUNS=$((10#$RUNS))
  DELAY_SECONDS=$((10#$DELAY_SECONDS))
  COUNT=$((10#$COUNT))
  PACKET_SIZE=$((10#$PACKET_SIZE))
  PARALLEL=$((10#$PARALLEL))
  TCPQUALITY_PLANNED_PAYLOAD_BYTES=$((10#$TCPQUALITY_PLANNED_PAYLOAD_BYTES))
  DVT_TRAFFIC_BUDGET_BYTES=$((10#$DVT_TRAFFIC_BUDGET_BYTES))
  [ -f "${PIN_DIR}/SHA256SUMS" ] || fail '固定目录缺少 SHA256SUMS。'
  [ -f "${PIN_DIR}/PINNED-METADATA.txt" ] || fail '固定目录缺少 PINNED-METADATA.txt。'
  [ -f "${PIN_DIR}/rootfs-manifest.json" ] || fail '固定目录缺少 rootfs-manifest.json。'
  [ -x "${PIN_DIR}/runTcpQuality.sh" ] || fail '固定目录缺少可执行 runTcpQuality.sh。'
  [ -x "${PIN_DIR}/runTcpQuality-rootfs.sh" ] || fail '固定目录缺少可执行 runTcpQuality-rootfs.sh。'
  [ -x "${PIN_DIR}/runTcpQuality-core.sh" ] || fail '固定目录缺少可执行 runTcpQuality-core.sh。'
  [ -f "${PIN_DIR}/tcpquality-rootfs-amd64.tar.gz" ] || fail '固定目录缺少 rootfs。'
  [ "$(wc -c <"${PIN_DIR}/tcpquality-rootfs-amd64.tar.gz" | tr -d ' ')" = "$SUPPORTED_ROOTFS_SIZE" ] ||
    fail 'rootfs 大小与已审计 release manifest 不一致。'
  grep -Fqx "tcpquality_release_tag=${SUPPORTED_RELEASE_TAG}" "${PIN_DIR}/PINNED-METADATA.txt" ||
    fail 'PINNED-METADATA.txt 中的 release tag 不属于本版已审计依赖。'
  grep -Fqx "tcpquality_commit=${COMMIT}" "${PIN_DIR}/PINNED-METADATA.txt" ||
    fail 'PINNED-METADATA.txt 中的 commit 与 TCPQUALITY_COMMIT 不一致。'
  for metadata_line in \
    "rootfs_manifest_file=rootfs-manifest.json" \
    "rootfs_manifest_sha256=${SUPPORTED_ROOTFS_MANIFEST_SHA256}" \
    "rootfs_file=tcpquality-rootfs-amd64.tar.gz" \
    "rootfs_size=${SUPPORTED_ROOTFS_SIZE}" \
    "rootfs_sha256=${SUPPORTED_ROOTFS_SHA256}" \
    "tcp_info_helper_path=usr/local/lib/libtcpquality-tcpinfo.so" \
    "tcp_info_helper_size=${SUPPORTED_TCP_INFO_HELPER_SIZE}" \
    "tcp_info_helper_sha256=${SUPPORTED_TCP_INFO_HELPER_SHA256}" \
    "retrans_seq_path=usr/local/libexec/tcpquality-retrans-seq.bt" \
    "retrans_seq_size=${SUPPORTED_RETRANS_SEQ_SIZE}" \
    "retrans_seq_sha256=${SUPPORTED_RETRANS_SEQ_SHA256}" \
    "retrans_skb_path=usr/local/libexec/tcpquality-retrans-skb.bt" \
    "retrans_skb_size=${SUPPORTED_RETRANS_SKB_SIZE}" \
    "retrans_skb_sha256=${SUPPORTED_RETRANS_SKB_SHA256}"; do
    grep -Fqx "$metadata_line" "${PIN_DIR}/PINNED-METADATA.txt" ||
      fail "PINNED-METADATA.txt 缺少已审计字段：${metadata_line%%=*}。"
  done
  printf '%s  %s\n' \
    "$SUPPORTED_RUN_SHA256" "${PIN_DIR}/runTcpQuality.sh" \
    "$SUPPORTED_ROOTFS_RUNNER_SHA256" "${PIN_DIR}/runTcpQuality-rootfs.sh" \
    "$SUPPORTED_CORE_SHA256" "${PIN_DIR}/runTcpQuality-core.sh" \
    "$SUPPORTED_ROOTFS_MANIFEST_SHA256" "${PIN_DIR}/rootfs-manifest.json" \
    "$SUPPORTED_ROOTFS_SHA256" "${PIN_DIR}/tcpquality-rootfs-amd64.tar.gz" |
    sha256sum -c -
  (cd "$PIN_DIR" && sha256sum -c SHA256SUMS)

  mkdir -m 0700 -- "$EVIDENCE_DIR"
  printf 'status=INCOMPLETE\nstage=initialization\nutc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${EVIDENCE_DIR}/INCOMPLETE"
  trap 'write_incomplete_marker ERR' ERR
  trap 'write_incomplete_marker INT; exit 130' INT
  trap 'write_incomplete_marker TERM; exit 143' TERM
  TRAFFIC_RESERVATION_ID="tcpquality-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  bash "$DVT_TRAFFIC_BUDGET_TOOL" reserve --ledger "$DVT_TRAFFIC_LEDGER" \
    --window-id "$DVT_TRAFFIC_WINDOW_ID" --budget-bytes "$DVT_TRAFFIC_BUDGET_BYTES" \
    --tool tcpquality --run-id "$TRAFFIC_RESERVATION_ID" \
    --reservation-id "$TRAFFIC_RESERVATION_ID" \
    --planned-bytes "$TCPQUALITY_PLANNED_PAYLOAD_BYTES" >/dev/null ||
    fail 'TcpQuality 未能保留共享流量预算；没有开始网络测试。'
  TRAFFIC_RESERVED=1

  printf 'run\tcsv\tsha256\n' >"${EVIDENCE_DIR}/csv-inventory.tsv"
  printf 'run\tdebug_archive\tsha256\n' >"${EVIDENCE_DIR}/debug-inventory.tsv"
  printf 'run\tscope\tphase\tfile\tsha256\n' >"${EVIDENCE_DIR}/node-inventory.tsv"
  printf 'run\tscope\tbefore_rows\tafter_rows\tlogical_removed\tlogical_added\tip_changed\texact_equal\n' >"${EVIDENCE_DIR}/node-drift.tsv"
  printf 'run\tdebug_archive\tmeta_file\tprobe_type\tserver_ip\tresult\tmetric_source\ttcp_info_total_retrans\ttcp_info_data_segs_out\ttcp_info_segs_out\ttcp_info_bytes_retrans\tebpf_unique_retrans\tratio_denominator\tratio\tfallback_reason\tmeasurement_status\n' \
    >"${EVIDENCE_DIR}/retransmission-evidence.tsv"
  {
    printf 'tool_version=%s\nutc_start=%s\n' "$TOOL_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'tcpquality_release_tag=%s\ntcpquality_commit=%s\nrootfs_manifest_sha256=%s\nrootfs_sha256=%s\n' \
      "$SUPPORTED_RELEASE_TAG" "$COMMIT" "$SUPPORTED_ROOTFS_MANIFEST_SHA256" "$ROOTFS_SHA256"
    printf 'mode=%s\ntransient_firewall_counter_ack=%s\nreport_upload=%s\ndebug_bundle_upload=%s\n' "$MODE" "$ACK_TRANSIENT_FIREWALL" \
      "$( [ "$MODE" = public-report ] && printf enabled || printf disabled )" \
      "$( [ "$MODE" = public-report ] && printf enabled || printf disabled )"
    printf 'get_nodes_url=%s\nruns=%s\ndelay_seconds=%s\n' "$GET_NODES_URL" "$RUNS" "$DELAY_SECONDS"
    printf 'traffic_budget_window_id=%s\ntraffic_reservation_id=%s\nplanned_payload_bytes=%s\nprotocol_overhead_included=false\n' \
      "$DVT_TRAFFIC_WINDOW_ID" "$TRAFFIC_RESERVATION_ID" "$TCPQUALITY_PLANNED_PAYLOAD_BYTES"
    printf 'args=-c %s -s %s -p %s --all --debug%s\n' "$COUNT" "$PACKET_SIZE" "$PARALLEL" \
      "$( [ "$MODE" = local-evidence ] && printf ' --no-rank-upload' || true )"
    printf 'measurement_contract=flow-level when metric_source is ebpf_* or tcp_info_*; nstat is MEASUREMENT_DEGRADED\n'
  } >"${EVIDENCE_DIR}/summary.txt"

  for ((run=1; run<=RUNS; run++)); do
    printf '[INFO] starting run %s/%s\n' "$run" "$RUNS"
    set +e
    (set -Eeuo pipefail; run_one "$run")
    run_rc=$?
    set -e
    if [ "$run_rc" -eq 0 ]; then
      successful=$((successful + 1))
    else
      printf 'successful_runs=%s\nbatch_result=FAIL\nfailed_run=%s\n' "$successful" "$run" >>"${EVIDENCE_DIR}/summary.txt"
      printf 'status=INCOMPLETE\nstage=run-%s\nexit_code=%s\nutc=%s\n' "$run" "$run_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${EVIDENCE_DIR}/INCOMPLETE"
      finalize_manifest || true
      trap - ERR INT TERM
      fail "TcpQuality run ${run} 失败；保留证据目录并停止。"
    fi
    if [ "$run" -lt "$RUNS" ] && [ "$DELAY_SECONDS" -gt 0 ]; then
      sleep "$DELAY_SECONDS"
    fi
  done
  printf 'successful_runs=%s\nutc_end=%s\nbatch_result=PASS\n' \
    "$successful" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${EVIDENCE_DIR}/summary.txt"
  if ! bash "$DVT_TRAFFIC_BUDGET_TOOL" commit-unknown --ledger "$DVT_TRAFFIC_LEDGER" \
    --reservation-id "$TRAFFIC_RESERVATION_ID" >/dev/null; then
    write_incomplete_marker budget-commit
    trap - ERR INT TERM
    fail 'TcpQuality 完成，但无法保守结算共享预算。'
  fi
  TRAFFIC_RESERVED=0
  if ! finalize_manifest; then
    printf 'manifest_result=FAIL\n' >>"${EVIDENCE_DIR}/summary.txt" 2>/dev/null || true
    printf 'status=INCOMPLETE\nstage=manifest\nutc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${EVIDENCE_DIR}/INCOMPLETE" 2>/dev/null || true
    trap - ERR INT TERM
    fail '最终证据清单生成或校验失败。'
  fi
  manifest_sha="$(sha256sum "${EVIDENCE_DIR}/SHA256SUMS" | awk '{print $1}')" || fail '无法计算最终证据清单哈希。'
  printf 'status=COMPLETED\nevidence_manifest_sha256=%s\nutc=%s\n' \
    "$manifest_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${EVIDENCE_DIR}/COMPLETED.tmp" || fail '无法生成完成标记。'
  chmod 0600 "${EVIDENCE_DIR}/COMPLETED.tmp" || fail '无法设置完成标记权限。'
  mv -f "${EVIDENCE_DIR}/COMPLETED.tmp" "${EVIDENCE_DIR}/COMPLETED" || fail '无法提交完成标记。'
  rm -f "${EVIDENCE_DIR}/INCOMPLETE" || { rm -f "${EVIDENCE_DIR}/COMPLETED"; fail '无法移除未完成标记。'; }
  trap - ERR INT TERM
  printf '[PASS] evidence_dir=%s successful_runs=%s\n' "$EVIDENCE_DIR" "$successful"
}

main "$@"
