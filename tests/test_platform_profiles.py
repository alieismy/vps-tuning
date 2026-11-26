"""跨平台选择与资源策略回归；真实 OS/重启由 VM 生命周期检查承担。"""

from pathlib import Path
import json
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'ubuntu2404-adaptive-vps-tuning.sh').read_text(encoding='utf-8')


def functions(*names):
    return '\n'.join(re.search(r'^' + name + r'\(\) \{.*?^\}', SOURCE,
                               re.M | re.S).group() for name in names) + '\n'


@unittest.skipUnless(shutil.which('bash'), 'Bash is required')
class PlatformProfilesTest(unittest.TestCase):
    def run_shell(self, script):
        result = subprocess.run([shutil.which('bash')], input=script.encode(),
                                cwd=ROOT, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        return result.stdout.decode()

    def test_controller_platform_and_resource_matrix(self):
        self.run_shell(r'''
set -euo pipefail
source ./debian-vps-tuning.sh
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
for arch in x86_64 aarch64; do
  for platform in 'debian 12 debian12' 'debian 13 debian13' 'ubuntu 24.04 ubuntu2404' 'ubuntu 26.04 ubuntu2604'; do
    IFS=' ' read -r os version prefix <<<"$platform"
    printf 'ID=%s\nVERSION_ID=%s\n' "$os" "$version" >"$tmp/os"
    for resources in '2 1024' '4 4096' '4 8192' '4 24576' '128 1048576'; do
      IFS=' ' read -r cpu ram <<<"$resources"
      printf 'MemTotal: %s kB\n' "$((ram*1024))" >"$tmp/mem"
      result=$(detect_profile_from "$tmp/os" "$tmp/mem" "$arch" "$cpu")
      [[ "$result" == "$prefix-adaptive"$'\t'* ]]
    done
  done
done
''')

    def test_ubuntu_release_allowlist_remains_explicit(self):
        self.run_shell(r'''
set -euo pipefail
source ./debian-vps-tuning.sh
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
printf 'MemTotal: 4194304 kB\n' >"$tmp/mem"
for version in 22.04 25.10 26.10 28.04; do
  printf 'ID=ubuntu\nVERSION_ID=%s\n' "$version" >"$tmp/os"
  if detect_profile_from "$tmp/os" "$tmp/mem" x86_64 4; then exit 1; else test "$?" = 2; fi
done
''')

    def test_legacy_arm_selection_preserves_profile_identity(self):
        self.run_shell(r'''
set -euo pipefail
source ./debian-vps-tuning.sh
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
printf 'ID=debian\nVERSION_ID=13\n' >"$tmp/os"
printf 'MemTotal: 1048576 kB\n' >"$tmp/mem"
for arch in x86_64 aarch64; do
  result=$(detect_profile_from "$tmp/os" "$tmp/mem" "$arch" 1)
  [[ "$result" == debian13-1c1g$'\t'* ]]
done
''')

    def test_adaptive_cap_is_bounded_for_small_and_large_hosts(self):
        self.run_shell(functions('configure_resource_policy') + r'''
set -euo pipefail
EXIT_UNSUPPORTED=3
die() { exit "$1"; }
memory_mib() { printf '%s\n' "$ram"; }
for pair in '384 16777216' '512 16777216' '1024 33554432' '4096 134217728' '8192 268435456' '24576 268435456' '1048576 268435456'; do
  read -r ram expected <<<"$pair"
  configure_resource_policy
  [ "$MAX_BUF_MAX" = "$expected" ]
done
for ram in 0 383 invalid ''; do
  if (configure_resource_policy); then exit 1; else [ $? = 3 ]; fi
done
''')

    def test_buffer_target_and_explicit_values_obey_memory_cap(self):
        self.run_shell(functions('configure_resource_policy', 'validate_inputs') + r'''
set -euo pipefail
die() { exit "$1"; }
warn() { :; }
is_bool() { [ "$1" = 0 ] || [ "$1" = 1 ]; }
memory_mib() { printf '%s\n' "$ram"; }
EXIT_USAGE=2
EXIT_UNSUPPORTED=3
PROFILE_RESOURCE_POLICY=adaptive
PROFILE_LABEL=adaptive
DEFAULT_PORT_SPEED_MBPS=200
DEFAULT_BUFFER_TARGET_RTT_MS=200
BUFFER_TARGET_NUMERATOR=1
BUFFER_TARGET_DENOMINATOR=1
MIN_BUF_MAX=262144
ENABLE_SWAP=0
PURGE_CREATED_SWAP=0
REQUIRE_PROXY_SERVICE=0
UPDATE_PREFLIGHT=0
SWAP_MB_INPUT=1024
SWAP_MAX_MIB=4096
BUFFER_TARGET_RTT_MS_INPUT=200
BUF_MAX_INPUT=auto
ram=24576
PORT_SPEED_MBPS_INPUT=10000
validate_inputs
[ "$BUF_MAX" = 268435456 ] && [ "$BUF_MAX_MODE" = auto ]
BUFFER_TARGET_RTT_MS_INPUT=500
validate_inputs
[ "$BUF_MAX_MODE" = auto-clamped ] && [ "$BUFFER_CLAMPED" = 1 ]
ram=4096
validate_inputs
[ "$BUF_MAX" = 134217728 ] && [ "$BUF_MAX_MODE" = auto-clamped ]
PORT_SPEED_MBPS_INPUT=1
validate_inputs
[ "$BUF_MAX" = 16777216 ]
BUF_MAX_INPUT=134217729
if (validate_inputs); then exit 1; else [ $? = 2 ]; fi
BUF_MAX_INPUT=134217728
validate_inputs
[ "$BUF_MAX_MODE" = explicit ]
for PORT_SPEED_MBPS_INPUT in 0 10001 999999999999999999999 1.5; do
  if (validate_inputs); then exit 1; else [ $? = 2 ]; fi
done
''')

    def test_adaptive_resource_check_has_no_cpu_or_ram_ceiling(self):
        self.run_shell(functions('configure_resource_policy', 'check_resource_profile') + r'''
set -euo pipefail
EXIT_UNSUPPORTED=3
die() { exit "$1"; }
nproc() { printf '128\n'; }
memory_mib() { printf '1048576\n'; }
PROFILE_RESOURCE_POLICY=adaptive
PROFILE_CPU_MIN=1
PROFILE_CPU_MAX=0
PROFILE_RAM_MIN_MIB=384
PROFILE_RAM_MAX_MIB=0
check_resource_profile
[ "$MAX_BUF_MAX" = 268435456 ]
''')

    def test_generated_new_profile_defaults(self):
        for name in ('debian12', 'debian13', 'ubuntu2404', 'ubuntu2604'):
            source = (ROOT / f'{name}-adaptive-vps-tuning.sh').read_text(encoding='utf-8')
            self.assertIn('ENABLE_SWAP="${ENABLE_SWAP:-0}"', source)
            self.assertIn("PROFILE_RESOURCE_POLICY='adaptive'", source)
            keys = re.search(r'PROFILE_SYSCTL_KEYS=\((.*?)\n\)', source, re.S)[1]
            self.assertEqual(len(keys.split()), 17)
            self.assertNotIn('tcp_mem', keys)

    def test_sysctl_snapshot_preserves_tab_separated_vectors(self):
        raw = self.run_shell(functions('original_sysctls_json') + r'''
set -euo pipefail
PROFILE_SYSCTL_KEYS=(net.ipv4.tcp_rmem net.ipv4.tcp_wmem)
sysctl() {
  case "$2" in
    net.ipv4.tcp_rmem) printf '4096\t131072\t6291456\n' ;;
    net.ipv4.tcp_wmem) printf '4096\t16384\t4194304\n' ;;
  esac
}
original_sysctls_json
''')
        self.assertEqual(json.loads(raw), {'net.ipv4.tcp_rmem': '4096\t131072\t6291456',
                                          'net.ipv4.tcp_wmem': '4096\t16384\t4194304'})

    def test_incomplete_original_vectors_block_rollback_before_writes(self):
        self.run_shell(functions('original_sysctl_vectors_are_complete', 'rollback_internal') + r'''
set -euo pipefail
STATE_FILE=$(mktemp)
trap 'rm -f -- "$STATE_FILE"' EXIT
error() { :; }
validate_state_file() { :; }
state_get() { printf 'VERIFIED\n'; }
state_set_phase() { exit 99; }
sysctl() { exit 99; }
systemctl() { exit 99; }
for value in '4096' '4096 131072'; do
  jq -n --arg value "$value" '{original_sysctls:{"net.ipv4.tcp_rmem":$value,"net.ipv4.tcp_wmem":"4096 16384 4194304"}}' >"$STATE_FILE"
  if (rollback_internal 0); then exit 1; else [ $? = 1 ]; fi
done
printf '%s\n' '{"original_sysctls":{"net.ipv4.tcp_rmem":"4096\t131072\t6291456","net.ipv4.tcp_wmem":"4096 16384 4194304"}}' >"$STATE_FILE"
original_sysctl_vectors_are_complete
''')


if __name__ == '__main__':
    unittest.main()
