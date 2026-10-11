#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d)"
prefix="${test_root}/usr/local"
trap 'rm -rf -- "$test_root"' EXIT

[ "$(id -u)" -eq 0 ] || { printf 'installer check requires root\n' >&2; exit 1; }

bash "${repo_root}/install.sh" --source-dir "$repo_root" --prefix "$prefix" --no-launch
test -x "${prefix}/bin/dvt"
test -L "${prefix}/lib/debian-vps-tuning/current"
test "$(readlink -f "${prefix}/lib/debian-vps-tuning/current")" = \
  "${prefix}/lib/debian-vps-tuning/0.2.0-rc.2"
test "$("${prefix}/bin/dvt" --version)" = 'controller=0.2.0-rc.2 release=v0.2.0-rc.2'
(
  cd "${prefix}/lib/debian-vps-tuning/current"
  sha256sum -c SHA256SUMS >/dev/null
)

# An identical reinstall must be idempotent.
bash "${repo_root}/install.sh" --source-dir "$repo_root" --prefix "$prefix" --no-launch >/dev/null

# An altered immutable version asset must be rejected rather than overwritten.
printf '\n# tamper fixture\n' >>"${prefix}/lib/debian-vps-tuning/0.2.0-rc.2/dvt-probe.sh"
if bash "${repo_root}/install.sh" --source-dir "$repo_root" --prefix "$prefix" --no-launch >/dev/null 2>&1; then
  printf 'installer accepted a modified existing version directory\n' >&2
  exit 1
fi
grep -Fq '# tamper fixture' "${prefix}/lib/debian-vps-tuning/0.2.0-rc.2/dvt-probe.sh"

printf 'installer checks passed\n'
