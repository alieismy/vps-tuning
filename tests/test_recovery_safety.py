"""账本路径和迁移接续的离线反例，不修改宿主状态或发送流量。"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]


def function(path, name):
    source = (ROOT / path).read_text(encoding='utf-8')
    return re.search(r'^' + name + r'\(\) \{.*?^\}', source, re.M | re.S).group()


@unittest.skipUnless(shutil.which('bash') and shutil.which('jq'), 'requires Bash and jq')
class RecoverySafetyTests(unittest.TestCase):
    def run_shell(self, script):
        result = subprocess.run([shutil.which('bash')], input=script.encode(), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))

    def test_ledger_rejects_cleanup_tree_before_directory_creation(self):
        validate = function('dvt-traffic-budget.sh', 'validate_ledger_path')
        self.run_shell('''set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 2; }
''' + validate + '''
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
install() { printf 'unexpected directory creation\n' >&2; return 97; }
for ledger in /var/lib/proxy-vps-tuning/ledger.json /var/lib/proxy-vps-tuning/../proxy-vps-tuning/nested/window.json; do
  for action in init reserve; do
    result=0
    (validate_ledger_path) 2>"$temp/error" || result=$?
    [ "$result" = 2 ]
    grep -Fq '受管状态目录树之外' "$temp/error"
  done
done
# 独立目录仍可用。元数据替身只用于该正例。
mkdir "$temp/safe"
ledger="$temp/safe/window.json"; action=init
stat() { case "$*" in *%u*) echo 0 ;; *%a*) echo 700 ;; esac; }
validate_ledger_path
''')

    def test_checkpoint_rejects_normalized_cleanup_paths(self):
        validate = function('dvt-migrate.sh', 'validate_checkpoint_location')
        self.run_shell('''set -euo pipefail
die() { exit 2; }
''' + validate + '''
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
for checkpoint in /var/lib/proxy-vps-tuning /var/lib/proxy-vps-tuning/../proxy-vps-tuning/migration; do
  result=0; (validate_checkpoint_location) || result=$?
  [ "$result" = 2 ]
done
checkpoint=/var/lib/proxy-vps-tuning-migrations/new
validate_checkpoint_location
''')

    @unittest.skipUnless(sys.platform.startswith('linux'), 'requires native Linux symlinks')
    def test_symlink_ancestor_cannot_hide_managed_tree(self):
        ledger = function('dvt-traffic-budget.sh', 'validate_ledger_path')
        checkpoint = function('dvt-migrate.sh', 'validate_checkpoint_location')
        self.run_shell('''set -euo pipefail
die() { exit 2; }
''' + ledger + '\n' + checkpoint + '''
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
ln -s /var/lib/proxy-vps-tuning "$temp/alias"
ledger="$temp/alias/nested/window.json"; action=init
checkpoint="$temp/alias/migration"
for validate in validate_ledger_path validate_checkpoint_location; do
  result=0; ($validate) || result=$?
  [ "$result" = 2 ]
done
''')

    def test_applied_resume_stops_before_reboot_gate_and_is_repeatable(self):
        resume = function('dvt-migrate.sh', 'continue_stage')
        self.run_shell('''set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 2; }
info() { :; }
validate_checkpoint() { :; }
boot_id() { echo fixture-boot; }
verify_target_baseline() { :; }
update_phase() { printf '%s\n' "$1" >>"$trace"; }
''' + resume + '''
checkpoint="$(mktemp -d)"
trap 'rm -rf -- "$checkpoint"' EXIT
STATE_FILE="$checkpoint/state.json"; trace="$checkpoint/trace"
printf '%s\n' '{"phase":"APPLY_RUNNING","target_version":"0.2.0-rc.5","profile_id":"debian13-1c1g","port_speed_mbps":200}' >"$checkpoint/migration.json"
printf '%s\n' '{"script_version":"0.2.0-rc.5","state":"APPLIED","profile":{"id":"debian13-1c1g"}}' >"$STATE_FILE"
before="$(sha256sum "$STATE_FILE")"
for attempt in 1 2; do
  result=0; (continue_stage) 2>"$checkpoint/error" || result=$?
  [ "$result" = 2 ]; [ ! -e "$trace" ]
  grep -Fq '当前无需重启' "$checkpoint/error"
  [ "$(sha256sum "$STATE_FILE")" = "$before" ]
done
jq '.state="VERIFIED"' "$STATE_FILE" >"$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"
continue_stage
[ "$(cat "$trace")" = TARGET_APPLIED_REBOOT_REQUIRED ]
''')

    def test_legacy_rollback_preserves_unknown_state_material(self):
        guard = function('dvt-migrate.sh', 'validate_source_state_directory')
        rollback = function('dvt-migrate.sh', 'rollback_stage')
        self.run_shell('''set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 2; }
info() { :; }
validate_checkpoint() { :; }
boot_id() { echo fixture-boot; }
stat() { echo 0; }
update_phase() { printf '%s\n' "$1" >>"$trace"; }
bash() { touch "$called"; rm "$STATE_FILE"; }
''' + guard + '\n' + rollback + '''
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
mkdir "$temp/state" "$temp/checkpoint"
STATE_FILE="$temp/state/state.json"; checkpoint="$temp/checkpoint"
trace="$temp/trace"; called="$temp/old-source-called"
printf '%s\n' '{}' >"$STATE_FILE"
before="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
jq -n --arg hash "$before" '{phase:"PREPARED",source_state_sha256:$hash}' >"$checkpoint/migration.json"
for phase in PREPARED ROLLBACK_RUNNING; do
  jq --arg phase "$phase" '.phase=$phase' "$checkpoint/migration.json" >"$checkpoint/migration.json.tmp"
  mv "$checkpoint/migration.json.tmp" "$checkpoint/migration.json"
  for kind in file directory; do
    extra="$temp/state/traffic-ledgers"
    if [ "$kind" = file ]; then printf fixture >"$extra"; else mkdir "$extra"; fi
    result=0; (rollback_stage) 2>"$temp/error" || result=$?
    [ "$result" = 2 ]; [ ! -e "$called" ]; [ ! -e "$trace" ]
    [ "$(sha256sum "$STATE_FILE" | awk '{print $1}')" = "$before" ]
    grep -Fq '保留现场' "$temp/error"
    if [ "$kind" = file ]; then rm "$extra"; else rmdir "$extra"; fi
  done
done
rollback_stage
[ -e "$called" ]
[ "$(cat "$trace")" = ROLLED_BACK_REBOOT_REQUIRED ]
''')

    def test_unknown_and_failed_settlement_keep_known_lower_bound(self):
        settle = function('dvt-traffic-budget.sh', 'settle')
        schema = function('dvt-traffic-budget.sh', 'validate_ledger_json')
        uint = function('dvt-traffic-budget.sh', 'uint')
        self.run_shell('''set -euo pipefail
die() { exit 2; }
safe_id() { :; }
atomic_write() { mv "$1" "$ledger"; }
SCHEMA_VERSION=1
reservation_id=fixture
actual_bytes=''
''' + uint + '\n' + schema + '\n' + settle + '''
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
ledger="$temp/ledger.json"
for outcome in COMMITTED_CONSERVATIVE FAILED_CONSERVATIVE; do
  for known_bytes in '' 50 150; do
    printf '%s\n' '{"schema_version":1,"tool_version":"0.2.0-rc.1","window_id":"fixture","budget_bytes":1000,"reserved_bytes":100,"accounted_bytes":0,"entries":[{"reservation_id":"fixture","status":"RESERVED","planned_bytes":100}]}' >"$ledger"
    settle "$outcome" >/dev/null
    expected=100; [ "${known_bytes:-0}" -le 100 ] || expected="$known_bytes"
    jq -e --arg status "$outcome" --argjson expected "$expected" '.reserved_bytes==0 and .accounted_bytes==$expected and .entries[0].status==$status and .entries[0].actual_known_bytes==null and .entries[0].accounted_bytes==$expected' "$ledger" >/dev/null
  done
done
jq '.entries[0].status="RESERVED" | .reserved_bytes=100 | .accounted_bytes=0' "$ledger" >"$ledger.tmp"
mv "$ledger.tmp" "$ledger"
before="$(sha256sum "$ledger")"
known_bytes=-1
set +e
(set -e; settle COMMITTED_CONSERVATIVE) >/dev/null 2>&1
result=$?
set -e
[ "$result" = 2 ]
[ "$(sha256sum "$ledger")" = "$before" ]
''')


if __name__ == '__main__':
    unittest.main()
