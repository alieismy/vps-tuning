#!/usr/bin/env bash
# Debian VPS Tuning controller. Selects and verifies one generated profile.

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

CONTROLLER_VERSION='0.2.0-rc.3'
RELEASE_TAG='v0.2.0-rc.3'
REPOSITORY='alieismy/debian-vps-tuning'
RELEASE_BASE_URL="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}"

STATE_FILE='/var/lib/proxy-vps-tuning/state.json'
DEFAULT_PORT_SPEED_MBPS=200
MIN_PORT_SPEED_MBPS=1
MAX_PORT_SPEED_MBPS=10000

EXIT_USAGE=2
EXIT_UNSUPPORTED=3
EXIT_CONFLICT=4
EXIT_DOWNLOAD=10
EXIT_INTEGRITY=11

ACTION=''
ACTION_FROM_MENU=0
CLI_PORT_SPEED_MBPS=''
PORT_SPEED_MBPS_SELECTED=''
DETECTED_PROFILE=''
DETECTED_LABEL=''
DETECTED_PRETTY_NAME=''
DETECTED_MEMORY_MIB=''
DETECTED_ARCH=''
DETECTED_CPUS=''
DETECTED_RESOURCE_CLASS=''
STATE_PROFILE=''
STATE_VERSION=''
STATE_PORT_SPEED_MBPS=''
PROFILE_FILE=''
PROFILE_PATH=''
PROFILE_SHA256=''
PROFILE_SOURCE=''
TEMP_DIR=''
UPDATE_TEMP_DIR=''
CLI_UPDATE_TAG=''
UPDATE_TAG_SELECTED=''
UPDATE_CONTROLLER_PATH=''
UPDATE_CONTROLLER_SHA256=''
SOURCE_PROFILE_PATH=''
SOURCE_PROFILE_SHA256=''
ACTION_ARGS=()
PROBE_PATH=''
HTB_WRAPPER_PATH=''
HTB_BUNDLE_DIR=''
TRAFFIC_BUDGET_PATH=''
MIGRATION_PATH=''
MEASUREMENT_PATH=''

# Presentation state. Rendering never changes dispatch, gates or exit codes;
# see docs/interactive-cli-design.md for the layout and width contract.
UI_STYLED=0
UI_COLOR_OUT=0
UI_COLOR_ERR=0
UI_ASCII=0
UI_LAYOUT='framed'
UI_EN=1
UI_COLS=80
UI_INNER=64
UI_H='─' UI_V='│' UI_TL='┌' UI_TR='┐' UI_BL='└' UI_BR='┘' UI_LT='├' UI_RT='┤'
UI_STEP='▸'
UI_CHOICE=''
RESULT_PENDING=0
DISPATCH_NOTE=''
HOME_FACTS_READY=0
HOME_ROOT=0
HOME_PLATFORM_OK=0
HOME_PLATFORM_REASON=''
HOME_OS=''
HOME_ARCH=''
HOME_CPUS=''
HOME_MEMORY_MIB=''
HOME_PROFILE=''
HOME_RESOURCE_CLASS=''
HOME_STATE=''
HOME_STATE_VERSION=''
HOME_STATE_PORT=''
HOME_STATE_UPDATED=''
HOME_RUNTIME=''
HOME_BLOCKER=''
HOME_DEFAULT=''

info() {
  if [ "$UI_COLOR_OUT" -eq 1 ]; then printf '\033[32m[+]\033[0m %s\n' "$*"; else printf '[+] %s\n' "$*"; fi
}
warn() {
  if [ "$UI_COLOR_ERR" -eq 1 ]; then printf '\033[33m[!]\033[0m %s\n' "$*" >&2; else printf '[!] %s\n' "$*" >&2; fi
}
error() {
  if [ "$UI_COLOR_ERR" -eq 1 ]; then printf '\033[31m[x]\033[0m %s\n' "$*" >&2; else printf '[x] %s\n' "$*" >&2; fi
}
die() { local code="$1"; shift; error "$*"; exit "$code"; }

cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf -- "$TEMP_DIR"
  fi
  if [ -n "$UPDATE_TEMP_DIR" ] && [ -d "$UPDATE_TEMP_DIR" ]; then
    rm -rf -- "$UPDATE_TEMP_DIR"
  fi
}

on_exit() {
  local rc=$?
  if [ "$RESULT_PENDING" -eq 1 ]; then
    RESULT_PENDING=0
    render_result "$rc" || true
  fi
  cleanup
}

usage() {
  cat <<'EOF_USAGE'
Usage:
  debian-vps-tuning.sh
  debian-vps-tuning.sh {guided|preflight|apply|reconfigure|verify|status|diagnose|measure|htb-sweep|report|probe|benchmark|htb|update|migrate|rollback|recover} [options]

Options:
  --port MBPS    provider port cap for guided/preflight/apply; default 200;
                 required explicitly by CLI reconfigure
  --target TAG    update target, for example v0.2.0-rc.3; default is the
                  highest non-draft Release in the installed major.minor line;
                  stable installations ignore prereleases automatically
  -h, --help     show this help
  --version      show controller and pinned release versions

Behavior:
  - diagnose uses Linux capabilities without a managed profile; use
    diagnose --managed for the legacy profile-specific incremental diagnostics.
  - measure automatically selects a public iperf3 endpoint; requires an explicit
    test rate cap and a shared traffic budget. It does not change sysctl/qdisc.
    Use "measure --rate-cap 20 --plan-only" for a network-free preview.
  - report --input-dir PATH verifies and displays independent measurement evidence.
  - htb-sweep temporarily shapes all egress traffic on an explicitly selected
    interface; requires a recoverable root fq and restores it before completion.
  - With a terminal and no action, shows an interactive menu. The menu runs
    one action and exits; write and rollback confirmations default to no.
  - Without a terminal, an explicit action is required.
  - NO_COLOR (non-empty) disables color; DVT_ASCII=1 draws ASCII frames for
    terminals that render box-drawing characters as double width.
  - guided runs preflight first and asks before apply.
  - reconfigure changes only the managed provider port/buffer state. It requires
    an existing VERIFIED state for the same version/profile and preserves RTT,
    qdisc, swap, journald and NOFILE configuration.
  - benchmark requires BENCHMARK_HOST and an existing iperf3 server; it changes
    no system configuration but deliberately generates high-bandwidth traffic.
  - probe requires an explicitly authorized iperf3 server, enforces an
    application rate cap, repeats samples and emits advisory-only evidence.
  - htb wraps the existing non-persistent Debian 13 / 200 Mbps experiment;
    use "htb --help" for its narrower scope and stage gates.
  - update is read-only: it verifies the source and target Release assets, runs
    source verify and target update-preflight, then prints a manual handoff plan.
  - migrate uses a persistent checkpoint and two explicit reboot gates. Start
    with "migrate prepare --checkpoint /absolute/new/path".
  - recover restores an interrupted reconfigure transaction, or performs the
    advanced rc.2 empty-state recovery when explicitly acknowledged.

The controller supports Debian 12/13 and Ubuntu 24.04 LTS on x86_64/aarch64.
It preserves existing Debian profiles and selects adaptive profiles for new
resource combinations (at least 384 MiB RAM). It invokes one verified script.
EOF_USAGE
}

is_interactive_terminal() { [ -t 0 ] && [ -t 1 ]; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "$EXIT_UNSUPPORTED" '请在 root shell 中运行；本项目命令不需要 sudo。'
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "$EXIT_UNSUPPORTED" "缺少必要命令：$1"
}

validate_port_speed() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#$value))
  [ "$value" -ge "$MIN_PORT_SPEED_MBPS" ] && [ "$value" -le "$MAX_PORT_SPEED_MBPS" ]
}

profile_metadata() {
  case "$1" in
    debian12-adaptive) printf '%s\t%s\n' 'debian12-adaptive-vps-tuning.sh' 'Debian 12 / adaptive' ;;
    debian13-adaptive) printf '%s\t%s\n' 'debian13-adaptive-vps-tuning.sh' 'Debian 13 / adaptive' ;;
    ubuntu2404-adaptive) printf '%s\t%s\n' 'ubuntu2404-adaptive-vps-tuning.sh' 'Ubuntu 24.04 LTS / adaptive' ;;
    debian12-1c512m)
      printf '%s\t%s\n' 'debian12-1c512m-vps-tuning.sh' 'Debian 12 / 1 vCPU / 512 MiB'
      ;;
    debian12-1c1g)
      printf '%s\t%s\n' 'debian12-1c1g-vps-tuning.sh' 'Debian 12 / 1 vCPU / 1 GiB'
      ;;
    debian12-1c2g)
      printf '%s\t%s\n' 'debian12-1c2g-vps-tuning.sh' 'Debian 12 / 1–2 vCPU / 2 GiB'
      ;;
    debian13-1c512m)
      printf '%s\t%s\n' 'debian13-1c512m-vps-tuning.sh' 'Debian 13 / 1 vCPU / 512 MiB'
      ;;
    debian13-1c1g)
      printf '%s\t%s\n' 'debian13-1c1g-vps-tuning.sh' 'Debian 13 / 1 vCPU / 1 GiB'
      ;;
    debian13-1c2g)
      printf '%s\t%s\n' 'debian13-1c2g-vps-tuning.sh' 'Debian 13 / 1–2 vCPU / 2 GiB'
      ;;
    *) return 1 ;;
  esac
}

os_release_values() {
  # /etc/os-release is specified as shell-compatible variable assignments.
  # shellcheck disable=SC1090
  (set +u; . "$1"; printf '%s\t%s\t%s' "${ID:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-unknown}")
}

detect_profile_from() {
  local os_release_file="$1" meminfo_file="$2" arch="$3" cpus="$4"
  local os_id version_id pretty_name os_values mem_mib profile label metadata resource_class

  [ -r "$os_release_file" ] || return 1
  [ -r "$meminfo_file" ] || return 1

  os_values="$(os_release_values "$os_release_file")"
  IFS=$'\t' read -r os_id version_id pretty_name <<<"$os_values"
  case "$os_id:$version_id" in debian:12 | debian:13 | ubuntu:24.04) ;; *) return 2 ;; esac
  case "$arch" in x86_64 | aarch64) ;; *) return 2 ;; esac
  [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || return 1

  mem_mib="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024; found=1} END {if (!found) exit 1}' "$meminfo_file")" || return 1
  [[ "$mem_mib" =~ ^[0-9]+$ ]] || return 1

  [ "$mem_mib" -ge 384 ] || return 3
  if [ "$os_id" = ubuntu ]; then
    profile='ubuntu2404-adaptive'
    resource_class='adaptive'
  elif [ "$cpus" -eq 1 ] && [ "$mem_mib" -ge 384 ] && [ "$mem_mib" -le 767 ]; then
    profile="debian${version_id}-1c512m"
    resource_class='1C512MB'
  elif [ "$cpus" -eq 1 ] && [ "$mem_mib" -ge 768 ] && [ "$mem_mib" -le 1535 ]; then
    profile="debian${version_id}-1c1g"
    resource_class='1C1GB'
  elif [ "$cpus" -eq 1 ] && [ "$mem_mib" -ge 1536 ] && [ "$mem_mib" -le 3072 ]; then
    profile="debian${version_id}-1c2g"
    resource_class='1C2GB'
  elif [ "$cpus" -eq 2 ] && [ "$mem_mib" -ge 1536 ] && [ "$mem_mib" -le 3072 ]; then
    profile="debian${version_id}-1c2g"
    resource_class='2C2GB'
  else
    profile="debian${version_id}-adaptive"
    resource_class='adaptive'
  fi

  metadata="$(profile_metadata "$profile")" || return 1
  IFS=$'\t' read -r _ label <<<"$metadata"
  printf '%s\t%s\t%s\t%s\t%s\n' "$profile" "$label" "$pretty_name" "$mem_mib" "$resource_class"
}

# Shared by detect_environment (fatal) and the menu home screen (display only).
environment_error_message() {
  local rc="$1" arch="$2" cpus="$3" mem_mib="$4"
  case "$rc" in
    1) printf '%s' '无法读取或解析 /etc/os-release、/proc/meminfo 或可用逻辑 CPU 数。' ;;
    2) printf '%s' "支持 Debian 12/13、Ubuntu 24.04 LTS 和 x86_64/aarch64；检测到架构 ${arch}。" ;;
    3) printf '%s' "需要至少 384 MiB RAM；检测到 ${cpus} vCPU、${mem_mib} MiB RAM。" ;;
    *) printf '%s' '环境检测发生未知错误。' ;;
  esac
}

detect_environment() {
  local detected rc metadata
  DETECTED_ARCH="$(uname -m)"
  DETECTED_CPUS="$(nproc 2>/dev/null || printf '?')"
  DETECTED_MEMORY_MIB="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024; found=1} END {if (!found) exit 1}' /proc/meminfo 2>/dev/null || printf '?')"
  set +e
  detected="$(detect_profile_from /etc/os-release /proc/meminfo "$DETECTED_ARCH" "$DETECTED_CPUS")"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] ||
    die "$EXIT_UNSUPPORTED" "$(environment_error_message "$rc" "$DETECTED_ARCH" "$DETECTED_CPUS" "$DETECTED_MEMORY_MIB")"
  IFS=$'\t' read -r DETECTED_PROFILE DETECTED_LABEL DETECTED_PRETTY_NAME DETECTED_MEMORY_MIB DETECTED_RESOURCE_CLASS <<<"$detected"
  metadata="$(profile_metadata "$DETECTED_PROFILE")" || die "$EXIT_UNSUPPORTED" '无法映射资源档位。'
  IFS=$'\t' read -r PROFILE_FILE _ <<<"$metadata"
}

read_existing_state() {
  [ -e "$STATE_FILE" ] || return 0
  need_command jq
  if ! jq -e 'type == "object" and (.profile.id | type == "string")' "$STATE_FILE" >/dev/null 2>&1; then
    warn "检测到不可解析的状态文件：${STATE_FILE}；将由目标脚本给出恢复诊断。"
    return 0
  fi
  STATE_PROFILE="$(jq -r '.profile.id' "$STATE_FILE")"
  STATE_VERSION="$(jq -r '.script_version // "unknown"' "$STATE_FILE")"
  STATE_PORT_SPEED_MBPS="$(jq -r '.network.port_speed_mbps // empty' "$STATE_FILE")"
  profile_metadata "$STATE_PROFILE" >/dev/null 2>&1 || die "$EXIT_CONFLICT" "状态文件包含未知档位：${STATE_PROFILE}"
  state_profile_matches_detected "$DETECTED_PROFILE" "$STATE_PROFILE" ||
    die "$EXIT_CONFLICT" "当前检测档位 ${DETECTED_PROFILE} 与已安装状态档位 ${STATE_PROFILE} 不一致；拒绝自动选择脚本。"
}

state_profile_matches_detected() { [ "$1" = "$2" ]; }

parse_arguments() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      guided | preflight | apply | reconfigure | verify | status | benchmark | update | rollback | recover)
        [ -z "$ACTION" ] || die "$EXIT_USAGE" '只能指定一个 action。'
        ACTION="$1"
        ;;
      probe | htb | migrate | diagnose | measure | htb-sweep | report)
        [ -z "$ACTION" ] || die "$EXIT_USAGE" '只能指定一个 action。'
        ACTION="$1"
        shift
        ACTION_ARGS=("$@")
        break
        ;;
      --port)
        [ "$#" -ge 2 ] || die "$EXIT_USAGE" '--port 缺少数值。'
        CLI_PORT_SPEED_MBPS="$2"
        shift
        ;;
      --port=*) CLI_PORT_SPEED_MBPS="${1#*=}" ;;
      --target)
        [ "$#" -ge 2 ] || die "$EXIT_USAGE" '--target 缺少 Release tag。'
        CLI_UPDATE_TAG="$2"
        shift
        ;;
      --target=*) CLI_UPDATE_TAG="${1#*=}" ;;
      -h | --help) usage; exit 0 ;;
      --version)
        printf 'controller=%s release=%s\n' "$CONTROLLER_VERSION" "$RELEASE_TAG"
        exit 0
        ;;
      *) die "$EXIT_USAGE" "未知参数：$1" ;;
    esac
    shift
  done
}

ui_init() {
  local term="${TERM:-}" size cols
  UI_STYLED=0 UI_COLOR_OUT=0 UI_COLOR_ERR=0 UI_ASCII=0 UI_LAYOUT='framed' UI_EN=1 UI_COLS=80
  if [ -t 1 ]; then UI_STYLED=1; fi
  case "$term" in '' | dumb | linux) UI_ASCII=1 UI_LAYOUT='open' ;; esac
  if [ -n "${DVT_ASCII:-}" ]; then UI_ASCII=1; fi
  # https://no-color.org/: any non-empty NO_COLOR disables color.
  if [ -z "${NO_COLOR:-}" ] && [ -n "$term" ] && [ "$term" != dumb ]; then
    if [ -t 1 ]; then UI_COLOR_OUT=1; fi
    if [ -t 2 ]; then UI_COLOR_ERR=1; fi
  fi
  if size="$(stty size 2>/dev/null </dev/tty)"; then
    cols="${size##* }"
    if [[ "$cols" =~ ^[1-9][0-9]{0,3}$ ]]; then UI_COLS="$cols"; fi
  fi
  if [ "$UI_COLS" -lt $((UI_INNER + 2)) ]; then UI_LAYOUT='open'; fi
  if [ "$UI_LAYOUT" = open ] && [ "$UI_COLS" -lt 62 ]; then UI_EN=0; fi
  if [ "$UI_ASCII" -eq 1 ]; then
    UI_H='-' UI_V='|' UI_TL='+' UI_TR='+' UI_BL='+' UI_BR='+' UI_LT='+' UI_RT='+' UI_STEP='>'
  else
    UI_H='─' UI_V='│' UI_TL='┌' UI_TR='┐' UI_BL='└' UI_BR='┘' UI_LT='├' UI_RT='┤' UI_STEP='▸'
  fi
}

# Prints the display width of a frame string. Bytes are classified directly,
# so neither the locale nor awk multibyte support matters, and East Asian
# Ambiguous characters count as narrow (UAX #11). Returns 1 when the string
# contains a character outside the frame character set.
ui_width() {
  printf '%s' "$1" | od -An -v -tu1 | awk '
    { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }
    END {
      w = 0; bad = 0
      for (i = 0; i < n;) {
        c = b[i]
        if (c >= 32 && c <= 126) { w++; i++; continue }
        c1 = (i + 1 < n) ? b[i + 1] : -1; c2 = (i + 2 < n) ? b[i + 2] : -1
        if (c1 < 128 || c1 > 191 || c2 < 128 || c2 > 191) { bad = 1; w++; i++; continue }
        if (c == 226 && c1 == 148) w += 1
        else if (c == 227 && c1 == 128) w += 2
        else if ((c == 228 && c1 >= 184) || (c >= 229 && c <= 233)) w += 2
        else if (c == 239 && ((c1 == 188 && c2 >= 129) || (c1 == 189 && c2 <= 160))) w += 2
        else { bad = 1; w++ }
        i += 3
      }
      print w
      exit bad
    }'
}

# ui_measure VAR TEXT: fork-free display width for rendering. ASCII and the
# eight box-drawing characters take one column; every other character allowed
# in frames is 3-byte UTF-8 CJK taking two. Bytes are counted in the C locale
# so the user's locale does not matter. ui_width enforces the character set.
ui_measure() {
  local LC_ALL=C ui_measure_rest="$2" ui_measure_ascii ui_measure_glyph
  for ui_measure_glyph in ─ │ ┌ ┐ └ ┘ ├ ┤; do
    ui_measure_rest="${ui_measure_rest//"$ui_measure_glyph"/}"
  done
  ui_measure_ascii="${ui_measure_rest//[!\ -~]/}"
  printf -v "$1" '%d' $((${#ui_measure_ascii} + (${#2} - ${#ui_measure_rest}) / 3 + (${#ui_measure_rest} - ${#ui_measure_ascii}) / 3 * 2))
}

# ui_pad VAR TEXT COLS [right]
ui_pad() {
  local ui_pad_width ui_pad_fill
  ui_measure ui_pad_width "$2"
  ui_pad_fill=$(($3 > ui_pad_width ? $3 - ui_pad_width : 0))
  if [ "${4:-}" = right ]; then
    printf -v "$1" '%*s%s' "$ui_pad_fill" '' "$2"
  else
    printf -v "$1" '%s%*s' "$2" "$ui_pad_fill" ''
  fi
}

# ui_paint VAR SGR TEXT: colored only when stdout color is enabled.
ui_paint() {
  if [ "$UI_COLOR_OUT" -eq 1 ] && [ -n "$2" ] && [ -n "$3" ]; then
    printf -v "$1" '\033[%sm%s\033[0m' "$2" "$3"
  else
    printf -v "$1" '%s' "$3"
  fi
}

# ui_repeat VAR CHAR COUNT
ui_repeat() {
  local ui_repeat_text=''
  if [ "$3" -gt 0 ]; then printf -v ui_repeat_text '%*s' "$3" ''; fi
  printf -v "$1" '%s' "${ui_repeat_text// /$2}"
}

# ui_rule top|mid|bottom [TITLE] [RIGHT]: a 66-column frame rule; titles are
# embedded in the rule so groups do not cost extra rows.
ui_rule() {
  local kind="$1" title="${2:-}" right_text="${3:-}" left right head='' tail='' used fill shown
  if [ "$UI_LAYOUT" = open ]; then
    ui_paint shown 1 "$title"
    case "$kind" in
      top) printf '%s%s\n' "$shown" "${right_text:+  $right_text}" ;;
      mid) printf '%s %s\n' "${UI_H}${UI_H}" "$shown" ;;
    esac
    return 0
  fi
  case "$kind" in
    top) left="$UI_TL" right="$UI_TR" ;;
    mid) left="$UI_LT" right="$UI_RT" ;;
    *) left="$UI_BL" right="$UI_BR" ;;
  esac
  [ -z "$title" ] || head="${UI_H} ${title} "
  [ -z "$right_text" ] || tail=" ${right_text} ${UI_H}"
  ui_measure used "${head}${tail}"
  ui_repeat fill "$UI_H" $((UI_INNER - used))
  if [ -n "$title" ]; then
    ui_paint shown 1 "$title"
    head="${UI_H} ${shown} "
  fi
  printf '%s%s%s%s%s\n' "$left" "$head" "$fill" "$tail" "$right"
}

# ui_tag_color VAR TAG: SGR color for a side-effect tag; text carries meaning.
ui_tag_color() {
  case "$2" in
    只读 | 预检+确认) printf -v "$1" '32' ;;
    写入 | '写入 重启') printf -v "$1" '33' ;;
    '只读 联网') printf -v "$1" '36' ;;
    流量 | '写入 流量') printf -v "$1" '35' ;;
    不可用) printf -v "$1" '2' ;;
    *) printf -v "$1" '' ;;
  esac
}

# ui_item KEY CN EN TAG: key, Chinese name (10 columns), English name
# (35 ASCII columns) and a right-aligned side-effect tag (10 columns).
ui_item() {
  local key cn en="$3" tag="$4" color padded shown
  ui_tag_color color "$tag"
  ui_pad cn "$2" 10
  ui_paint key 1 "$1"
  ui_paint shown "$color" "$tag"
  if [ "$UI_LAYOUT" = open ]; then
    if [ "$UI_EN" -eq 1 ]; then printf -v en '%-35s ' "$en"; else en=''; fi
    printf '  %s. %s %s%s\n' "$key" "$cn" "$en" "$shown"
    return 0
  fi
  printf -v en '%-35s' "$en"
  ui_pad padded "$tag" 10 right
  padded="${padded%"$tag"}${shown}"
  printf '%s  %s. %s %s %s  %s\n' "$UI_V" "$key" "$cn" "$en" "$padded" "$UI_V"
}

# ui_kv LABEL VALUE [COLS]: label padded so values align; at least one space.
ui_kv() {
  local label
  ui_pad label "$1" $((${3:-11} - 1))
  printf '  %s %s\n' "$label" "$2"
}

ui_section() {
  local head used fill
  head="${UI_H}${UI_H} $1 "
  ui_measure used "$head"
  ui_repeat fill "$UI_H" $((57 - used))
  ui_paint head 1 "$head"
  printf '\n%s%s\n' "$head" "$fill"
}

ui_step() {
  local mark
  ui_paint mark 36 "$UI_STEP"
  printf '\n%s %s\n' "$mark" "$1"
}

ui_notice() {
  local mark
  ui_paint mark 33 '[!]'
  printf '%s %s\n' "$mark" "$1"
}

# Display-only sanitizer for external strings shown outside frames.
ui_clean() {
  local text="${1//[[:cntrl:]]/}"
  if [ "${#text}" -gt "$2" ]; then text="${text:0:$(($2 - 3))}..."; fi
  printf '%s' "$text"
}

# Collects home-screen facts without network, writes, root or die. Every value
# is validated before display; anything else falls back to a placeholder.
# Tests may preset HOME_* and HOME_FACTS_READY=1.
home_facts_collect() {
  local values pretty='' detected rc state_line kernel cc='' qdisc='' iface kind
  [ "$HOME_FACTS_READY" -eq 0 ] || return 0
  HOME_ROOT=0
  if [ "$(id -u 2>/dev/null || printf 1)" = 0 ]; then HOME_ROOT=1; fi
  HOME_ARCH="$(uname -m 2>/dev/null || true)"
  [[ "$HOME_ARCH" =~ ^[A-Za-z0-9_]{1,16}$ ]] || HOME_ARCH=''
  HOME_CPUS="$(nproc 2>/dev/null || true)"
  [[ "$HOME_CPUS" =~ ^[1-9][0-9]{0,4}$ ]] || HOME_CPUS=''
  HOME_MEMORY_MIB="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024; found=1} END {if (!found) exit 1}' /proc/meminfo 2>/dev/null || true)"
  [[ "$HOME_MEMORY_MIB" =~ ^[0-9]{1,9}$ ]] || HOME_MEMORY_MIB=''
  if [ -r /etc/os-release ] && values="$(os_release_values /etc/os-release 2>/dev/null)"; then
    IFS=$'\t' read -r _ _ pretty <<<"$values"
  fi
  HOME_OS="$(ui_clean "$pretty" 48)"

  HOME_PLATFORM_OK=0 HOME_PLATFORM_REASON='' HOME_PROFILE='' HOME_RESOURCE_CLASS=''
  if detected="$(detect_profile_from /etc/os-release /proc/meminfo "${HOME_ARCH:-unknown}" "${HOME_CPUS:-?}" 2>/dev/null)"; then
    IFS=$'\t' read -r HOME_PROFILE _ _ _ HOME_RESOURCE_CLASS <<<"$detected"
    HOME_PLATFORM_OK=1
  else
    rc=$?
    HOME_PLATFORM_REASON="$(environment_error_message "$rc" "${HOME_ARCH:-unknown}" "${HOME_CPUS:-?}" "${HOME_MEMORY_MIB:-?}")"
  fi

  HOME_STATE='' HOME_STATE_VERSION='' HOME_STATE_PORT='' HOME_STATE_UPDATED=''
  if [ "$HOME_ROOT" -ne 1 ]; then
    HOME_STATE='NEEDS_ROOT'
  elif [ ! -e "$STATE_FILE" ]; then
    HOME_STATE='UNMANAGED'
  elif ! command -v jq >/dev/null 2>&1; then
    HOME_STATE='NEEDS_JQ'
  elif state_line="$(jq -r '[.state, .script_version, .network.port_speed_mbps, .timestamps.last_update] |
      map(if . == null then "" else tostring end) | join("|")' "$STATE_FILE" 2>/dev/null)"; then
    IFS='|' read -r HOME_STATE HOME_STATE_VERSION HOME_STATE_PORT HOME_STATE_UPDATED <<<"$state_line"
    case "$HOME_STATE" in
      PREPARED | APPLYING | APPLIED | VERIFIED | DEGRADED | ROLLBACK_PENDING | SWAP_RETAINED | RECONFIGURING) ;;
      *) HOME_STATE='INVALID' ;;
    esac
    [[ "$HOME_STATE_VERSION" =~ ^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}(-rc\.[0-9]{1,9})?$ ]] || HOME_STATE_VERSION=''
    [[ "$HOME_STATE_PORT" =~ ^[0-9]{1,5}$ ]] || HOME_STATE_PORT=''
    [[ "$HOME_STATE_UPDATED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || HOME_STATE_UPDATED=''
  else
    HOME_STATE='INVALID'
  fi

  kernel="$(uname -r 2>/dev/null || true)"
  [[ "$kernel" =~ ^[A-Za-z0-9._+~-]{1,64}$ ]] || kernel='不可用'
  { read -r cc </proc/sys/net/ipv4/tcp_congestion_control; } 2>/dev/null || true
  { read -r qdisc </proc/sys/net/core/default_qdisc; } 2>/dev/null || true
  [[ "$cc" =~ ^[a-z0-9_]{1,16}$ ]] || cc='不可用'
  [[ "$qdisc" =~ ^[a-z0-9_]{1,16}$ ]] || qdisc='不可用'
  iface="$({ ip -o -4 route show default; ip -o -6 route show default; } 2>/dev/null |
    awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}' || true)"
  if [[ "$iface" =~ ^[A-Za-z0-9._@-]{1,15}$ ]]; then
    kind="$(tc qdisc show dev "$iface" 2>/dev/null | awk '$1 == "qdisc" && / root / {print $2; exit}' || true)"
    [[ "$kind" =~ ^[a-z_]{1,16}$ ]] || kind='不可用'
    iface="${iface} root=${kind}"
  else
    iface='默认路由 不可用'
  fi
  HOME_RUNTIME="${kernel} · cc=${cc} · default_qdisc=${qdisc} · ${iface}"
  HOME_FACTS_READY=1
}

# Sets HOME_BLOCKER to why a menu entry cannot run on this host, or ''. Only
# presentation: the real refusals stay in need_root and detect_environment.
home_blocker() {
  HOME_BLOCKER=''
  case "$1" in 1 | 2 | 3 | 4 | 5 | 6 | 8 | 9 | htb) ;; *) return 0 ;; esac
  if [ "$HOME_ROOT" -ne 1 ]; then
    HOME_BLOCKER='当前用户不是 root；请在 root shell 中运行（本项目命令不需要 sudo）。'
  elif [ "$HOME_PLATFORM_OK" -ne 1 ]; then
    HOME_BLOCKER="当前平台不受支持：${HOME_PLATFORM_REASON}"
  fi
}

# The default is the first read-only action that fits the recorded state.
home_default_key() {
  if [ "$HOME_ROOT" -ne 1 ] || [ "$HOME_PLATFORM_OK" -ne 1 ]; then
    HOME_DEFAULT=7
    return 0
  fi
  case "$HOME_STATE" in
    UNMANAGED) HOME_DEFAULT=1 ;;
    APPLIED) HOME_DEFAULT=5 ;;
    *) HOME_DEFAULT=6 ;;
  esac
}

home_item() {
  home_blocker "$1"
  if [ -n "$HOME_BLOCKER" ]; then ui_item "$1" "$2" "$3" '不可用'; else ui_item "$@"; fi
}

render_home() {
  local record shown color
  printf '\n'
  ui_rule top 'dvt  Debian VPS Tuning' "$RELEASE_TAG"
  ui_rule mid '配置 Configure'
  home_item 1 '安全引导' 'Guided: preflight, then confirm' '预检+确认'
  home_item 2 '只读预检' 'Preflight only' '只读'
  home_item 3 '应用配置' 'Apply persistent tuning' '写入 重启'
  home_item 4 '修改带宽' 'Reconfigure provider port speed' '写入'
  ui_rule mid '检查 Inspect'
  home_item 5 '验证配置' 'Verify managed configuration' '只读'
  home_item 6 '查看状态' 'Status and recorded state' '只读'
  home_item 7 '能力诊断' 'Diagnose (no profile needed)' '只读'
  ui_rule mid '维护 Maintain'
  home_item 8 '检查升级' 'Update check and handoff plan' '只读 联网'
  home_item 9 '回滚' 'Rollback managed changes' '写入'
  ui_item a '高级与测量' 'Advanced and measurement' '子菜单'
  ui_item 0 '退出' 'Exit' ''
  ui_rule bottom

  ui_kv '主机' "${HOME_OS:-未知} · ${HOME_ARCH:-未知} · ${HOME_CPUS:-?} vCPU · ${HOME_MEMORY_MIB:-?} MiB" 9
  if [ "$HOME_PLATFORM_OK" -eq 1 ]; then
    ui_kv '档位' "${HOME_PROFILE}（${HOME_RESOURCE_CLASS}）" 9
  else
    ui_kv '档位' "不支持：${HOME_PLATFORM_REASON}" 9
  fi
  case "$HOME_STATE" in
    UNMANAGED) record='无（UNMANAGED）' ;;
    NEEDS_ROOT) record='需 root 读取' ;;
    NEEDS_JQ) record='需 jq 解析' ;;
    INVALID) record='无法解析，请运行 dvt status' ;;
    *)
      case "$HOME_STATE" in VERIFIED) color=32 ;; DEGRADED | ROLLBACK_PENDING) color=31 ;; *) color=33 ;; esac
      ui_paint shown "$color" "$HOME_STATE"
      record="$shown"
      [ -z "$HOME_STATE_VERSION" ] || record+=" · ${HOME_STATE_VERSION}"
      [ -z "$HOME_STATE_PORT" ] || record+=" · ${HOME_STATE_PORT} Mbps"
      [ -z "$HOME_STATE_UPDATED" ] || record+=" · 更新 ${HOME_STATE_UPDATED}"
      ;;
  esac
  ui_kv '受管记录' "$record" 9
  ui_kv '运行值' "${HOME_RUNTIME:-不可用}" 9

  if [ "$HOME_ROOT" -ne 1 ]; then
    ui_notice '当前用户不是 root，只有 7 可用；a 可查看命令参考。'
  elif [ "$HOME_PLATFORM_OK" -ne 1 ]; then
    ui_notice '当前平台不受支持，只有 7 可用；a 可查看命令参考。'
  else
    case "$HOME_STATE" in
      APPLIED) ui_notice '受管记录为 APPLIED：重启主机后运行 5 验证配置。' ;;
      PREPARED | APPLYING | DEGRADED | ROLLBACK_PENDING | SWAP_RETAINED | RECONFIGURING | INVALID)
        ui_notice '普通 verify/rollback/apply 可能拒绝执行；先运行 6 查看状态，再按 docs/usage.md 处理。'
        ;;
    esac
  fi
  printf '\n'
}

ui_reference() {
  local tag color shown
  ui_pad tag "$1" 10
  ui_tag_color color "$1"
  ui_paint shown "$color" "$1"
  printf '  %s%s\n' "${shown}${tag#"$1"}" "$2"
}

render_advanced() {
  local tag='子菜单'
  home_blocker htb
  [ -z "$HOME_BLOCKER" ] || tag='不可用'
  printf '\n'
  ui_rule top '高级与测量 Advanced' "$RELEASE_TAG"
  ui_item 1 'HTB 实验' 'HTB trial: Debian 13 / 200 Mbps' "$tag"
  ui_item 0 '返回' 'Back to main menu' ''
  ui_rule bottom
  printf '  命令参考：以下操作需要参数，请在命令行运行。\n'
  printf '  此处只列主要参数；完整参数见 dvt --help 与 docs/usage.md。\n'
  ui_reference '只读' 'dvt measure --rate-cap N --plan-only'
  ui_reference '流量' 'dvt measure --rate-cap N --ledger PATH --window-id ID ...'
  ui_reference '写入 流量' 'dvt htb-sweep --interface IF --lower N --upper N ...'
  ui_reference '只读' 'dvt report --input-dir PATH'
  ui_reference '流量' 'dvt probe --host HOST --ledger PATH --window-id ID'
  ui_reference '流量' 'BENCHMARK_HOST=HOST dvt benchmark'
  ui_reference '写入 重启' 'dvt migrate prepare --checkpoint /absolute/new/path'
  ui_reference '写入' 'dvt recover'
  ui_reference '只读' 'dvt diagnose --managed'
  printf '\n'
}

# read_choice PROMPT PATTERN DEFAULT: reads one line into UI_CHOICE. Returns 0
# for a matching answer, 1 at end of input and 2 otherwise. Invalid input is
# never echoed back.
read_choice() {
  local answer=''
  printf '%s' "$1"
  if ! IFS= read -r answer && [ -z "$answer" ]; then
    printf '\n'
    return 1
  fi
  UI_CHOICE="${answer:-$3}"
  [[ "$UI_CHOICE" =~ $2 ]] || return 2
}

choose_action_interactively() {
  local page=home tries=0 rc key
  home_facts_collect
  home_default_key
  render_home
  while :; do
    if [ "$page" = home ]; then
      if read_choice "请选择 / Select [0-9,a] [${HOME_DEFAULT}]: " '^([0-9]|[aA])$' "$HOME_DEFAULT"; then rc=0; else rc=$?; fi
    else
      if read_choice '请选择 / Select [0-1] [0]: ' '^[01]$' 0; then rc=0; else rc=$?; fi
    fi
    if [ "$rc" -eq 1 ]; then
      info '未执行任何操作。'
      exit 0
    fi
    if [ "$rc" -eq 2 ]; then
      tries=$((tries + 1))
      [ "$tries" -lt 3 ] || die "$EXIT_USAGE" '无效操作选择。'
      if [ "$page" = home ]; then warn '无效选择；请输入 0-9 或 a。'; else warn '无效选择；请输入 0 或 1。'; fi
      continue
    fi
    key="$UI_CHOICE"
    if [ "$page" = advanced ]; then
      if [ "$key" = 0 ]; then
        page=home
        render_home
        continue
      fi
      key=htb
    fi
    case "$key" in
      0)
        info '未执行任何操作。'
        exit 0
        ;;
      a | A)
        page=advanced
        render_advanced
        continue
        ;;
    esac
    home_blocker "$key"
    if [ -n "$HOME_BLOCKER" ]; then
      warn "该项当前不可用：${HOME_BLOCKER}"
      continue
    fi
    case "$key" in
      1) ACTION='guided' ;;
      2) ACTION='preflight' ;;
      3) ACTION='apply' ;;
      4) ACTION='reconfigure' ;;
      5) ACTION='verify' ;;
      6) ACTION='status' ;;
      7) ACTION='diagnose' ;;
      8) ACTION='update' ;;
      9) ACTION='rollback' ;;
      htb) ACTION='htb' ;;
    esac
    break
  done
  ACTION_FROM_MENU=1
}

choose_port_interactively() {
  local tries=0 rc
  ui_step '服务商端口带宽（用于推导 socket 缓冲上限，不产生流量）'
  printf '    1. 100 Mbps    2. 200 Mbps（默认）    3. 500 Mbps\n'
  printf '    4. 1000 Mbps   5. 自定义 1-10000\n'
  while :; do
    if read_choice '请选择 [2]: ' '^[1-5]$' 2; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 1 ]; then
      info '未执行任何操作。'
      exit 0
    fi
    [ "$rc" -eq 2 ] || break
    tries=$((tries + 1))
    [ "$tries" -lt 3 ] || die "$EXIT_USAGE" '无效带宽选择。'
    warn '无效选择；请输入 1-5。'
  done
  case "$UI_CHOICE" in
    1) PORT_SPEED_MBPS_SELECTED=100 ;;
    2) PORT_SPEED_MBPS_SELECTED=200 ;;
    3) PORT_SPEED_MBPS_SELECTED=500 ;;
    4) PORT_SPEED_MBPS_SELECTED=1000 ;;
    5)
      tries=0
      while :; do
        if read_choice '请输入 1-10000 的整数: ' '^[0-9]{1,5}$' ''; then rc=0; else rc=$?; fi
        if [ "$rc" -eq 1 ]; then
          info '未执行任何操作。'
          exit 0
        fi
        if [ "$rc" -eq 0 ] && validate_port_speed "$UI_CHOICE"; then break; fi
        tries=$((tries + 1))
        [ "$tries" -lt 3 ] || die "$EXIT_USAGE" '带宽必须是 1–10000 的整数。'
        warn '带宽必须是 1-10000 的整数；请重新输入。'
      done
      PORT_SPEED_MBPS_SELECTED=$((10#$UI_CHOICE))
      ;;
  esac
}

no_terminal_guidance() {
  error '非交互环境必须明确指定 action。'
  printf '    远程执行请分配终端：ssh -t <host> dvt\n' >&2
  printf '    自动化请直接指定 action，例如：dvt preflight --port 200；dvt verify\n' >&2
  printf '    全部 action：dvt --help\n' >&2
  exit "$EXIT_USAGE"
}

select_port_speed() {
  if [ -n "$CLI_UPDATE_TAG" ] && [ "$ACTION" != 'update' ]; then
    die "$EXIT_USAGE" '--target 只能与 update 一起使用。'
  fi
  case "$ACTION" in
    guided | preflight | apply | reconfigure) ;;
    *)
      [ -z "$CLI_PORT_SPEED_MBPS" ] || die "$EXIT_USAGE" "${ACTION} 不接受 --port；它使用现有状态。"
      return 0
      ;;
  esac

  if [ "$ACTION" = 'reconfigure' ]; then
    if [ "$ACTION_FROM_MENU" -eq 1 ]; then
      choose_port_interactively
    else
      [ -n "$CLI_PORT_SPEED_MBPS" ] ||
        die "$EXIT_USAGE" 'reconfigure 必须显式使用 --port <MBPS>；不会采用默认值或 PORT_SPEED_MBPS 环境变量。'
      validate_port_speed "$CLI_PORT_SPEED_MBPS" || die "$EXIT_USAGE" '带宽必须是 1–10000 的整数。'
      PORT_SPEED_MBPS_SELECTED=$((10#$CLI_PORT_SPEED_MBPS))
    fi
    return 0
  fi

  if [ -n "$CLI_PORT_SPEED_MBPS" ]; then
    validate_port_speed "$CLI_PORT_SPEED_MBPS" || die "$EXIT_USAGE" '带宽必须是 1–10000 的整数。'
    PORT_SPEED_MBPS_SELECTED=$((10#$CLI_PORT_SPEED_MBPS))
  elif [ -n "${PORT_SPEED_MBPS:-}" ]; then
    validate_port_speed "$PORT_SPEED_MBPS" || die "$EXIT_USAGE" 'PORT_SPEED_MBPS 必须是 1–10000 的整数。'
    PORT_SPEED_MBPS_SELECTED=$((10#$PORT_SPEED_MBPS))
  elif [ "$ACTION" = 'apply' ] && [ -n "$STATE_PROFILE" ]; then
    validate_port_speed "$STATE_PORT_SPEED_MBPS" ||
      die "$EXIT_CONFLICT" '已安装状态缺少有效的端口带宽；请执行 status/diagnose 并人工检查状态。'
    PORT_SPEED_MBPS_SELECTED=$((10#$STATE_PORT_SPEED_MBPS))
  elif is_interactive_terminal; then
    choose_port_interactively
  else
    PORT_SPEED_MBPS_SELECTED=$DEFAULT_PORT_SPEED_MBPS
  fi
}

parse_release_version() {
  local value="${1#v}" stable rc part
  if [[ "$value" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-rc\.([0-9]+))?$ ]]; then
    for part in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}"; do
      [ -z "$part" ] && continue
      [ "${#part}" -le 9 ] || return 1
      [ "$part" = '0' ] || [[ "$part" != 0* ]] || return 1
    done
    if [ -n "${BASH_REMATCH[4]}" ]; then stable=0; rc="$((10#${BASH_REMATCH[5]}))"; else stable=1; rc=0; fi
    printf '%d\t%d\t%d\t%d\t%d\n' \
      "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" \
      "$((10#${BASH_REMATCH[3]}))" "$stable" "$rc"
    return 0
  fi
  return 1
}

release_is_newer() {
  local candidate current c_major c_minor c_patch c_stable c_rc o_major o_minor o_patch o_stable o_rc
  candidate="$(parse_release_version "$1")" || return 2
  current="$(parse_release_version "$2")" || return 2
  IFS=$'\t' read -r c_major c_minor c_patch c_stable c_rc <<<"$candidate"
  IFS=$'\t' read -r o_major o_minor o_patch o_stable o_rc <<<"$current"
  [ "$c_major" -gt "$o_major" ] && return 0
  [ "$c_major" -lt "$o_major" ] && return 1
  [ "$c_minor" -gt "$o_minor" ] && return 0
  [ "$c_minor" -lt "$o_minor" ] && return 1
  [ "$c_patch" -gt "$o_patch" ] && return 0
  [ "$c_patch" -lt "$o_patch" ] && return 1
  [ "$c_stable" -gt "$o_stable" ] && return 0
  [ "$c_stable" -lt "$o_stable" ] && return 1
  [ "$c_rc" -gt "$o_rc" ]
}

verify_manifest_entry() {
  local manifest="$1" file_path="$2" logical_name="$3"
  local count expected actual
  [ -s "$manifest" ] && [ -s "$file_path" ] || return 1
  count="$(awk -v name="$logical_name" '$2 == name {count++} END {print count+0}' "$manifest")"
  [ "$count" -eq 1 ] || return 1
  expected="$(awk -v name="$logical_name" '$2 == name {print $1; exit}' "$manifest")"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  actual="$(sha256sum "$file_path" | awk '{print $1}')"
  [ "${actual,,}" = "${expected,,}" ] || return 1
  PROFILE_SHA256="${actual,,}"
}

verify_profile_contract() {
  local file_path="$1"
  grep -Fq "SCRIPT_VERSION='${CONTROLLER_VERSION}'" "$file_path" &&
    grep -Fq "PROFILE_ID='${DETECTED_PROFILE}'" "$file_path"
}

controller_directory() {
  local source_path="${BASH_SOURCE[0]}"
  if [[ "$source_path" != /* ]]; then source_path="${PWD}/${source_path}"; fi
  cd -- "$(dirname -- "$source_path")" 2>/dev/null && pwd -P
}

download_file() {
  local url="$1" output="$2"
  curl --fail --show-error --silent --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 120 --max-redirs 5 \
    --remove-on-error --output "$output" "$url"
}

select_highest_release_tag() {
  local releases_json="$1" current_version="${2:-$CONTROLLER_VERSION}"
  local tag best='' candidate parsed current_parsed current_major current_minor current_stable tag_major tag_minor tag_stable
  current_parsed="$(parse_release_version "$current_version")" || return 1
  IFS=$'\t' read -r current_major current_minor _ current_stable _ <<<"$current_parsed"
  while IFS= read -r tag; do
    parsed="$(parse_release_version "$tag")" || continue
    IFS=$'\t' read -r tag_major tag_minor _ tag_stable _ <<<"$parsed"
    if [ "$tag_major" -ne "$current_major" ] || [ "$tag_minor" -ne "$current_minor" ]; then
      continue
    fi
    [ "$current_stable" -eq 0 ] || [ "$tag_stable" -eq 1 ] || continue
    if [ -z "$best" ] || release_is_newer "$tag" "$best"; then
      best="$tag"
    fi
  done < <(jq -r '.[] | select(.draft == false) | .tag_name // empty' "$releases_json")
  [ -n "$best" ] || return 1
  candidate="${best#v}"
  printf 'v%s\n' "$candidate"
}

resolve_update_release() {
  local releases_json requested
  [ -n "$STATE_PROFILE" ] || die "$EXIT_CONFLICT" '当前没有已安装的管理状态；update 只用于升级已应用的配置。'
  parse_release_version "$STATE_VERSION" >/dev/null 2>&1 ||
    die "$EXIT_CONFLICT" "状态版本无法参与安全升级比较：${STATE_VERSION}"
  need_command curl
  need_command jq
  need_command sha256sum
  umask 077
  UPDATE_TEMP_DIR="$(mktemp -d)" || die "$EXIT_DOWNLOAD" '无法创建 update 临时目录。'

  requested="${CLI_UPDATE_TAG:-${UPDATE_TAG:-}}"
  if [ -n "$requested" ]; then
    parse_release_version "$requested" >/dev/null 2>&1 ||
      die "$EXIT_USAGE" '目标 Release 必须符合 vMAJOR.MINOR.PATCH 或 vMAJOR.MINOR.PATCH-rc.N。'
    UPDATE_TAG_SELECTED="v${requested#v}"
  else
    releases_json="${UPDATE_TEMP_DIR}/releases.json"
    if [[ "$STATE_VERSION" == *-rc.* ]]; then
      info '查询 GitHub Releases（rc 通道接受更高 rc 或同版本线稳定版）。'
    else
      info '查询 GitHub Releases（稳定通道自动排除 prerelease）。'
    fi
    curl --fail --show-error --silent --location \
      --proto '=https' --proto-redir '=https' \
      --connect-timeout 15 --max-time 120 --max-redirs 5 \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --remove-on-error --output "$releases_json" \
      "https://api.github.com/repos/${REPOSITORY}/releases?per_page=30" ||
      die "$EXIT_DOWNLOAD" '无法查询 GitHub Releases；可用 --target 显式指定目标 tag。'
    jq -e 'type == "array"' "$releases_json" >/dev/null 2>&1 ||
      die "$EXIT_DOWNLOAD" 'GitHub Releases 响应不是预期的 JSON 数组。'
    UPDATE_TAG_SELECTED="$(select_highest_release_tag "$releases_json" "$STATE_VERSION")" ||
      die "$EXIT_DOWNLOAD" '没有找到同一 major.minor 发布线且符合项目版本格式的非草稿 Release。'
  fi

  if ! release_is_newer "$UPDATE_TAG_SELECTED" "$STATE_VERSION"; then
    if [ "${UPDATE_TAG_SELECTED#v}" = "${STATE_VERSION#v}" ]; then
      info "当前已是目标版本：${STATE_VERSION}"
      UPDATE_TAG_SELECTED=''
      return 0
    fi
    die "$EXIT_CONFLICT" "目标版本 ${UPDATE_TAG_SELECTED} 不高于已安装版本 ${STATE_VERSION}；拒绝降级或重复迁移。"
  fi
}

resolve_update_controller() {
  local target_base manifest expected_version
  target_base="https://github.com/${REPOSITORY}/releases/download/${UPDATE_TAG_SELECTED}"
  manifest="${UPDATE_TEMP_DIR}/SHA256SUMS"
  UPDATE_CONTROLLER_PATH="${UPDATE_TEMP_DIR}/debian-vps-tuning.sh"
  info "下载目标发布清单：${UPDATE_TAG_SELECTED}/SHA256SUMS"
  download_file "${target_base}/SHA256SUMS" "$manifest" ||
    die "$EXIT_DOWNLOAD" "无法下载目标发布清单：${UPDATE_TAG_SELECTED}"
  info "下载目标总控脚本：${UPDATE_TAG_SELECTED}/debian-vps-tuning.sh"
  download_file "${target_base}/debian-vps-tuning.sh" "$UPDATE_CONTROLLER_PATH" ||
    die "$EXIT_DOWNLOAD" "无法下载目标总控脚本：${UPDATE_TAG_SELECTED}"
  PROFILE_SHA256=''
  verify_manifest_entry "$manifest" "$UPDATE_CONTROLLER_PATH" 'debian-vps-tuning.sh' ||
    die "$EXIT_INTEGRITY" "目标总控脚本未通过 SHA-256 校验：${UPDATE_TAG_SELECTED}"
  UPDATE_CONTROLLER_SHA256="$PROFILE_SHA256"
  expected_version="${UPDATE_TAG_SELECTED#v}"
  if ! grep -Fq "CONTROLLER_VERSION='${expected_version}'" "$UPDATE_CONTROLLER_PATH" ||
    ! grep -Fq "RELEASE_TAG='${UPDATE_TAG_SELECTED}'" "$UPDATE_CONTROLLER_PATH"; then
    die "$EXIT_INTEGRITY" '目标总控脚本的版本或 Release tag 契约不匹配。'
  fi
  chmod 0700 "$UPDATE_CONTROLLER_PATH"
}

resolve_installed_profile() {
  local source_tag source_base manifest expected_version
  expected_version="${STATE_VERSION#v}"
  source_tag="v${expected_version}"
  if [ "$expected_version" = "$CONTROLLER_VERSION" ]; then
    resolve_profile_script
    SOURCE_PROFILE_PATH="$PROFILE_PATH"
    SOURCE_PROFILE_SHA256="$PROFILE_SHA256"
    return 0
  fi

  source_base="https://github.com/${REPOSITORY}/releases/download/${source_tag}"
  manifest="${UPDATE_TEMP_DIR}/source-SHA256SUMS"
  SOURCE_PROFILE_PATH="${UPDATE_TEMP_DIR}/source-${PROFILE_FILE}"
  info "下载已安装版本清单：${source_tag}/SHA256SUMS"
  download_file "${source_base}/SHA256SUMS" "$manifest" ||
    die "$EXIT_DOWNLOAD" "无法下载已安装版本清单：${source_tag}"
  info "下载已安装版本档位脚本：${source_tag}/${PROFILE_FILE}"
  download_file "${source_base}/${PROFILE_FILE}" "$SOURCE_PROFILE_PATH" ||
    die "$EXIT_DOWNLOAD" "无法下载已安装版本档位脚本：${source_tag}/${PROFILE_FILE}"
  PROFILE_SHA256=''
  verify_manifest_entry "$manifest" "$SOURCE_PROFILE_PATH" "$PROFILE_FILE" ||
    die "$EXIT_INTEGRITY" "已安装版本档位脚本未通过 SHA-256 校验：${source_tag}/${PROFILE_FILE}"
  SOURCE_PROFILE_SHA256="$PROFILE_SHA256"
  if ! grep -Fq "SCRIPT_VERSION='${expected_version}'" "$SOURCE_PROFILE_PATH" ||
    ! grep -Fq "PROFILE_ID='${STATE_PROFILE}'" "$SOURCE_PROFILE_PATH"; then
    die "$EXIT_INTEGRITY" '已安装版本档位脚本的版本或 profile 契约不匹配。'
  fi
  chmod 0700 "$SOURCE_PROFILE_PATH"
}

resolve_profile_script() {
  local local_dir local_manifest local_profile controller_source remote_manifest
  need_command sha256sum
  local_dir="$(controller_directory)"
  local_manifest="${local_dir}/SHA256SUMS"
  local_profile="${local_dir}/${PROFILE_FILE}"
  controller_source="${BASH_SOURCE[0]}"
  if [[ "$controller_source" != /* ]]; then controller_source="${PWD}/${controller_source}"; fi

  if [ -f "$local_manifest" ] && [ -f "$local_profile" ]; then
    verify_manifest_entry "$local_manifest" "$controller_source" 'debian-vps-tuning.sh' ||
      die "$EXIT_INTEGRITY" "检测到同目录 SHA256SUMS 和 ${PROFILE_FILE}，但当前总控不属于该清单；可能混用了不同 Release 的资产。请为每个版本使用独立临时目录；拒绝使用同目录 profile，也不会回退联网下载。"
    verify_manifest_entry "$local_manifest" "$local_profile" "$PROFILE_FILE" ||
      die "$EXIT_INTEGRITY" "本地 profile 未通过同目录清单校验：${PROFILE_FILE}；可能混用了不同 Release 的资产。请为每个版本使用独立临时目录。"
    verify_profile_contract "$local_profile" ||
      die "$EXIT_INTEGRITY" "本地 profile 的版本或档位契约不匹配：${PROFILE_FILE}；请确认总控、SHA256SUMS 和 profile 来自同一 Release。"
    PROFILE_PATH="$local_profile"
    PROFILE_SOURCE='local'
    return 0
  fi

  need_command curl
  umask 077
  TEMP_DIR="$(mktemp -d)" || die "$EXIT_DOWNLOAD" '无法创建临时目录。'
  remote_manifest="${TEMP_DIR}/SHA256SUMS"
  PROFILE_PATH="${TEMP_DIR}/${PROFILE_FILE}"

  info "下载固定发布清单：${RELEASE_TAG}/SHA256SUMS"
  download_file "${RELEASE_BASE_URL}/SHA256SUMS" "$remote_manifest" ||
    die "$EXIT_DOWNLOAD" "无法下载固定发布清单；没有回退到 master/latest：${RELEASE_TAG}"
  info "下载固定档位脚本：${RELEASE_TAG}/${PROFILE_FILE}"
  download_file "${RELEASE_BASE_URL}/${PROFILE_FILE}" "$PROFILE_PATH" ||
    die "$EXIT_DOWNLOAD" "无法下载固定档位脚本；没有执行任何配置：${PROFILE_FILE}"
  verify_manifest_entry "$remote_manifest" "$PROFILE_PATH" "$PROFILE_FILE" ||
    die "$EXIT_INTEGRITY" "远程档位脚本未通过 SHA-256 校验：${PROFILE_FILE}"
  verify_profile_contract "$PROFILE_PATH" ||
    die "$EXIT_INTEGRITY" "远程脚本的版本或档位契约不匹配：${PROFILE_FILE}"
  chmod 0700 "$PROFILE_PATH"
  PROFILE_SOURCE="release:${RELEASE_TAG}"
}

resolve_companion_assets() {
  local local_dir local_manifest controller_source manifest logical source target remote_name
  local -a required=(dvt-traffic-budget.sh)
  case "$ACTION" in
    diagnose | measure | htb-sweep | report) required=(dvt-measure.py dvt-measure-runtime.sh dvt_htb_transaction.py measurement-endpoints.json dvt-traffic-budget.sh) ;;
  esac
  [ "$ACTION" != probe ] || required=(dvt-traffic-budget.sh dvt-probe.sh)
  [ "$ACTION" != migrate ] || required=(dvt-migrate.sh)
  [ "$ACTION" != htb ] || required=(
    dvt-traffic-budget.sh
    dvt-htb.sh
    experiments/htb-aggregate/experiment-plan.sh
    experiments/htb-aggregate/htb-aggregate-experiment.sh
    experiments/htb-aggregate/rate-sweep-plan.sh
    experiments/htb-aggregate/rate-sweep-run.sh
    experiments/htb-aggregate/rate-sweep-analyze.sh
  )
  local_dir="$(controller_directory)"
  local_manifest="${local_dir}/SHA256SUMS"
  controller_source="${BASH_SOURCE[0]}"
  if [[ "$controller_source" != /* ]]; then controller_source="${PWD}/${controller_source}"; fi
  case "$ACTION" in
    diagnose | measure | htb-sweep | report)
      [ -f "$local_manifest" ] || die "$EXIT_INTEGRITY" '独立诊断/测量需要完整的同版本本地 bundle；此入口不会下载缺失资产。'
      ;;
  esac
  if [ -f "$local_manifest" ]; then
    verify_manifest_entry "$local_manifest" "$controller_source" debian-vps-tuning.sh ||
      die "$EXIT_INTEGRITY" '同目录 companion 资产存在，但总控不属于该 SHA256SUMS。'
    for logical in "${required[@]}"; do
      source="${local_dir}/${logical}"
      [ -f "$source" ] && [ ! -L "$source" ] || die "$EXIT_INTEGRITY" "同目录 Release 缺少 companion 资产：${logical}"
      verify_manifest_entry "$local_manifest" "$source" "$logical" ||
        die "$EXIT_INTEGRITY" "companion 资产未通过 SHA-256 校验：${logical}"
    done
    PROBE_PATH="${local_dir}/dvt-probe.sh"
    TRAFFIC_BUDGET_PATH="${local_dir}/dvt-traffic-budget.sh"
    HTB_WRAPPER_PATH="${local_dir}/dvt-htb.sh"
    HTB_BUNDLE_DIR="${local_dir}/experiments/htb-aggregate"
    MIGRATION_PATH="${local_dir}/dvt-migrate.sh"
    MEASUREMENT_PATH="${local_dir}/dvt-measure.py"
    return 0
  fi

  need_command curl
  if [ -z "$TEMP_DIR" ]; then TEMP_DIR="$(mktemp -d)" || die "$EXIT_DOWNLOAD" '无法创建 companion 临时目录。'; fi
  manifest="${TEMP_DIR}/SHA256SUMS"
  if [ ! -f "$manifest" ]; then
    download_file "${RELEASE_BASE_URL}/SHA256SUMS" "$manifest" ||
      die "$EXIT_DOWNLOAD" '无法下载固定 companion 发布清单。'
  fi
  for logical in "${required[@]}"; do
    target="${TEMP_DIR}/${logical}"
    mkdir -p -- "$(dirname "$target")"
    remote_name="$(basename "$logical")"
    download_file "${RELEASE_BASE_URL}/${remote_name}" "$target" ||
      die "$EXIT_DOWNLOAD" "无法下载固定 companion 资产：${remote_name}"
    verify_manifest_entry "$manifest" "$target" "$logical" ||
      die "$EXIT_INTEGRITY" "远程 companion 资产未通过 SHA-256 校验：${logical}"
    chmod 0700 "$target"
  done
  PROBE_PATH="${TEMP_DIR}/dvt-probe.sh"
  TRAFFIC_BUDGET_PATH="${TEMP_DIR}/dvt-traffic-budget.sh"
  HTB_WRAPPER_PATH="${TEMP_DIR}/dvt-htb.sh"
  HTB_BUNDLE_DIR="${TEMP_DIR}/experiments/htb-aggregate"
  MIGRATION_PATH="${TEMP_DIR}/dvt-migrate.sh"
  MEASUREMENT_PATH="${TEMP_DIR}/dvt-measure.py"
}

print_environment_summary() {
  if [ "$UI_STYLED" -eq 1 ]; then
    ui_section "检测结果（Debian VPS Tuning ${CONTROLLER_VERSION}）"
    ui_kv '系统' "$DETECTED_PRETTY_NAME" 15
    ui_kv '架构' "$DETECTED_ARCH" 15
    ui_kv 'CPU' "${DETECTED_CPUS} vCPU" 15
    ui_kv '内存' "${DETECTED_MEMORY_MIB} MiB" 15
    ui_kv '资源档' "$DETECTED_RESOURCE_CLASS" 15
    ui_kv '实现档位' "$DETECTED_LABEL" 15
    if [ -n "$STATE_PROFILE" ]; then
      ui_kv '已安装档位' "$STATE_PROFILE" 15
      ui_kv '状态脚本版本' "$STATE_VERSION" 15
      [ -z "$STATE_PORT_SPEED_MBPS" ] || ui_kv '已安装端口带宽' "${STATE_PORT_SPEED_MBPS} Mbps" 15
    fi
    return 0
  fi
  printf '\nDebian VPS Tuning %s\n\n' "$CONTROLLER_VERSION"
  printf '检测结果：\n'
  printf '  系统：%s\n' "$DETECTED_PRETTY_NAME"
  printf '  架构：%s\n' "$DETECTED_ARCH"
  printf '  CPU：%s vCPU\n' "$DETECTED_CPUS"
  printf '  内存：%s MiB\n' "$DETECTED_MEMORY_MIB"
  printf '  资源档：%s\n' "$DETECTED_RESOURCE_CLASS"
  printf '  实现档位：%s\n' "$DETECTED_LABEL"
  if [ -n "$STATE_PROFILE" ]; then
    printf '  已安装档位：%s\n' "$STATE_PROFILE"
    printf '  状态脚本版本：%s\n' "$STATE_VERSION"
    [ -z "$STATE_PORT_SPEED_MBPS" ] || printf '  已安装端口带宽：%s Mbps\n' "$STATE_PORT_SPEED_MBPS"
  fi
}

print_execution_plan() {
  if [ "$UI_STYLED" -eq 1 ]; then
    ui_section '执行计划'
    ui_kv 'action' "$ACTION" 15
    ui_kv '调用脚本' "$PROFILE_FILE" 15
    ui_kv '脚本来源' "$PROFILE_SOURCE" 15
    ui_kv 'SHA-256' "$PROFILE_SHA256" 15
    case "$ACTION" in
      guided | preflight | apply)
        ui_kv '端口带宽' "${PORT_SPEED_MBPS_SELECTED} Mbps" 15
        ;;
      reconfigure)
        ui_kv '已安装端口带宽' "${STATE_PORT_SPEED_MBPS:-unknown} Mbps" 15
        ui_kv '目标端口带宽' "${PORT_SPEED_MBPS_SELECTED} Mbps" 15
        ui_kv '变更边界' '只更新本项目 sysctl 管理文件、必要的 socket buffer 运行值和状态；不重建 qdisc' 15
        ;;
    esac
    printf '\n'
    return 0
  fi
  printf '\n执行计划：\n'
  printf '  action：%s\n' "$ACTION"
  printf '  调用脚本：%s\n' "$PROFILE_FILE"
  printf '  脚本来源：%s\n' "$PROFILE_SOURCE"
  printf '  SHA-256：%s\n' "$PROFILE_SHA256"
  case "$ACTION" in
    guided | preflight | apply)
      printf '  端口带宽：%s Mbps\n' "$PORT_SPEED_MBPS_SELECTED"
      ;;
    reconfigure)
      printf '  已安装端口带宽：%s Mbps\n' "${STATE_PORT_SPEED_MBPS:-unknown}"
      printf '  目标端口带宽：%s Mbps\n' "$PORT_SPEED_MBPS_SELECTED"
      printf '  变更边界：只更新本项目 sysctl 管理文件、必要的 socket buffer 运行值和状态；不重建 qdisc\n'
      ;;
  esac
  printf '\n'
}

# Reads one answer; only y/Y/yes/YES confirm, so Enter and EOF mean no.
confirm_answer() {
  local answer=''
  printf '%s' "$1"
  if ! IFS= read -r answer; then printf '\n'; fi
  case "$answer" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

# Confirmation page facts come from the controller only; the write scope
# itself is reported by the profile, not restated here.
confirm_write_page() {
  ui_section '确认写入'
  ui_kv '操作' 'apply（写入持久配置）'
  ui_kv '档位' "${DETECTED_PROFILE}  ${DETECTED_LABEL}"
  ui_kv '端口带宽' "${PORT_SPEED_MBPS_SELECTED} Mbps"
  ui_kv '脚本' "${PROFILE_FILE}（来源：${PROFILE_SOURCE}）"
  ui_kv 'SHA-256' "$PROFILE_SHA256"
  if [ "$1" = guided ]; then
    ui_kv '写入范围' '以上方 preflight 输出为准；若其报告可迁移的厂商 fq/bbr 基线，'
    ui_kv '' 'apply 会先完整备份 /etc/sysctl.conf 再迁移对应定义'
  else
    ui_kv '写入范围' '由 profile 在执行时判定并输出；只读查看请改用菜单 1 或 2'
  fi
  ui_kv '完成条件' 'apply 成功后重启，重新登录后运行 dvt verify'
}

confirm_apply() {
  is_interactive_terminal || return 1
  if [ "$UI_STYLED" -eq 1 ]; then
    confirm_write_page guided
  else
    printf 'apply 将写入系统配置；若 preflight 报告可迁移的厂商 fq/bbr 基线，还会先完整备份并迁移 /etc/sysctl.conf 中对应定义。\n'
  fi
  confirm_answer 'preflight 已通过。是否执行 apply？[y/N]：'
}

exit_code_meaning() {
  case "$1" in
    2) printf '用法或输入错误' ;;
    3) printf '环境不支持' ;;
    4) printf '状态或所有权冲突' ;;
    5) printf '验证失败' ;;
    6) printf '回滚不完整' ;;
    10) printf '下载失败' ;;
    11) printf '完整性校验失败' ;;
    130) printf '已中断' ;;
    143) printf '已终止' ;;
  esac
}

# Result page for menu-dispatched actions, rendered from the EXIT trap so the
# action keeps its errexit semantics and exit status.
render_result() {
  local rc="$1" status meaning='' next=''
  [ "$UI_STYLED" -eq 1 ] || return 0
  ui_section '结果'
  if [ "$rc" -eq 0 ] && [ "$DISPATCH_NOTE" = declined ]; then
    ui_kv "$ACTION" '未执行（确认时已取消）'
    ui_kv '下一步' '没有写入；需要时重新运行 dvt'
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    ui_paint status 32 '成功'
    ui_kv "$ACTION" "${status}（退出码 0）"
    case "$ACTION" in
      guided | apply) next='若上方显示“应用完成”，重启主机，重新登录后运行 dvt verify' ;;
      preflight) next="确认写入范围后运行 dvt apply --port ${PORT_SPEED_MBPS_SELECTED}，或在菜单中选 3" ;;
      reconfigure) next='运行 dvt status 查看新的端口带宽记录' ;;
      update) next='按上方计划和 docs/migration.md 执行；update 本身没有改动受管配置' ;;
    esac
  else
    # Companion tools reuse 2 for several failures, so only controller and
    # profile actions get a meaning.
    case "$ACTION" in
      guided | preflight | apply | reconfigure | verify | status | rollback | update) meaning="$(exit_code_meaning "$rc")" ;;
    esac
    ui_paint status 31 '失败'
    ui_kv "$ACTION" "${status}（退出码 ${rc}${meaning:+：${meaning}}）"
    next='保存上方完整输出，并按其中 [x] 行处理；不要用重复 apply 或手工编辑 state.json 代替恢复流程'
  fi
  [ -z "$next" ] || ui_kv '下一步' "$next"
}

run_profile() {
  local action="$1"
  case "$action" in
    preflight | apply | reconfigure)
      env PORT_SPEED_MBPS="$PORT_SPEED_MBPS_SELECTED" bash "$PROFILE_PATH" "$action"
      ;;
    benchmark)
      env DVT_TRAFFIC_BUDGET_TOOL="$TRAFFIC_BUDGET_PATH" bash "$PROFILE_PATH" "$action"
      ;;
    *) bash "$PROFILE_PATH" "$action" ;;
  esac
}

run_update() {
  local source_tag source_url target_url
  validate_port_speed "$STATE_PORT_SPEED_MBPS" ||
    die "$EXIT_CONFLICT" '已安装状态缺少有效端口带宽；无法生成安全升级计划。'
  resolve_update_release
  [ -n "$UPDATE_TAG_SELECTED" ] || return 0
  resolve_installed_profile
  resolve_update_controller

  printf '\n升级计划：\n'
  printf '  当前版本：%s\n' "$STATE_VERSION"
  printf '  当前 profile SHA-256：%s\n' "$SOURCE_PROFILE_SHA256"
  printf '  目标版本：%s\n' "$UPDATE_TAG_SELECTED"
  printf '  目标总控 SHA-256：%s\n' "$UPDATE_CONTROLLER_SHA256"
  printf '  保留端口带宽：%s Mbps\n' "$STATE_PORT_SPEED_MBPS"
  printf '  模式：只读检查；不会执行 rollback、purge、apply 或 reboot\n\n'

  info "先验证当前 ${STATE_VERSION} 配置。"
  bash "$SOURCE_PROFILE_PATH" verify
  info "用目标 ${UPDATE_TAG_SELECTED} 执行只读 update-preflight。"
  env UPDATE_PREFLIGHT=1 PORT_SPEED_MBPS="$STATE_PORT_SPEED_MBPS" \
    bash "$UPDATE_CONTROLLER_PATH" preflight --port "$STATE_PORT_SPEED_MBPS"
  source_tag="v${STATE_VERSION#v}"
  source_url="https://github.com/${REPOSITORY}/releases/download/${source_tag}/${PROFILE_FILE}"
  target_url="https://github.com/${REPOSITORY}/releases/download/${UPDATE_TAG_SELECTED}/debian-vps-tuning.sh"
  printf '\n升级检查通过；系统配置未修改。\n'
  printf '维护窗口迁移材料：\n'
  printf '  当前 profile URL：%s\n' "$source_url"
  printf '  当前 profile SHA-256：%s\n' "$SOURCE_PROFILE_SHA256"
  printf '  目标总控 URL：%s\n' "$target_url"
  printf '  目标总控 SHA-256：%s\n' "$UPDATE_CONTROLLER_SHA256"
  printf '  端口带宽：%s Mbps\n' "$STATE_PORT_SPEED_MBPS"
  printf '请先按迁移指南运行目标总控 migrate prepare；只有 checkpoint 为 PREPARED 才可进入 rollback → reboot → 目标 preflight/apply → reboot → verify。TCP 原值不完整时停止，不执行旧版 rollback。\n'
}

run_migrate() {
  local subcommand="${ACTION_ARGS[0]:-}" state_hash
  case "$subcommand" in
    prepare)
      [ -n "$STATE_VERSION" ] || die "$EXIT_CONFLICT" 'migrate prepare 需要现有 managed state。'
      release_is_newer "$RELEASE_TAG" "$STATE_VERSION" ||
        die "$EXIT_CONFLICT" "目标 ${RELEASE_TAG} 必须高于已安装版本 ${STATE_VERSION}。"
      validate_port_speed "$STATE_PORT_SPEED_MBPS" || die "$EXIT_CONFLICT" 'managed state 缺少有效端口带宽。'
      if [ -z "$UPDATE_TEMP_DIR" ]; then UPDATE_TEMP_DIR="$(mktemp -d)" || die "$EXIT_DOWNLOAD" '无法创建迁移临时目录。'; fi
      resolve_installed_profile
      state_hash="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
      bash "$SOURCE_PROFILE_PATH" verify
      env UPDATE_PREFLIGHT=1 PORT_SPEED_MBPS="$STATE_PORT_SPEED_MBPS" bash "$PROFILE_PATH" preflight
      bash "$MIGRATION_PATH" prepare "${ACTION_ARGS[@]:1}" \
        --source-profile "$SOURCE_PROFILE_PATH" --target-profile "$PROFILE_PATH" \
        --source-version "$STATE_VERSION" --target-version "$CONTROLLER_VERSION" \
        --profile-id "$STATE_PROFILE" --port "$STATE_PORT_SPEED_MBPS" --state-sha256 "$state_hash"
      ;;
    rollback | continue | status)
      bash "$MIGRATION_PATH" "${ACTION_ARGS[@]}"
      ;;
    *) die "$EXIT_USAGE" 'migrate 需要 prepare、rollback、continue 或 status 子命令。' ;;
  esac
}

dispatch_action() {
  local rc
  case "$ACTION" in
    guided)
      is_interactive_terminal || die "$EXIT_USAGE" 'guided 需要交互终端；自动化请分别执行 preflight 和 apply。'
      if run_profile preflight; then :; else rc=$?; return "$rc"; fi
      if confirm_apply; then
        run_profile apply
      else
        DISPATCH_NOTE='declined'
        info '已停止；没有执行 apply。'
      fi
      ;;
    apply)
      if [ "$ACTION_FROM_MENU" -eq 1 ]; then
        [ "$UI_STYLED" -eq 0 ] || confirm_write_page apply
        if ! confirm_answer 'apply 会写入系统配置。是否继续？[y/N]：'; then
          DISPATCH_NOTE='declined'
          info '已停止；没有执行 apply。'
          return 0
        fi
      fi
      run_profile apply
      ;;
    reconfigure)
      if [ "$ACTION_FROM_MENU" -eq 1 ]; then
        if [ "$UI_STYLED" -eq 1 ]; then
          ui_section '确认修改带宽'
          ui_kv '操作' 'reconfigure（修改受管端口带宽）'
          ui_kv '端口带宽' "${STATE_PORT_SPEED_MBPS:-unknown} Mbps → ${PORT_SPEED_MBPS_SELECTED} Mbps"
        fi
        if ! confirm_answer "$(printf '将把已安装端口带宽从 %s Mbps 重配置为 %s Mbps；该操作会事务化更新管理文件和状态。是否继续？[y/N]：' \
          "${STATE_PORT_SPEED_MBPS:-unknown}" "$PORT_SPEED_MBPS_SELECTED")"; then
          DISPATCH_NOTE='declined'
          info '已停止；没有执行带宽重配置。'
          return 0
        fi
      fi
      run_profile reconfigure
      ;;
    rollback)
      if [ "$ACTION_FROM_MENU" -eq 1 ]; then
        if [ "$UI_STYLED" -eq 1 ]; then
          ui_section '确认回滚'
          ui_kv '操作' 'rollback（撤销本项目受管配置）'
          ui_kv '注意' '普通 rollback 保留已创建的 swap；只改端口带宽请用 4. 修改带宽'
        fi
        if ! confirm_answer '是否执行 rollback？[y/N]：'; then
          DISPATCH_NOTE='declined'
          info '已停止；没有执行 rollback。'
          return 0
        fi
      fi
      run_profile rollback
      ;;
    benchmark) run_profile benchmark ;;
    probe)
      bash "$PROBE_PATH" --tuning-script "$PROFILE_PATH" --profile-id "$DETECTED_PROFILE" \
        --budget-tool "$TRAFFIC_BUDGET_PATH" "${ACTION_ARGS[@]}"
      ;;
    htb)
      bash "$HTB_WRAPPER_PATH" --bundle-dir "$HTB_BUNDLE_DIR" --tuning-script "$PROFILE_PATH" \
        --budget-tool "$TRAFFIC_BUDGET_PATH" "${ACTION_ARGS[@]}"
      ;;
    update) run_update ;;
    migrate) run_migrate ;;
    preflight | verify | status | diagnose | recover) run_profile "$ACTION" ;;
    *) die "$EXIT_USAGE" "不支持的 action：${ACTION}" ;;
  esac
}

main() {
  ui_init
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ "$RELEASE_TAG" = "v${CONTROLLER_VERSION}" ] ||
    die "$EXIT_INTEGRITY" '总控版本与固定 Release tag 不一致。'
  parse_arguments "$@"
  if [ -z "$ACTION" ]; then
    is_interactive_terminal || no_terminal_guidance
    choose_action_interactively
  fi
  case "$ACTION" in
    diagnose | measure | htb-sweep | report)
      if [ "$ACTION" = diagnose ] && [ "${ACTION_ARGS[0]:-}" = --managed ]; then
        [ "${#ACTION_ARGS[@]}" -eq 1 ] || die "$EXIT_USAGE" 'diagnose --managed 不接受其他参数。'
        ACTION_ARGS=()
      else
        [ -z "$CLI_PORT_SPEED_MBPS$CLI_UPDATE_TAG" ] || die "$EXIT_USAGE" '独立测量不接受受管 --port/--target。'
        need_command python3
        resolve_companion_assets
        RESULT_PENDING="$ACTION_FROM_MENU"
        python3 "$MEASUREMENT_PATH" "$ACTION" "${ACTION_ARGS[@]}"
        return
      fi
      ;;
  esac
  need_root
  detect_environment
  read_existing_state
  print_environment_summary
  select_port_speed
  if [ "$ACTION" != 'update' ]; then
    resolve_profile_script
    case "$ACTION" in benchmark | probe | htb | migrate) resolve_companion_assets ;; esac
    print_execution_plan
  fi
  RESULT_PENDING="$ACTION_FROM_MENU"
  dispatch_action
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
