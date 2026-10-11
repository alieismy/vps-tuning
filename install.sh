#!/usr/bin/env bash
# Verified, release-pinned installer for the dvt command.

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

INSTALLER_VERSION='0.2.0-rc.2'
RELEASE_TAG='v0.2.0-rc.2'
REPOSITORY='alieismy/debian-vps-tuning'
EXPECTED_MANIFEST_SHA256='93cc144843cfd1ce0f0961922b04a1a8d60ab86e2bab841c26b857b9e0493558'
DEFAULT_PREFIX='/usr/local'

source_dir=''
prefix="$DEFAULT_PREFIX"
launch=1
temp_dir=''

assets=(
  debian-vps-tuning.sh
  debian12-1c512m-vps-tuning.sh
  debian12-1c1g-vps-tuning.sh
  debian12-1c2g-vps-tuning.sh
  debian13-1c512m-vps-tuning.sh
  debian13-1c1g-vps-tuning.sh
  debian13-1c2g-vps-tuning.sh
  debian12-adaptive-vps-tuning.sh
  debian13-adaptive-vps-tuning.sh
  ubuntu2404-adaptive-vps-tuning.sh
  tcpquality-evidence.sh
  dvt-traffic-budget.sh
  dvt-migrate.sh
  dvt-probe.sh
  dvt-measure.py
  dvt-measure-runtime.sh
  dvt_htb_transaction.py
  measurement-endpoints.json
  dvt-htb.sh
  experiments/htb-aggregate/experiment-plan.sh
  experiments/htb-aggregate/htb-aggregate-experiment.sh
  experiments/htb-aggregate/rate-sweep-plan.sh
  experiments/htb-aggregate/rate-sweep-run.sh
  experiments/htb-aggregate/rate-sweep-analyze.sh
)

info() { printf '[dvt-install] %s\n' "$*"; }
die() { printf '[dvt-install][FAIL] %s\n' "$*" >&2; exit 2; }
cleanup() { [ -z "$temp_dir" ] || [ ! -d "$temp_dir" ] || rm -rf -- "$temp_dir"; }

usage() {
  cat <<'EOF'
Usage:
  bash install.sh [--no-launch]
  bash install.sh --source-dir /absolute/release-assets [--prefix /usr/local] [--no-launch]

Remote mode downloads only the fixed v0.2.0-rc.2 Release. It first verifies
the pinned SHA-256 of SHA256SUMS, then verifies every installed asset. Local
mode is intended for release validation and also requires a complete matching
SHA256SUMS. Installation itself does not apply tuning or run network traffic.
With an interactive terminal it opens the dvt menu after installation unless
--no-launch is specified.
EOF
}

download_file() {
  local url="$1" output="$2"
  curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 120 --max-redirs 5 --remove-on-error --output "$output" "$url"
}

manifest_entry_valid() {
  local manifest="$1" file="$2" logical="$3" count expected actual
  count="$(awk -v name="$logical" '$2 == name {count++} END {print count+0}' "$manifest")"
  [ "$count" -eq 1 ] || return 1
  expected="$(awk -v name="$logical" '$2 == name {print $1; exit}' "$manifest")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [ "${actual,,}" = "${expected,,}" ]
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-dir) [ "$#" -ge 2 ] || die '--source-dir 缺少参数。'; source_dir="$2"; shift 2 ;;
      --prefix) [ "$#" -ge 2 ] || die '--prefix 缺少参数。'; prefix="$2"; shift 2 ;;
      --no-launch) launch=0; shift ;;
      -h | --help | help) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

main() {
  local release_base manifest manifest_actual logical source target stage_root final_root lib_root
  local asset_name wrapper_tmp current_tmp existing_manifest
  parse_args "$@"
  [ "$(id -u)" -eq 0 ] || die '必须在 root shell 中运行。'
  for command in awk bash chmod cp curl dirname find install ln mkdir mv readlink rm sha256sum stat; do
    [ -n "$source_dir" ] && [ "$command" = curl ] && continue
    command -v "$command" >/dev/null 2>&1 || die "缺少命令：${command}"
  done
  [ "$RELEASE_TAG" = "v${INSTALLER_VERSION}" ] || die 'installer 版本与 Release tag 不一致。'
  [[ "$prefix" = /* ]] || die '--prefix 必须是绝对路径。'
  [ ! -L "$prefix" ] || die '--prefix 不能是符号链接。'
  if [ -n "$source_dir" ]; then
    [[ "$source_dir" = /* ]] || die '--source-dir 必须是绝对路径。'
    [ -d "$source_dir" ] && [ ! -L "$source_dir" ] || die '--source-dir 不存在或是符号链接。'
    source_dir="$(readlink -f "$source_dir")"
  fi
  umask 077
  temp_dir="$(mktemp -d)" || die '无法创建临时目录。'
  trap cleanup EXIT INT TERM
  manifest="${temp_dir}/SHA256SUMS"
  if [ -n "$source_dir" ]; then
    [ -f "${source_dir}/SHA256SUMS" ] && [ ! -L "${source_dir}/SHA256SUMS" ] || die 'source-dir 缺少普通文件 SHA256SUMS。'
    cp -- "${source_dir}/SHA256SUMS" "$manifest"
  else
    release_base="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}"
    info "下载固定 Release 清单：${RELEASE_TAG}/SHA256SUMS"
    download_file "${release_base}/SHA256SUMS" "$manifest" || die '无法下载固定 Release 清单；没有回退到分支或 latest。'
    manifest_actual="$(sha256sum "$manifest" | awk '{print $1}')"
    [ "$manifest_actual" = "$EXPECTED_MANIFEST_SHA256" ] || die 'SHA256SUMS 未通过 installer 内置固定摘要校验。'
  fi

  mkdir -m 0700 "${temp_dir}/assets"
  for logical in "${assets[@]}"; do
    target="${temp_dir}/assets/${logical}"
    mkdir -p -- "$(dirname "$target")"
    if [ -n "$source_dir" ]; then
      source="${source_dir}/${logical}"
      [ -f "$source" ] && [ ! -L "$source" ] || die "source-dir 缺少普通文件：${logical}"
      cp -- "$source" "$target"
    else
      asset_name="$(basename "$logical")"
      info "下载并校验：${asset_name}"
      download_file "${release_base}/${asset_name}" "$target" || die "无法下载 Release 资产：${asset_name}"
    fi
    manifest_entry_valid "$manifest" "$target" "$logical" || die "资产未通过 SHA-256 校验：${logical}"
  done
  manifest_entry_valid "$manifest" "${temp_dir}/assets/debian-vps-tuning.sh" debian-vps-tuning.sh || die '总控校验失败。'
  grep -Fq "CONTROLLER_VERSION='${INSTALLER_VERSION}'" "${temp_dir}/assets/debian-vps-tuning.sh" || die '总控版本契约不匹配。'

  lib_root="${prefix}/lib/debian-vps-tuning"
  final_root="${lib_root}/${INSTALLER_VERSION}"
  stage_root="${lib_root}/.${INSTALLER_VERSION}.stage.$$"
  install -d -o root -g root -m 0755 "$prefix" "${prefix}/bin" "${prefix}/lib" "$lib_root"
  if [ -e "$final_root" ]; then
    [ -d "$final_root" ] && [ ! -L "$final_root" ] || die "版本目标不是普通目录：${final_root}"
    existing_manifest="${final_root}/SHA256SUMS"
    [ -f "$existing_manifest" ] || die '现有版本目录缺少 SHA256SUMS；拒绝覆盖。'
    [ "$(sha256sum "$existing_manifest" | awk '{print $1}')" = "$(sha256sum "$manifest" | awk '{print $1}')" ] ||
      die '现有版本目录的 SHA256SUMS 与固定 Release 不一致；拒绝覆盖。'
    for logical in "${assets[@]}"; do
      [ "$(stat -c '%u' "${final_root}/${logical}")" = 0 ] || die "现有资产不是 root 所有：${logical}"
      [ $((8#$(stat -c '%a' "${final_root}/${logical}") & 0022)) -eq 0 ] ||
        die "现有资产可被 group/world 写入：${logical}"
      manifest_entry_valid "$manifest" "${final_root}/${logical}" "$logical" || die "现有版本目录内容不匹配：${logical}"
    done
    info "现有版本目录已完整校验，将复用：${final_root}"
  else
    install -d -o root -g root -m 0755 "$stage_root"
    for logical in "${assets[@]}"; do
      target="${stage_root}/${logical}"
      install -d -o root -g root -m 0755 "$(dirname "$target")"
      install -o root -g root -m 0755 "${temp_dir}/assets/${logical}" "$target"
    done
    install -o root -g root -m 0644 "$manifest" "${stage_root}/SHA256SUMS"
    mv -- "$stage_root" "$final_root"
  fi

  current_tmp="${lib_root}/.current.$$"
  ln -s "$final_root" "$current_tmp"
  mv -Tf -- "$current_tmp" "${lib_root}/current"
  wrapper_tmp="${prefix}/bin/.dvt.$$"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
    printf 'exec bash %q "$@"\n' "${lib_root}/current/debian-vps-tuning.sh"
  } >"$wrapper_tmp"
  chmod 0755 "$wrapper_tmp"; mv -f -- "$wrapper_tmp" "${prefix}/bin/dvt"
  info "安装完成：${prefix}/bin/dvt -> ${final_root}"
  info '安装过程没有执行 preflight/apply、没有修改网络参数，也没有产生测试流量。'
  trap - EXIT INT TERM; cleanup
  if [ "$launch" -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then exec "${prefix}/bin/dvt"; fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
