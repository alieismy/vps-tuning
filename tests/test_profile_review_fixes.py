"""评审缺陷回归，执行生成脚本函数并隔离 systemd、proc 和 root 元数据。"""
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def functions(*names):
    source = (ROOT / 'ubuntu2404-adaptive-vps-tuning.sh').read_text(encoding='utf-8')
    return '\n'.join(re.search(r'^' + name + r'\(\) \{.*?^\}', source,
                               re.M | re.S).group() for name in names) + '\n'


@unittest.skipUnless(shutil.which('bash') and shutil.which('jq'), 'Bash and jq required')
class ProfileReviewFixesTest(unittest.TestCase):
    def run_shell(self, source, body):
        script = 'set -euo pipefail\n' + source + r'''
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
error() { printf '%s\n' "$*" >&2; }
info() { :; }
warn() { printf '%s\n' "$*" >&2; }
die() { error "$2"; exit "$1"; }
''' + body
        result = subprocess.run([shutil.which('bash')], input=script.encode(),
                                cwd=ROOT, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))

    def test_strict_service_requires_main_limits_and_requested_core(self):
        source = functions('profile_service_units', 'read_nofile_limits',
                           'verify_runtime_nofile', 'verify_proxy_services')
        source = source.replace('/proc/', '${tmp}/proc/')
        self.run_shell(source, r'''
XUI_NOFILE_LIMIT=65536
PROXY_SERVICE_UNITS_INPUT=x-ui.service
DEFAULT_PROXY_SERVICE_UNITS=(x-ui.service)
REQUIRE_PROXY_SERVICE=1
EXIT_USAGE=2
main=111; children=''; fixture_executable=/bin/helper
systemctl() {
  case "$*" in
    *LoadState*x-ui.service) echo loaded;;
    *LoadState*) echo not-found;;
    *ActiveState*) echo active;;
    *MainPID*) echo "$main";;
    *LimitNOFILE*) echo 65536;;
  esac
}
pgrep() { printf '%s\n' "$children"; }
readlink() { printf '%s\n' "$fixture_executable"; }
mkdir -p "$tmp/proc/111" "$tmp/proc/222"
printf 'Max open files 65536 65536 files\n' >"$tmp/proc/111/limits"
cp "$tmp/proc/111/limits" "$tmp/proc/222/limits"
if verify_proxy_services; then exit 1; fi
children=222
if verify_proxy_services; then exit 1; fi
fixture_executable=/usr/local/x-ui/bin/xray-linux-amd64
verify_proxy_services
main=0
if verify_proxy_services; then exit 1; fi
main=111
printf 'Max open files 1024 65536 files\n' >"$tmp/proc/222/limits"
if verify_proxy_services; then exit 1; fi
cp "$tmp/proc/111/limits" "$tmp/proc/222/limits"
PROXY_SERVICE_UNITS_INPUT='x-ui.service missing.service'
if verify_proxy_services; then exit 1; fi
PROXY_SERVICE_UNITS_INPUT=''; REQUIRE_PROXY_SERVICE=0; children=''
verify_proxy_services
systemctl() { echo not-found; }
verify_proxy_services
''')

    def test_invalid_explicit_units_do_not_pass_as_preinstall(self):
        self.run_shell(functions('profile_service_units', 'verify_proxy_services'), r'''
EXIT_USAGE=2
REQUIRE_PROXY_SERVICE=0
DEFAULT_PROXY_SERVICE_UNITS=(x-ui.service)
systemctl() { echo 'service queried before all names were validated' >&2; exit 99; }
for PROXY_SERVICE_UNITS_INPUT in invalid-unit 'x-ui.service invalid-unit' '   ' $'x-ui.service\ninvalid-unit'; do
  if verify_proxy_services; then exit 1; fi
done
''')

    def test_queue_verification_requires_an_interface(self):
        self.run_shell(functions('verify_current_qdiscs'), r'''
ifaces=''; kind=fq
default_route_ifaces() { printf '%s\n' "$ifaces"; }
qdisc_snapshot_for_iface() { printf '{"qdiscs":[{"root":true,"kind":"%s"}]}\n' "$kind"; }
if verify_current_qdiscs; then exit 1; fi
ifaces=eth0
verify_current_qdiscs
kind=htb
if verify_current_qdiscs; then exit 1; fi
''')

    def test_publish_registers_digest_before_file_is_visible(self):
        self.run_shell(functions('write_managed_file', 'atomic_json_commit',
                                 'state_managed_hash', 'is_marker_managed_file',
                                 'assert_owned_file'), r'''
STATE_FILE="$tmp/state.json"
MANAGED_MARKER='# fixture managed'
EXIT_CONFLICT=4
state_get() { jq -r "$1" "$STATE_FILE"; }
chown() { :; }
stat() { printf '0\n'; }
printf '{"state":"APPLYING","managed_files":[]}\n' >"$STATE_FILE"
target="$tmp/config"
mv() {
  if [ "${*: -1}" = "$target" ]; then
    jq -e --arg path "$target" '.managed_files[] | select(.path==$path) | .sha256 | length==64' "$STATE_FILE" >/dev/null
    [ ! -e "$target" ]
  fi
  command mv "$@"
}
printf '%s\nbody\n' "$MANAGED_MARKER" | write_managed_file "$target" 0644
assert_owned_file "$target"
printf 'foreign edit\n' >>"$target"
if (assert_owned_file "$target"); then exit 1; else [ $? = 4 ]; fi
rm "$target"
mv() { if [ "${*: -1}" = "$target" ]; then return 1; fi; command mv "$@"; }
if printf '%s\n' "$MANAGED_MARKER" | write_managed_file "$target" 0644; then exit 1; fi
[ ! -e "$target" ]
''')

    def test_cleanup_preserves_ledger_and_state_until_moved(self):
        self.run_shell(functions('remove_managed_state'), r'''
STATE_DIR="$tmp/state"; STATE_FILE="$STATE_DIR/state.json"
mkdir -p "$STATE_DIR/traffic-ledgers"
printf 'state\n' >"$STATE_FILE"
printf 'reserved budget\n' >"$STATE_DIR/traffic-ledgers/window.json"
if remove_managed_state; then exit 1; fi
[ -f "$STATE_FILE" ]
grep -qx 'reserved budget' "$STATE_DIR/traffic-ledgers/window.json"
mv "$STATE_DIR/traffic-ledgers" "$tmp/traffic-ledgers"
printf 'snapshot\n' >"$STATE_DIR/qdisc-original.json"
remove_managed_state
[ ! -e "$STATE_DIR" ]
grep -qx 'reserved budget' "$tmp/traffic-ledgers/window.json"
''')

    def test_cleanup_does_not_remove_a_file_created_during_deletion(self):
        self.run_shell(functions('remove_managed_state'), r'''
STATE_DIR="$tmp/state"; STATE_FILE="$STATE_DIR/state.json"
mkdir "$STATE_DIR"
printf 'state\n' >"$STATE_FILE"
printf 'snapshot\n' >"$STATE_DIR/qdisc-original.json"
rm() {
  printf 'new budget\n' >"$STATE_DIR/window.json"
  command rm "$@"
}
if remove_managed_state; then exit 1; fi
grep -qx 'new budget' "$STATE_DIR/window.json"
unset -f rm
''')

    def test_adaptive_warning_distinguishes_rounding_cap_from_target_shortfall(self):
        self.run_shell(functions('configure_resource_policy', 'validate_inputs'), r'''
is_bool() { [ "$1" = 0 ] || [ "$1" = 1 ]; }
memory_mib() { echo "$ram"; }
EXIT_USAGE=2; EXIT_UNSUPPORTED=3
PROFILE_RESOURCE_POLICY=adaptive; PROFILE_LABEL=adaptive
DEFAULT_PORT_SPEED_MBPS=200; DEFAULT_BUFFER_TARGET_RTT_MS=200
BUFFER_TARGET_NUMERATOR=1; BUFFER_TARGET_DENOMINATOR=1
MIN_BUF_MAX=262144; ENABLE_SWAP=0; PURGE_CREATED_SWAP=0
REQUIRE_PROXY_SERVICE=0; UPDATE_PREFLIGHT=0; SWAP_MB_INPUT=1024; SWAP_MAX_MIB=4096
BUFFER_TARGET_RTT_MS_INPUT=200; BUF_MAX_INPUT=auto; PORT_SPEED_MBPS_INPUT=2000
ram=1984
validate_inputs 2>"$tmp/warning"
[ "$BUF_MAX" = 65011712 ] && [ "$BUF_MAX_MODE" = auto-clamped ]
grep -q '仍覆盖' "$tmp/warning"
ram=1024
validate_inputs 2>"$tmp/warning"
[ "$BUF_MAX" = 33554432 ]
grep -q '未达到' "$tmp/warning"
''')

    def test_apply_port_change_points_to_reconfigure(self):
        self.run_shell(functions('apply_settings'), r'''
SCRIPT_VERSION=0.2.0-rc.5; EXIT_CONFLICT=4
PORT_SPEED_MBPS=2000; BUFFER_TARGET_RTT_MS=200; BUF_MAX=67108864
BUFFER_TARGET_RTT_MS_INPUT=''; BUF_MAX_ENV_WAS_SET=''
run_preflight() { :; }
state_exists() { return 0; }
state_get() {
 case "$1" in
  .state) echo VERIFIED;; .script_version) echo "$SCRIPT_VERSION";;
  .network.port_speed_mbps) echo 500;; .network.target_rtt_ms) echo 250;;
  .network.buffer_max_bytes) echo 33554432;;
 esac
}
if (apply_settings) 2>"$tmp/message"; then exit 1; else [ $? = 4 ]; fi
grep -q 'dvt reconfigure --port 2000' "$tmp/message"
! grep -q 'PURGE_CREATED_SWAP' "$tmp/message"
BUFFER_TARGET_RTT_MS_INPUT=250; BUFFER_TARGET_RTT_MS=250
BUF_MAX_ENV_WAS_SET=x; BUF_MAX=33554432
if (apply_settings) 2>"$tmp/message"; then exit 1; else [ $? = 4 ]; fi
grep -q 'dvt reconfigure --port 2000' "$tmp/message"
grep -q '清除 BUFFER_TARGET_RTT_MS 和 BUF_MAX' "$tmp/message"
''')


if __name__ == '__main__':
    unittest.main()
