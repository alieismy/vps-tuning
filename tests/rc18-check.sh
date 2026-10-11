#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
chmod 0700 "$test_root"

budget_tool="${repo_root}/dvt-traffic-budget.sh"
ledger="${test_root}/ledger/window.json"
bash "$budget_tool" init --ledger "$ledger" --window-id fixture --budget-bytes 1000 >/dev/null
bash "$budget_tool" reserve --ledger "$ledger" --window-id fixture --budget-bytes 1000 \
  --tool probe --run-id run-1 --reservation-id reservation-1 --planned-bytes 600 >/dev/null
if bash "$budget_tool" reserve --ledger "$ledger" --window-id fixture --budget-bytes 1000 \
  --tool benchmark --run-id run-2 --reservation-id reservation-2 --planned-bytes 500 >/dev/null 2>&1; then
  printf 'over-budget reservation was accepted\n' >&2
  exit 1
fi
bash "$budget_tool" commit --ledger "$ledger" --reservation-id reservation-1 --actual-bytes 400 >/dev/null
bash "$budget_tool" reserve --ledger "$ledger" --window-id fixture --budget-bytes 1000 \
  --tool benchmark --run-id run-2 --reservation-id reservation-2 --planned-bytes 500 >/dev/null
bash "$budget_tool" fail --ledger "$ledger" --reservation-id reservation-2 >/dev/null
jq -e '.reserved_bytes==0 and .accounted_bytes==900 and .status=="OPEN" and
  ([.entries[].status] == ["COMMITTED","FAILED_CONSERVATIVE"])' "$ledger" >/dev/null

check_migration() (
# 每个来源使用独立状态和 checkpoint，保留旧来源回归并覆盖新增上界。
source_release="$1"
migration_root="${test_root}/${source_release}"
mkdir -m 0700 "$migration_root"
state_file="${migration_root}/managed-state.json"
boot_file="${migration_root}/boot-id"
source_profile="${migration_root}/source-profile.sh"
target_profile="${migration_root}/target-profile.sh"
checkpoint="${migration_root}/checkpoint"
printf '%s\n' boot-a >"$boot_file"
jq -n --arg version "$source_release" \
  '{schema_version:4,script_version:$version,state:"VERIFIED",profile:{id:"debian13-1c1g"},network:{port_speed_mbps:200},original_sysctls:{"net.ipv4.tcp_rmem":"4096\t131072\t6291456","net.ipv4.tcp_wmem":"4096\t16384\t4194304"}}' >"$state_file"
{
printf '%s\n' '#!/usr/bin/env bash'
printf "SCRIPT_VERSION='%s'\n" "$source_release"
cat <<'EOF_SOURCE'
set -Eeuo pipefail
PROFILE_ID='debian13-1c1g'
case "$1" in
  verify) jq -e --arg version "$SCRIPT_VERSION" '.script_version==$version and .state=="VERIFIED"' "$DVT_STATE_FILE" >/dev/null ;;
  rollback) rm -f -- "$DVT_STATE_FILE" ;;
  *) exit 2 ;;
esac
EOF_SOURCE
} >"$source_profile"
{
printf '%s\n' '#!/usr/bin/env bash'
printf "SOURCE_VERSION='%s'\n" "$source_release"
cat <<'EOF_TARGET'
set -Eeuo pipefail
SCRIPT_VERSION='0.2.0-rc.2'
PROFILE_ID='debian13-1c1g'
case "$1" in
  preflight) [ ! -e "$DVT_STATE_FILE" ] || jq -e --arg version "$SOURCE_VERSION" '.script_version==$version' "$DVT_STATE_FILE" >/dev/null ;;
  apply) printf '%s\n' '{"schema_version":4,"script_version":"0.2.0-rc.2","state":"APPLIED","profile":{"id":"debian13-1c1g"},"network":{"port_speed_mbps":200}}' >"$DVT_STATE_FILE" ;;
  verify) jq '.state="VERIFIED"' "$DVT_STATE_FILE" >"${DVT_STATE_FILE}.tmp"; mv -f "${DVT_STATE_FILE}.tmp" "$DVT_STATE_FILE" ;;
  *) exit 2 ;;
esac
EOF_TARGET
} >"$target_profile"
chmod 0700 "$source_profile" "$target_profile"
state_hash="$(sha256sum "$state_file" | awk '{print $1}')"
for rejected_source in 0.2.0-rc.1 0.1.0-rc.20; do
if env DVT_STATE_FILE="$state_file" DVT_BOOT_ID_FILE="$boot_file" \
  bash "${repo_root}/dvt-migrate.sh" prepare --checkpoint "${checkpoint}-rejected" \
  --source-profile "$source_profile" --target-profile "$target_profile" \
  --source-version "$rejected_source" --target-version 0.2.0-rc.2 \
  --profile-id debian13-1c1g --port 200 --state-sha256 "$state_hash" >"${migration_root}/rejected.log" 2>&1; then
  printf 'migration accepted source version %s\n' "$rejected_source" >&2
  exit 1
fi
grep -Fq '本版迁移器只接受 rc.1–rc.19 来源' "${migration_root}/rejected.log"
[ ! -e "${checkpoint}-rejected" ]
[ "$(sha256sum "$state_file" | awk '{print $1}')" = "$state_hash" ]
done
bad_state="${migration_root}/truncated-state.json"
jq '.original_sysctls["net.ipv4.tcp_rmem"]="4096"' "$state_file" >"$bad_state"
bad_hash="$(sha256sum "$bad_state" | awk '{print $1}')"
if env DVT_STATE_FILE="$bad_state" DVT_BOOT_ID_FILE="$boot_file" \
  bash "${repo_root}/dvt-migrate.sh" prepare --checkpoint "${checkpoint}-truncated" \
  --source-profile "$source_profile" --target-profile "$target_profile" \
  --source-version "$source_release" --target-version 0.2.0-rc.2 \
  --profile-id debian13-1c1g --port 200 --state-sha256 "$bad_hash" >"${migration_root}/truncated.log" 2>&1; then
  printf 'migration accepted an incomplete original TCP buffer vector\n' >&2
  exit 1
fi
grep -Fq '来源状态缺少完整 TCP buffer 三元组' "${migration_root}/truncated.log"
[ ! -e "${checkpoint}-truncated" ]
[ "$(sha256sum "$bad_state" | awk '{print $1}')" = "$bad_hash" ]
env DVT_STATE_FILE="$state_file" DVT_BOOT_ID_FILE="$boot_file" \
  bash "${repo_root}/dvt-migrate.sh" prepare --checkpoint "$checkpoint" \
  --source-profile "$source_profile" --target-profile "$target_profile" \
  --source-version "$source_release" --target-version 0.2.0-rc.2 \
  --profile-id debian13-1c1g --port 200 --state-sha256 "$state_hash" >/dev/null
[ "$(sha256sum "$state_file" | awk '{print $1}')" = "$state_hash" ]
jq -e --arg source "$source_release" --arg state_hash "$state_hash" \
  '.phase=="PREPARED" and .source_version==$source and .target_version=="0.2.0-rc.2" and
   .source_state_sha256==$state_hash' "$checkpoint/migration.json" >/dev/null
env DVT_STATE_FILE="$state_file" DVT_BOOT_ID_FILE="$boot_file" \
  bash "$checkpoint/dvt-migrate.sh" rollback --checkpoint "$checkpoint" >/dev/null
[ ! -e "$state_file" ]
if env DVT_STATE_FILE="$state_file" DVT_BOOT_ID_FILE="$boot_file" \
  bash "$checkpoint/dvt-migrate.sh" continue --checkpoint "$checkpoint" >/dev/null 2>&1; then
  printf 'first reboot gate accepted unchanged boot ID\n' >&2
  exit 1
fi
jq -e '.phase=="ROLLED_BACK_REBOOT_REQUIRED"' "$checkpoint/migration.json" >/dev/null
[ ! -e "$state_file" ]
printf '%s\n' boot-b >"$boot_file"
env DVT_STATE_FILE="$state_file" DVT_BOOT_ID_FILE="$boot_file" \
  bash "$checkpoint/dvt-migrate.sh" continue --checkpoint "$checkpoint" >/dev/null
jq -e '.script_version=="0.2.0-rc.2" and .state=="APPLIED"' "$state_file" >/dev/null
applied_hash="$(sha256sum "$state_file" | awk '{print $1}')"
if env DVT_STATE_FILE="$state_file" DVT_BOOT_ID_FILE="$boot_file" \
  bash "$checkpoint/dvt-migrate.sh" continue --checkpoint "$checkpoint" >/dev/null 2>&1; then
  printf 'second reboot gate accepted unchanged boot ID\n' >&2
  exit 1
fi
jq -e '.phase=="TARGET_APPLIED_REBOOT_REQUIRED"' "$checkpoint/migration.json" >/dev/null
[ "$(sha256sum "$state_file" | awk '{print $1}')" = "$applied_hash" ]
printf '%s\n' boot-c >"$boot_file"
env DVT_STATE_FILE="$state_file" DVT_BOOT_ID_FILE="$boot_file" \
  bash "$checkpoint/dvt-migrate.sh" continue --checkpoint "$checkpoint" >/dev/null
jq -e '.phase=="COMPLETE" and ([.history[].phase] | index("ROLLBACK_RUNNING") != null) and
  ([.history[].phase] | index("TARGET_APPLIED_REBOOT_REQUIRED") != null)' "$checkpoint/migration.json" >/dev/null
jq -e '.script_version=="0.2.0-rc.2" and .state=="VERIFIED"' "$state_file" >/dev/null
printf 'migration fixture passed: %s -> 0.2.0-rc.2\n' "$source_release"
)

check_migration 0.1.0-rc.16
check_migration 0.1.0-rc.17
check_migration 0.1.0-rc.18
check_migration 0.1.0-rc.19

profile="${repo_root}/debian13-1c1g-vps-tuning.sh"
process_fixture="${test_root}/benchmark-process-fixture.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
  awk '/^benchmark_reap_active_child\(\)/,/^}/' "$profile"
  awk '/^run_iperf3_with_timeout\(\)/,/^}/' "$profile"
  cat <<'EOF_PROCESS_FIXTURE'
BENCHMARK_ACTIVE_CHILD_PID=''
BENCHMARK_ACTIVE_CHILD_PGID=''
BENCHMARK_PHASE_TIMEOUT_RESOLVED=1
BENCHMARK_TIMEOUT_TERMINATE_GRACE_SECONDS=1
warn() { :; }
run_iperf3_with_timeout "$DVT_PROCESS_OUTPUT" --fixture
EOF_PROCESS_FIXTURE
} >"$process_fixture"
chmod 0700 "$process_fixture"

fake_bin="${test_root}/fake-bin"
mkdir -m 0700 "$fake_bin"
cat >"${fake_bin}/iperf3" <<'EOF_FAKE_IPERF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap '' TERM
sleep 300 &
child=$!
printf '%s %s\n' "$$" "$child" >"$DVT_PROCESS_PIDS"
wait "$child"
EOF_FAKE_IPERF
chmod 0700 "${fake_bin}/iperf3"
set +e
env PATH="${fake_bin}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  DVT_PROCESS_OUTPUT="${test_root}/iperf-output.json" DVT_PROCESS_PIDS="${test_root}/iperf-pids" \
  bash "$process_fixture" >/dev/null 2>&1
process_rc=$?
set -e
case "$process_rc" in
  124 | 137) ;;
  *) printf 'benchmark timeout fixture returned rc=%s\n' "$process_rc" >&2; exit 1 ;;
esac
[ -s "${test_root}/iperf-pids" ] || { printf 'benchmark timeout fixture did not record child processes\n' >&2; exit 1; }
# PID 记录以空格分隔，不能沿用全局仅包含换行/制表符的 IFS。
IFS=' ' read -r iperf_pid sleep_pid extra_pid <"${test_root}/iperf-pids"
if ! [[ "$iperf_pid" =~ ^[1-9][0-9]*$ && "$sleep_pid" =~ ^[1-9][0-9]*$ ]] ||
  [ "$iperf_pid" = "$sleep_pid" ] || [ -n "$extra_pid" ]; then
  printf 'benchmark timeout fixture recorded invalid process IDs\n' >&2
  exit 1
fi
for _ in 1 2 3 4 5; do
  if ! kill -0 "$iperf_pid" 2>/dev/null && ! kill -0 "$sleep_pid" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$iperf_pid" 2>/dev/null || kill -0 "$sleep_pid" 2>/dev/null; then
  printf 'benchmark timeout left an iperf3 process-group member alive\n' >&2
  exit 1
fi

printf 'rc.19 traffic-budget, migration, and benchmark process checks passed\n'
