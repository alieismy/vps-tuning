#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=debian-vps-tuning.sh
source "$repo_root/debian-vps-tuning.sh"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() { printf 'controller test failed: %s\n' "$*" >&2; exit 1; }

write_os_release() {
  local file="$1" id="$2" version="$3"
  printf 'ID=%q\nVERSION_ID=%q\nPRETTY_NAME=%q\n' \
    "$id" "$version" "Test OS ${version}" >"$file"
}

write_meminfo() {
  local file="$1" mib="$2"
  printf 'MemTotal:       %s kB\n' "$((mib * 1024))" >"$file"
}

assert_profile() {
  local version="$1" cpus="$2" memory="$3" expected="$4" expected_class="$5"
  local os_file="$test_root/os-${version}-${cpus}-${memory}" mem_file="$test_root/mem-${memory}" result actual actual_class
  write_os_release "$os_file" debian "$version"
  write_meminfo "$mem_file" "$memory"
  result="$(detect_profile_from "$os_file" "$mem_file" x86_64 "$cpus")" ||
    fail "profile detection failed for Debian ${version}, ${cpus} vCPU, ${memory} MiB"
  IFS=$'\t' read -r actual _ _ _ actual_class <<<"$result"
  [ "$actual" = "$expected" ] ||
    fail "Debian ${version}, ${cpus} vCPU, ${memory} MiB selected ${actual}, expected ${expected}"
  [ "$actual_class" = "$expected_class" ] ||
    fail "Debian ${version}, ${cpus} vCPU, ${memory} MiB selected class ${actual_class}, expected ${expected_class}"
}

assert_profile 12 1 384 debian12-1c512m 1C512MB
assert_profile 12 1 512 debian12-1c512m 1C512MB
assert_profile 12 1 767 debian12-1c512m 1C512MB
assert_profile 12 1 768 debian12-1c1g 1C1GB
assert_profile 12 1 1024 debian12-1c1g 1C1GB
assert_profile 12 1 1535 debian12-1c1g 1C1GB
assert_profile 12 1 1536 debian12-1c2g 1C2GB
assert_profile 12 1 2048 debian12-1c2g 1C2GB
assert_profile 12 2 1536 debian12-1c2g 2C2GB
assert_profile 12 2 2048 debian12-1c2g 2C2GB
assert_profile 13 1 512 debian13-1c512m 1C512MB
assert_profile 13 1 1024 debian13-1c1g 1C1GB
assert_profile 13 1 2048 debian13-1c2g 1C2GB
assert_profile 13 2 2048 debian13-1c2g 2C2GB

state_profile_matches_detected debian12-1c1g debian12-1c1g || fail 'matching state profile was rejected'
if state_profile_matches_detected debian12-1c1g debian12-1c2g; then
  fail 'mismatched state profile was accepted'
fi

unsupported_os="$test_root/os-unsupported"
supported_mem="$test_root/mem-supported"
write_os_release "$unsupported_os" ubuntu 22.04
write_meminfo "$supported_mem" 1024
set +e
detect_profile_from "$unsupported_os" "$supported_mem" x86_64 1 >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unsupported OS returned ${rc}, expected 2"

supported_os="$test_root/os-supported"
write_os_release "$supported_os" debian 12
set +e
detect_profile_from "$supported_os" "$supported_mem" riscv64 1 >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unsupported architecture returned ${rc}, expected 2"

unsupported_mem="$test_root/mem-unsupported"
write_meminfo "$unsupported_mem" 383
set +e
detect_profile_from "$supported_os" "$unsupported_mem" x86_64 1 >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "unsupported memory returned ${rc}, expected 3"

for unsupported_resource in '1 383' '2 383' '3 128'; do
  IFS=' ' read -r test_cpus test_mem <<<"$unsupported_resource"
  test_mem_file="$test_root/mem-unsupported-${test_cpus}-${test_mem}"
  write_meminfo "$test_mem_file" "$test_mem"
  set +e
  detect_profile_from "$supported_os" "$test_mem_file" x86_64 "$test_cpus" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "unsupported ${test_cpus} vCPU/${test_mem} MiB returned ${rc}, expected 3"
done

set +e
detect_profile_from "$supported_os" "$supported_mem" x86_64 invalid >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "invalid CPU count returned ${rc}, expected 1"

for valid_port in 1 99 100 200 500 1000 1001 10000 0200; do
  validate_port_speed "$valid_port" || fail "valid port rejected: ${valid_port}"
done
for invalid_port in 0 10001 20000 abc 20.0 ''; do
  if validate_port_speed "$invalid_port"; then
    fail "invalid port accepted: ${invalid_port:-empty}"
  fi
done

release_is_newer v0.1.0-rc.17 0.1.0-rc.16 || fail 'rc.17 was not newer than rc.16'
release_is_newer v0.1.0 0.1.0-rc.999999999 || fail 'stable release was not newer than prerelease'
release_is_newer v0.2.0-rc.1 0.1.9 || fail 'minor release comparison failed'
if release_is_newer v0.1.0-rc.16 0.1.0-rc.17; then
  fail 'downgrade tag was considered newer'
fi
if parse_release_version latest >/dev/null 2>&1; then
  fail 'non-semver release tag was accepted'
fi
for invalid_release in v00.1.0 v0.01.0 v0.1.00 v0.1.0-rc.01 v1000000000.1.0; do
  if parse_release_version "$invalid_release" >/dev/null 2>&1; then
    fail "invalid release tag was accepted: ${invalid_release}"
  fi
done

release_fixture="$test_root/releases.json"
cat >"$release_fixture" <<'EOF_RELEASES'
[
  {"tag_name":"v0.1.0-rc.9","draft":false},
  {"tag_name":"v0.1.0-rc.17","draft":false},
  {"tag_name":"v0.1.0-rc.15","draft":false},
  {"tag_name":"v0.1.0-rc.13","draft":false},
  {"tag_name":"v0.1.0-rc.12","draft":false},
  {"tag_name":"v0.1.0-rc.10","draft":false},
  {"tag_name":"v9.9.9","draft":true},
  {"tag_name":"v1.0.0","draft":false},
  {"tag_name":"v0.2.0","draft":false},
  {"tag_name":"nightly","draft":false}
]
EOF_RELEASES
# The Windows Git Bash test environment does not provide jq. This fixture
# isolates semantic version selection; JSON validation is exercised on VPS.
jq() {
  printf '%s\n' v0.1.0-rc.9 v0.1.0-rc.17 v0.1.0-rc.15 v0.1.0-rc.14 v0.1.0-rc.13 v0.1.0-rc.12 v0.1.0-rc.10 v0.2.0 v1.0.0 nightly
}
[ "$(select_highest_release_tag "$release_fixture" 0.1.0-rc.15)" = 'v0.1.0-rc.17' ] ||
  fail 'rc channel did not select its highest prerelease'
unset -f jq
jq() {
  printf '%s\n' v0.1.0-rc.12 v0.1.0 v0.2.0
}
[ "$(select_highest_release_tag "$release_fixture" 0.1.0-rc.11)" = 'v0.1.0' ] ||
  fail 'rc channel did not prefer the same-line stable release'
unset -f jq
jq() {
  printf '%s\n' v0.1.1-rc.1 v0.1.0 v0.2.0
}
[ "$(select_highest_release_tag "$release_fixture" 0.1.0)" = 'v0.1.0' ] ||
  fail 'stable channel accepted a prerelease candidate'
unset -f jq

ACTION=preflight
CLI_PORT_SPEED_MBPS=''
PORT_SPEED_MBPS_SELECTED=''
STATE_PROFILE=''
STATE_PORT_SPEED_MBPS=''
unset PORT_SPEED_MBPS || true
select_port_speed
[ "$PORT_SPEED_MBPS_SELECTED" -eq 200 ] || fail 'non-interactive default is not 200 Mbps'

ACTION=apply
STATE_PROFILE='debian12-1c1g'
STATE_PORT_SPEED_MBPS=500
PORT_SPEED_MBPS_SELECTED=''
select_port_speed
[ "$PORT_SPEED_MBPS_SELECTED" -eq 500 ] || fail 'apply did not reuse the installed port speed'

set +e
( ACTION=apply; CLI_PORT_SPEED_MBPS=''; STATE_PROFILE='debian12-1c1g'; STATE_PORT_SPEED_MBPS=invalid; PORT_SPEED_MBPS_SELECTED=''; select_port_speed ) >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq "$EXIT_CONFLICT" ] || fail "invalid installed port returned ${rc}, expected ${EXIT_CONFLICT}"

CLI_PORT_SPEED_MBPS=1000
PORT_SPEED_MBPS_SELECTED=''
select_port_speed
[ "$PORT_SPEED_MBPS_SELECTED" -eq 1000 ] || fail '--port did not override the installed value'

set +e
( ACTION=reconfigure; ACTION_FROM_MENU=0; CLI_PORT_SPEED_MBPS=''; PORT_SPEED_MBPS=200; PORT_SPEED_MBPS_SELECTED=''; select_port_speed ) >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq "$EXIT_USAGE" ] || fail "reconfigure without explicit --port returned ${rc}, expected ${EXIT_USAGE}"

ACTION=reconfigure
ACTION_FROM_MENU=0
CLI_PORT_SPEED_MBPS=500
PORT_SPEED_MBPS_SELECTED=''
select_port_speed
[ "$PORT_SPEED_MBPS_SELECTED" -eq 500 ] || fail 'reconfigure did not accept its explicit --port value'

# shellcheck disable=SC2034  # Consumed by sourced select_port_speed.
CLI_PORT_SPEED_MBPS=''
# shellcheck disable=SC2034  # Consumed by sourced select_port_speed.
PORT_SPEED_MBPS=100
ACTION=apply
ACTION_FROM_MENU=0
PORT_SPEED_MBPS_SELECTED=''
select_port_speed
[ "$PORT_SPEED_MBPS_SELECTED" -eq 100 ] || fail 'PORT_SPEED_MBPS did not override the installed value'
unset PORT_SPEED_MBPS
STATE_PROFILE=''
STATE_PORT_SPEED_MBPS=''

# Menu tests preset the home-screen facts; fact collection is smoke-tested below.
# shellcheck disable=SC2034  # Consumed by the sourced menu renderer.
set_menu_facts() {
  HOME_FACTS_READY=1 HOME_ROOT="$1" HOME_PLATFORM_OK="$2" HOME_STATE="$3"
  HOME_OS='Test OS 13' HOME_ARCH=x86_64 HOME_CPUS=1 HOME_MEMORY_MIB=1024
  HOME_PROFILE=debian13-1c1g HOME_RESOURCE_CLASS=1C1GB HOME_PLATFORM_REASON='test platform reason'
  HOME_STATE_VERSION='' HOME_STATE_PORT='' HOME_STATE_UPDATED='' HOME_RUNTIME='test runtime'
}

# Runs the menu in a subshell so an unexpected exit cannot end this script.
assert_menu() {
  local input="$1" expected="$2" label="$3" result
  result="$(
    ACTION='' ACTION_FROM_MENU=0
    choose_action_interactively <<<"$input" >/dev/null 2>&1
    printf 'selected=%s:%s' "$ACTION" "$ACTION_FROM_MENU"
  )" || true
  [ "$result" = "selected=${expected}:1" ] || fail "${label}: got '${result}', expected ${expected}"
}

assert_menu_exit() {
  local input="$1" expected_rc="$2" message="$3" label="$4" rc=0 output
  if [ "$input" = '<eof>' ]; then
    output="$(choose_action_interactively </dev/null 2>&1)" || rc=$?
  else
    output="$(choose_action_interactively <<<"$input" 2>&1)" || rc=$?
  fi
  [ "$rc" -eq "$expected_rc" ] || fail "${label}: exit ${rc}, expected ${expected_rc}"
  grep -Fq -- "$message" <<<"$output" || fail "${label}: output lacks '${message}'"
}

set_menu_facts 1 1 UNMANAGED
assert_menu '' guided 'default for an unmanaged host'
set_menu_facts 1 1 APPLIED
assert_menu '' verify 'default for an APPLIED record'
set_menu_facts 1 1 VERIFIED
assert_menu '' status 'default for a VERIFIED record'
set_menu_facts 1 1 DEGRADED
assert_menu '' status 'default for a DEGRADED record'
set_menu_facts 0 1 NEEDS_ROOT
assert_menu '' diagnose 'default for a non-root user'
set_menu_facts 1 0 UNMANAGED
assert_menu '' diagnose 'default for an unsupported platform'

set_menu_facts 1 1 VERIFIED
for mapping in 1:guided 2:preflight 3:apply 4:reconfigure 5:verify 6:status 7:diagnose 8:update 9:rollback; do
  assert_menu "${mapping%%:*}" "${mapping#*:}" "menu key ${mapping%%:*}"
done
assert_menu $'a\n1' htb 'advanced key 1'
assert_menu $'A\n1' htb 'upper-case advanced key'
assert_menu $'a\n0\n6' status 'advanced page returns to the home page'
assert_menu $'x\n5' verify 'one invalid answer before a valid one'
assert_menu_exit $'x\ny\nz' 2 '无效操作选择。' 'three invalid answers'
assert_menu_exit '<eof>' 0 '未执行任何操作。' 'end of input at the menu'
assert_menu_exit '0' 0 '未执行任何操作。' 'menu exit key'
if choose_action_interactively <<<$'zz-secret\n0' 2>&1 | grep -Fq 'zz-secret'; then
  fail 'menu echoed invalid input'
fi
set_menu_facts 0 1 NEEDS_ROOT
assert_menu $'3\n7' diagnose 'unavailable key re-prompts'
assert_menu $'a\n1\n0\n7' diagnose 'unavailable advanced key re-prompts'
assert_menu_exit $'3\n0' 0 '该项当前不可用' 'unavailable key explains the reason'

# Frame rows: 66 columns, frame character set only, in Unicode and ASCII modes.
set_menu_facts 1 1 VERIFIED
# shellcheck disable=SC2034  # Consumed by the sourced controller.
HOME_STATE_VERSION=0.2.0-rc.3 HOME_STATE_PORT=200 HOME_STATE_UPDATED=2026-10-12T00:00:00Z
for ascii in '' 1; do
  DVT_ASCII="$ascii" TERM=xterm ui_init
  # shellcheck disable=SC2034  # Consumed by the sourced controller.
  UI_LAYOUT=framed UI_EN=1 UI_COLOR_OUT=0
  frames="$({ render_home; render_advanced; } | grep -E '^(┌|├|│|└|\+|\|)')"
  [ "$(wc -l <<<"$frames")" -eq 20 ] || fail "expected 20 frame rows (DVT_ASCII='${ascii}')"
  while IFS= read -r row; do
    width="$(ui_width "$row")" || fail "frame row has a character outside the frame set: ${row}"
    [ "$width" -eq 66 ] || fail "frame row is ${width} columns: ${row}"
    ui_measure measured "$row"
    [ "$measured" -eq 66 ] || fail "fast width disagrees (${measured}): ${row}"
  done <<<"$frames"
done
if grep -Fq '─' <<<"$frames"; then fail 'DVT_ASCII frames contain box-drawing characters'; fi
[ "$(ui_width 'a中─')" -eq 4 ] || fail 'width of ASCII, CJK and box-drawing characters'
if ui_width '1–10000' >/dev/null; then fail 'an ambiguous-width dash passed the frame character set'; fi
TERM=dumb ui_init
[ "$UI_ASCII" -eq 1 ] && [ "$UI_LAYOUT" = open ] && [ "$UI_COLOR_OUT" -eq 0 ] || fail 'TERM=dumb did not degrade'
TERM=linux ui_init
[ "$UI_ASCII" -eq 1 ] && [ "$UI_LAYOUT" = open ] || fail 'TERM=linux did not degrade'

TERM=xterm ui_init
# shellcheck disable=SC2034  # Consumed by the sourced controller.
UI_LAYOUT=open UI_EN=0 UI_COLOR_OUT=0
open_output="$(render_home)"
grep -Fq '  1. 安全引导   预检+确认' <<<"$open_output" || fail 'open layout item format changed'
if grep -Eq 'Preflight only|│' <<<"$open_output"; then fail 'narrow open layout kept the English column or frame'; fi

# shellcheck disable=SC2034  # Consumed by the sourced controller.
UI_LAYOUT=framed UI_EN=1 UI_COLOR_OUT=0
plain_output="$(render_home)"
[[ "$plain_output" != *$'\033'* ]] || fail 'uncolored home screen contains an escape byte'
UI_COLOR_OUT=1
colored_output="$(render_home)"
[[ "$colored_output" == *$'\033['* ]] || fail 'colored home screen has no SGR sequence'
[ "$(sed $'s/\033\\[[0-9;]*m//g' <<<"$colored_output")" = "$plain_output" ] ||
  fail 'color changed home screen text or layout'
UI_COLOR_OUT=0

set_menu_facts 0 1 NEEDS_ROOT
grep -E '^│  1\. 安全引导 .*不可用  │$' <<<"$(render_home)" >/dev/null || fail 'unavailable item is not tagged'
grep -E '^│  7\. 能力诊断 .*只读  │$' <<<"$(render_home)" >/dev/null || fail 'diagnose is not available to non-root users'
# shellcheck disable=SC2034  # Consumed by the sourced controller.
HOME_FACTS_READY=0
( home_facts_collect && render_home >/dev/null ) || fail 'home fact collection failed on this host'
# shellcheck disable=SC2034  # Consumed by the sourced controller.
HOME_FACTS_READY=1

# Explicit actions without a terminal keep the legacy plain summary and plan.
# shellcheck disable=SC2034  # Consumed by the sourced controller.
UI_STYLED=0
# shellcheck disable=SC2034  # Consumed by the sourced controller.
DETECTED_PRETTY_NAME='Test OS 13' DETECTED_ARCH=x86_64 DETECTED_CPUS=1 DETECTED_MEMORY_MIB=1024
# shellcheck disable=SC2034  # Consumed by the sourced controller.
DETECTED_RESOURCE_CLASS=1C1GB DETECTED_LABEL='Debian 13 / 1 vCPU / 1 GiB'
# shellcheck disable=SC2034  # Consumed by the sourced controller.
STATE_PROFILE=debian13-1c1g STATE_VERSION=0.2.0-rc.3 STATE_PORT_SPEED_MBPS=200
# shellcheck disable=SC2034  # Consumed by the sourced controller.
ACTION=preflight PROFILE_FILE=debian13-1c1g-vps-tuning.sh PROFILE_SOURCE=local PROFILE_SHA256=abc
# shellcheck disable=SC2034  # Consumed by the sourced controller.
PORT_SPEED_MBPS_SELECTED=200
expected_plain=$'\nDebian VPS Tuning '"${CONTROLLER_VERSION}"$'\n\n检测结果：\n  系统：Test OS 13\n  架构：x86_64\n  CPU：1 vCPU\n  内存：1024 MiB\n  资源档：1C1GB\n  实现档位：Debian 13 / 1 vCPU / 1 GiB\n  已安装档位：debian13-1c1g\n  状态脚本版本：0.2.0-rc.3\n  已安装端口带宽：200 Mbps\n\n执行计划：\n  action：preflight\n  调用脚本：debian13-1c1g-vps-tuning.sh\n  脚本来源：local\n  SHA-256：abc\n  端口带宽：200 Mbps\n\nend'
[ "$({ print_environment_summary; print_execution_plan; printf 'end'; })" = "$expected_plain" ] ||
  fail 'plain summary or plan output changed'
# shellcheck disable=SC2034  # Consumed by the sourced controller.
UI_STYLED=1
styled_plan="$({ print_environment_summary; print_execution_plan; })"
for value in 'Test OS 13' x86_64 '1 vCPU' '1024 MiB' 1C1GB 'Debian 13 / 1 vCPU / 1 GiB' debian13-1c1g \
  0.2.0-rc.3 '200 Mbps' preflight debian13-1c1g-vps-tuning.sh local abc; do
  grep -Fq -- "$value" <<<"$styled_plan" || fail "styled summary lacks ${value}"
done

# Menu confirmations default to no, also at end of input, and rollback asks first.
confirm_case() {
  local action="$1" answer="$2" output
  output="$(
    # shellcheck disable=SC2329  # Invoked indirectly by sourced dispatch_action.
    run_profile() { printf 'RAN:%s\n' "$1"; }
    ACTION="$action" ACTION_FROM_MENU=1 DISPATCH_NOTE=''
    if [ "$answer" = '<eof>' ]; then dispatch_action </dev/null; else dispatch_action <<<"$answer"; fi
    printf '\nnote=%s' "$DISPATCH_NOTE"
  )" || fail "${action} confirmation exited non-zero"
  printf '%s' "$output"
}
for action in apply rollback reconfigure; do
  for answer in '' n '<eof>'; do
    output="$(confirm_case "$action" "$answer")"
    if grep -Fq 'RAN:' <<<"$output" || ! grep -Fq 'note=declined' <<<"$output"; then
      fail "${action} ran without confirmation (answer '${answer}')"
    fi
  done
  grep -Fq "RAN:${action}" <<<"$(confirm_case "$action" y)" || fail "${action} did not run after y"
done
cli_rollback_output="$(
  # shellcheck disable=SC2329  # Invoked indirectly by sourced dispatch_action.
  run_profile() { printf 'RAN:%s\n' "$1"; }
  ACTION=rollback ACTION_FROM_MENU=0
  dispatch_action </dev/null
)"
grep -Fq 'RAN:rollback' <<<"$cli_rollback_output" || fail 'CLI rollback gained a confirmation'

# Result page: rendered from the EXIT trap with the action's exit status intact.
result_case() {
  local action="$1" code="$2" note="${3:-}" rc=0 output
  output="$(bash -c '
    source "$1"
    UI_STYLED=1 UI_COLOR_OUT=0 ACTION="$2" DISPATCH_NOTE="$4" PORT_SPEED_MBPS_SELECTED=200
    trap on_exit EXIT
    RESULT_PENDING=1
    exit "$3"
  ' _ "$repo_root/debian-vps-tuning.sh" "$action" "$code" "$note")" || rc=$?
  [ "$rc" -eq "$code" ] || fail "result page changed exit status ${code} to ${rc}"
  printf '%s' "$output"
}
grep -Fq '失败（退出码 5：验证失败）' <<<"$(result_case verify 5)" || fail 'verify failure meaning'
grep -Fq '失败（退出码 2）' <<<"$(result_case htb 2)" || fail 'companion failures must show the number only'
grep -Fq '重启主机，重新登录后运行 dvt verify' <<<"$(result_case apply 0)" || fail 'apply next step'
grep -Fq 'dvt apply --port 200' <<<"$(result_case preflight 0)" || fail 'preflight next step'
grep -Fq '未执行（确认时已取消）' <<<"$(result_case rollback 0 declined)" || fail 'declined result'
# shellcheck disable=SC2034  # Consumed by the sourced controller.
UI_STYLED=0

no_tty_rc=0
no_tty_output="$(bash "$repo_root/debian-vps-tuning.sh" </dev/null 2>&1 >/dev/null)" || no_tty_rc=$?
[ "$no_tty_rc" -eq 2 ] || fail "no-terminal menu exit ${no_tty_rc}, expected 2"
[ "$(head -n1 <<<"$no_tty_output")" = '[x] 非交互环境必须明确指定 action。' ] || fail 'no-terminal first line changed'
grep -Fq 'ssh -t <host> dvt' <<<"$no_tty_output" || fail 'no-terminal guidance lacks ssh -t'

ACTION=''
ACTION_ARGS=()
parse_arguments probe --host probe.example --rate-cap 200 --yes
if [ "$ACTION" != probe ] || [ "${#ACTION_ARGS[@]}" -ne 5 ] ||
  [ "${ACTION_ARGS[0]}" != --host ] || [ "${ACTION_ARGS[1]}" != probe.example ] ||
  [ "${ACTION_ARGS[2]}" != --rate-cap ] || [ "${ACTION_ARGS[3]}" != 200 ] ||
  [ "${ACTION_ARGS[4]}" != --yes ]; then
  fail 'probe argument forwarding failed'
fi

ACTION=''
CLI_UPDATE_TAG=''
parse_arguments update --target v0.1.0-rc.17
if [ "$ACTION" != update ] || [ "$CLI_UPDATE_TAG" != v0.1.0-rc.17 ]; then
  fail 'update --target parsing failed'
fi

ACTION=''
CLI_PORT_SPEED_MBPS=''
parse_arguments reconfigure --port 500
if [ "$ACTION" != reconfigure ] || [ "$CLI_PORT_SPEED_MBPS" != 500 ]; then
  fail 'reconfigure --port parsing failed'
fi

PORT_SPEED_MBPS_SELECTED=''
choose_port_interactively <<<'' >/dev/null
[ "$PORT_SPEED_MBPS_SELECTED" -eq 200 ] || fail 'default interactive port is not 200 Mbps'
port_case() {
  (
    PORT_SPEED_MBPS_SELECTED=''
    choose_port_interactively <<<"$1" >/dev/null 2>&1
    printf 'port=%s' "$PORT_SPEED_MBPS_SELECTED"
  ) || true
}
[ "$(port_case $'9\n3')" = 'port=500' ] || fail 'invalid port choice did not re-prompt'
[ "$(port_case $'5\n0\n20000\n42')" = 'port=42' ] || fail 'invalid custom port did not re-prompt'
port_rc=0
port_output="$(choose_port_interactively <<<$'5\n0\nabc\n10001' 2>&1)" || port_rc=$?
if [ "$port_rc" -ne 2 ] || ! grep -Fq '带宽必须是 1–10000 的整数。' <<<"$port_output"; then
  fail 'three invalid custom ports did not stop with the original message'
fi

fixture="$test_root/profile.sh"
manifest="$test_root/SHA256SUMS"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fixture"
fixture_hash="$(sha256sum "$fixture" | awk '{print $1}')"
printf '%s  %s\n' "$fixture_hash" 'profile.sh' >"$manifest"
PROFILE_SHA256=''
verify_manifest_entry "$manifest" "$fixture" profile.sh || fail 'valid manifest entry was rejected'
[ "$PROFILE_SHA256" = "$fixture_hash" ] || fail 'verified hash was not recorded'

ACTION=probe
resolve_companion_assets
[ "$PROBE_PATH" = "${repo_root}/dvt-probe.sh" ] || fail 'local probe companion was not resolved'
ACTION=htb
resolve_companion_assets
[ "$HTB_WRAPPER_PATH" = "${repo_root}/dvt-htb.sh" ] || fail 'local HTB wrapper was not resolved'
[ "$HTB_BUNDLE_DIR" = "${repo_root}/experiments/htb-aggregate" ] || fail 'local HTB bundle was not resolved'

printf '%s  %s\n%s  %s\n' "$fixture_hash" profile.sh "$fixture_hash" profile.sh >"$manifest"
if verify_manifest_entry "$manifest" "$fixture" profile.sh; then
  fail 'duplicate manifest entries were accepted'
fi

printf '%064d  %s\n' 0 profile.sh >"$manifest"
if verify_manifest_entry "$manifest" "$fixture" profile.sh; then
  fail 'mismatched SHA-256 was accepted'
fi

capture="$test_root/capture"
runner="$test_root/runner.sh"
cat >"$runner" <<'EOF_RUNNER'
#!/usr/bin/env bash
printf '%s|%s\n' "${PORT_SPEED_MBPS:-unset}" "$1" >"$CAPTURE_FILE"
exit "${RUNNER_EXIT:-0}"
EOF_RUNNER
chmod 0700 "$runner"
export CAPTURE_FILE="$capture"
# shellcheck disable=SC2034  # Consumed by sourced run_profile.
PROFILE_PATH="$runner"
PORT_SPEED_MBPS_SELECTED=200
run_profile preflight
[ "$(<"$capture")" = '200|preflight' ] || fail 'preflight dispatch lost port/action'
run_profile reconfigure
[ "$(<"$capture")" = '200|reconfigure' ] || fail 'reconfigure dispatch lost port/action'
run_profile verify
[ "$(<"$capture")" = 'unset|verify' ] || fail 'verify dispatch unexpectedly injected a port'
run_profile diagnose
[ "$(<"$capture")" = 'unset|diagnose' ] || fail 'diagnose dispatch unexpectedly injected a port'
run_profile benchmark
[ "$(<"$capture")" = 'unset|benchmark' ] || fail 'benchmark dispatch unexpectedly injected a port'

RUNNER_EXIT=37
export RUNNER_EXIT
set +e
run_profile status
rc=$?
set -e
[ "$rc" -eq 37 ] || fail "profile exit code was changed: ${rc}"
unset RUNNER_EXIT

PROFILE_FILE='debian12-1c1g-vps-tuning.sh'
DETECTED_PROFILE='debian12-1c1g'
PROFILE_PATH=''
PROFILE_SOURCE=''
PROFILE_SHA256=''
TEMP_DIR=''
resolve_profile_script
[ "$PROFILE_SOURCE" = local ] || fail 'complete repository did not use local profile mode'
[ "$PROFILE_PATH" = "$repo_root/$PROFILE_FILE" ] || fail 'local profile path is incorrect'
[ -n "$PROFILE_SHA256" ] || fail 'local profile SHA-256 was not recorded'

mixed_dir="$test_root/mixed-release-assets"
mkdir "$mixed_dir"
cp "$repo_root/debian-vps-tuning.sh" "$mixed_dir/debian-vps-tuning-rc9.sh"
cp "$repo_root/$PROFILE_FILE" "$mixed_dir/$PROFILE_FILE"
mixed_profile_hash="$(sha256sum "$mixed_dir/$PROFILE_FILE" | awk '{print $1}')"
printf '%064d  %s\n%s  %s\n' \
  0 debian-vps-tuning.sh "$mixed_profile_hash" "$PROFILE_FILE" \
  >"$mixed_dir/SHA256SUMS"
# Re-source from the mixed directory so controller_directory resolves there.
# shellcheck source=/dev/null
source "$mixed_dir/debian-vps-tuning-rc9.sh"
PROFILE_FILE='debian12-1c1g-vps-tuning.sh'
DETECTED_PROFILE='debian12-1c1g'
mixed_network_fallback="$test_root/mixed-network-fallback"
curl() { : >"$mixed_network_fallback"; return 22; }
set +e
mixed_output="$(resolve_profile_script 2>&1)"
rc=$?
set -e
[ "$rc" -eq "$EXIT_INTEGRITY" ] ||
  fail "mixed Release assets returned ${rc}, expected ${EXIT_INTEGRITY}"
grep -Fq '可能混用了不同 Release 的资产' <<<"$mixed_output" ||
  fail 'mixed Release error did not explain the likely cause'
grep -Fq '独立临时目录' <<<"$mixed_output" ||
  fail 'mixed Release error did not provide directory isolation guidance'
[ ! -e "$mixed_network_fallback" ] ||
  fail 'mixed Release integrity failure fell back to the network'
unset -f curl
# Restore functions and constants from the repository controller.
# shellcheck source=debian-vps-tuning.sh
source "$repo_root/debian-vps-tuning.sh"

# shellcheck disable=SC2329  # Invoked indirectly by sourced download_file.
curl() { return 22; }
if download_file 'https://example.invalid/file' "$test_root/download" 2>/dev/null; then
  fail 'download failure was accepted'
fi
unset -f curl

remote_controller_dir="$test_root/remote-controller"
remote_fixture_dir="$test_root/remote-fixtures"
mkdir "$remote_controller_dir" "$remote_fixture_dir"
cp "$repo_root/debian-vps-tuning.sh" "$remote_controller_dir/controller.sh"
# Re-source the controller copy so BASH_SOURCE resolves to a directory without
# sibling profiles and exercises the remote branch.
# shellcheck source=/dev/null
source "$remote_controller_dir/controller.sh"

PROFILE_FILE='debian13-1c2g-vps-tuning.sh'
DETECTED_PROFILE='debian13-1c2g'
fixture_remote_profile="$remote_fixture_dir/$PROFILE_FILE"
fixture_remote_manifest="$remote_fixture_dir/SHA256SUMS"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "SCRIPT_VERSION='${CONTROLLER_VERSION}'" \
  "PROFILE_ID='${DETECTED_PROFILE}'" \
  'exit 0' >"$fixture_remote_profile"
remote_hash="$(sha256sum "$fixture_remote_profile" | awk '{print $1}')"
printf '%s  %s\n' "$remote_hash" "$PROFILE_FILE" >"$fixture_remote_manifest"

MOCK_DOWNLOAD_DIR="$test_root/download-success"
mktemp() {
  mkdir -p "$MOCK_DOWNLOAD_DIR"
  printf '%s\n' "$MOCK_DOWNLOAD_DIR"
}
# shellcheck disable=SC2329  # Invoked indirectly by sourced download_file.
curl() {
  local output='' url=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output) output="$2"; shift 2 ;;
      *) url="$1"; shift ;;
    esac
  done
  case "$url" in
    */SHA256SUMS) cp "$fixture_remote_manifest" "$output" ;;
    */"$PROFILE_FILE") cp "$fixture_remote_profile" "$output" ;;
    *) return 22 ;;
  esac
}

TEMP_DIR=''
PROFILE_PATH=''
PROFILE_SOURCE=''
PROFILE_SHA256=''
resolve_profile_script >/dev/null
[ "$PROFILE_SOURCE" = "release:$RELEASE_TAG" ] || fail 'remote profile source was not recorded'
[ "$PROFILE_SHA256" = "$remote_hash" ] || fail 'remote profile SHA-256 was not verified'
[ -s "$PROFILE_PATH" ] || fail 'remote profile was not downloaded'

printf '%s\n' '#!/usr/bin/env bash' 'exit 99' >"$fixture_remote_profile"
MOCK_DOWNLOAD_DIR="$test_root/download-mismatch"
set +e
( TEMP_DIR=''; PROFILE_PATH=''; PROFILE_SOURCE=''; PROFILE_SHA256=''; resolve_profile_script >/dev/null 2>&1 )
rc=$?
set -e
[ "$rc" -eq "$EXIT_INTEGRITY" ] || fail "remote hash mismatch returned ${rc}, expected ${EXIT_INTEGRITY}"

unset -f curl mktemp

update_log="$test_root/update.log"
source_runner="$test_root/source-profile.sh"
target_runner="$test_root/target-controller.sh"
cat >"$source_runner" <<'EOF_SOURCE_RUNNER'
#!/usr/bin/env bash
printf 'source:%s\n' "$*" >>"$UPDATE_TEST_LOG"
exit 0
EOF_SOURCE_RUNNER
cat >"$target_runner" <<'EOF_TARGET_RUNNER'
#!/usr/bin/env bash
printf 'target:%s:port=%s:update_preflight=%s\n' \
  "$*" "${PORT_SPEED_MBPS:-unset}" "${UPDATE_PREFLIGHT:-unset}" >>"$UPDATE_TEST_LOG"
exit 0
EOF_TARGET_RUNNER
chmod 0700 "$source_runner" "$target_runner"
export UPDATE_TEST_LOG="$update_log"
resolve_update_release() { UPDATE_TAG_SELECTED='v0.1.0-rc.17'; }
resolve_installed_profile() { SOURCE_PROFILE_PATH="$source_runner"; SOURCE_PROFILE_SHA256='source-hash'; }
resolve_update_controller() { UPDATE_CONTROLLER_PATH="$target_runner"; UPDATE_CONTROLLER_SHA256='target-hash'; }
STATE_PROFILE='debian12-1c1g'
STATE_VERSION='0.1.0-rc.12'
STATE_PORT_SPEED_MBPS=200
update_output="$(run_update)"
expected_update_log=$'source:verify\ntarget:preflight --port 200:port=200:update_preflight=1'
[ "$(<"$update_log")" = "$expected_update_log" ] || fail 'read-only update check sequence changed'
grep -Fq '升级检查通过；系统配置未修改。' <<<"$update_output" ||
  fail 'update did not report its read-only result'
if grep -Eq '(^|:)(rollback|apply)( |:|$)' "$update_log"; then
  fail 'read-only update invoked a mutating action'
fi
unset UPDATE_TEST_LOG

printf 'controller checks passed\n'
