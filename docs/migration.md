# 升级、旧状态与历史恢复

当前目标：`v0.2.0-rc.1`。本页用于已有 DVT 管理状态的主机；全新安装见 [README](../README.md#安装)。历史版本步骤保留在后面的附录，不能直接换版本号套用。

**2026-10-04 已知问题：** 已发布 rc.1 的目标 profile 会把旧 schema 4 的版本不一致报告为笼统状态错误；旧版 verify 成功并不能解除此拒绝。[rc.2 本地候选](releases/v0.2.0-rc.2.md)修复只读预检，并保留恢复完整性门禁。下方 rc.1 的固定资产和命令属于已发布版本，尚不能作为受影响 schema 4 主机的可执行迁移路线；rc.2 未发布，不能直接替换下载 URL。

盘点原值时应直接读取受管状态，而不是当前内核的调优值。下面命令只输出非敏感摘要，不修改状态：

```bash
jq '{schema_version,script_version,state,profile_id:.profile.id,
     port_speed_mbps:.network.port_speed_mbps,
     original_tcp_rmem:.original_sysctls["net.ipv4.tcp_rmem"],
     original_tcp_wmem:.original_sysctls["net.ipv4.tcp_wmem"]}' \
  /var/lib/proxy-vps-tuning/state.json
```

两项原值各须为完整的三个整数。若各只有 `4096`，即使候选预检通过，仍应停在恢复证据核查；`ALLOW_EMPTY_STATE_RECOVERY=1` 不适用于有效旧状态的缺失三元组。历史完整三元组只有在能证明对应同一主机、本次部署的应用前状态及其间配置连续性时，才能作为恢复依据。对于明确接受新恢复语义的主机，rc.2 源码候选另提供[带来源的 TCP 基线恢复工具](tcp-baseline-recovery.md)：保留原件，区分历史证据与替代值，再接续迁移；该入口未发布，不属于下面已发布 rc.1 命令的强制选项。

## 先判断能否迁移

安装新入口、迁移 managed state、重启持久性和真实业务验收是不同步骤。`dvt --version` 显示执行入口版本，不一定等于状态里的 `script_version`。`update` 只检查和生成计划，不执行 rollback、purge、apply、reconfigure 或 reboot。

**恢复原值不完整时，普通迁移停止在只读检查。** 更早版本可能只保存了 `net.ipv4.tcp_rmem` / `net.ipv4.tcp_wmem` 的第一项。三元组缺项时，新迁移器拒绝创建 checkpoint；旧版 verify 成功也不能证明原值完整。不得手改状态、猜默认值冒充历史快照，或调用旧版 rollback 绕过拒绝。选择新基线时须独立完成上文恢复工具的逐台计划、归档和来源记录，不能直接解除完整性门禁。已发布流程的处置边界见 [平台支持：旧状态与迁移](platform-support.md#旧状态与迁移)。

当前迁移器只接受已定义的 rc.1–rc.19 Debian 来源，还必须通过实际来源状态、profile、资源、所有权、原值和目标预检。版本在此范围内不等于必然可迁移。跨 OS、资源变化导致的 profile 切换不由以下步骤自动处理。

迁移前确认控制台/救援入口、系统及代理业务备份、SSH 管理路径与 swap 清理所需内存余量。保留来源版本的完整资产和备份。不同 Release 的总控、`SHA256SUMS`、profile 与伴随工具不得混放；发生失败保留 state/checkpoint，不跳阶段。

## 迁移到 v0.2.0-rc.1

以下命令在被迁移主机的 root shell 中分步执行。示例目录必须尚不存在；已存在时检查并接续原任务，不能覆盖或换名绕过未完成状态。任何命令失败即停止。

### 1. 获取固定目标入口并执行只读检查

不要提前安装新 `dvt` 或 apply。直接下载目标总控到独立目录，以固定摘要校验后让它取得、核验来源和目标资产。即使现有 `dvt` 与状态版本已经不同，也由目标总控调用来源版本的 profile 做核验。

```bash
set -Eeuo pipefail
test "$(id -u)" -eq 0
test ! -e /root/dvt-to-0.2.0-rc.1
test ! -L /root/dvt-to-0.2.0-rc.1
install -d -m 0700 /root/dvt-to-0.2.0-rc.1
curl --fail --show-error --silent --location \
  --proto '=https' --proto-redir '=https' \
  --connect-timeout 15 --max-time 120 --max-redirs 5 \
  --remove-on-error \
  -o /root/dvt-to-0.2.0-rc.1/debian-vps-tuning.sh \
  https://github.com/alieismy/debian-vps-tuning/releases/download/v0.2.0-rc.1/debian-vps-tuning.sh
printf '%s  %s\n' \
  'c547a88c519f27d2996eaaf6fe34716dffc391492687251a801387af20429dc2' \
  /root/dvt-to-0.2.0-rc.1/debian-vps-tuning.sh | sha256sum -c -
bash /root/dvt-to-0.2.0-rc.1/debian-vps-tuning.sh update --target v0.2.0-rc.1
```

检查输出中的来源版本、profile、端口带宽和目标 `v0.2.0-rc.1`。只有来源 verify、目标预检均通过，并显示“升级检查通过；系统配置未修改”才继续。此步骤成功仍不证明原始快照可以恢复；下一步 prepare 必须检查该条件。

### 2. 使用目标总控准备 checkpoint

仍使用刚校验的目标总控，不使用可能属于旧版的 `dvt migrate prepare`。prepare 写入 root-only checkpoint、固定两版 profile 和迁移器，但不修改当前受管配置。

```bash
set -Eeuo pipefail
test ! -e /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1
test ! -L /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1
bash /root/dvt-to-0.2.0-rc.1/debian-vps-tuning.sh migrate prepare \
  --checkpoint /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1
bash /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1/dvt-migrate.sh status \
  --checkpoint /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1 |
  jq -e 'select(.phase=="PREPARED" and .target_version=="0.2.0-rc.1") | {phase,source_version,target_version,profile_id,port_speed_mbps}'
```

核对显示的来源版本和 profile 与原主机一致。原值完整性、来源状态或任何检查失败时，到此停止，不执行下方回滚和重启。

### 3. 在维护窗口恢复来源并第一次重启

checkpoint 内固定的**旧版固定 Release** profile 执行受管 rollback，并显式清理由它创建的 swap。这一步会修改主机；外部 swap 不归项目删除。

```bash
set -Eeuo pipefail
bash /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1/dvt-migrate.sh rollback \
  --checkpoint /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1
reboot
```

成功重启并确认主机可达后继续。swapoff 或恢复失败时保留状态，不能强制清理。

### 4. 第一次重启后应用目标并第二次重启

continue 检查 boot ID 已变化，再运行目标 preflight/apply。失败时保留 checkpoint 和输出，不重复 apply 或编辑 state。

```bash
set -Eeuo pipefail
bash /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1/dvt-migrate.sh continue \
  --checkpoint /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1
reboot
```

### 5. 第二次重启后完成验证并切换入口

再次 continue 核验第二个 boot gate 和目标配置。只有 `COMPLETE` 才表示迁移器流程完成。

```bash
set -Eeuo pipefail
bash /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1/dvt-migrate.sh continue \
  --checkpoint /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1
bash /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1/dvt-migrate.sh status \
  --checkpoint /var/lib/debian-vps-tuning-migrations/to-0.2.0-rc.1 |
  jq -e 'select(.phase=="COMPLETE" and .target_version=="0.2.0-rc.1") | {phase,source_version,target_version,profile_id}'
```

随后按 [README 固定版本安装块](../README.md#安装) 安装 `v0.2.0-rc.1` 入口（保留 `--no-launch`）；这一步不再 apply。若入口已是该版本，核对版本与完整性后可跳过重复安装。最后执行：

```bash
dvt --version
dvt status
dvt verify
```

适用时执行[严格代理服务验证](../README.md#路径-b应用持久配置)，并独立确认控制台/SSH、服务与真实客户端业务。迁移不要求公网测速，不证明线路性能改善。旧目录、checkpoint 和备份保留供恢复与核验。

## 失败、混合版本与恢复

- checkpoint 中途失败：查看其 `status`，依据实际 phase 接续；不得跳过两个 reboot gate。
- 新入口配旧状态：普通 `status`/`verify` 可能报告版本或 schema 不匹配；单凭这条错误不能推断状态损坏。使用固定目标的只读 update 核对来源，不能直接 recover/apply。
- 带宽重配置的 `RECONFIGURING` / `DEGRADED`：属于同版本事务恢复，见[操作指南](usage.md#状态与重复执行)，不是跨版本迁移。
- 未知损坏、原值缺失或早期无可靠所有权状态：保留只读证据。没有应用前原始证据时，需另行评估有可恢复业务备份的干净系统重建；不能把删除旧文件当作恢复。
- 新安装本身不会迁移旧状态，也不授权用当前版本的 rollback 卸载任意历史版本。


## 历史版本迁移附录

本附录保留原目标版本、URL、摘要和恢复行为，仅用于处理与原前提一致的旧任务。所有历史 rollback/reboot 前仍必须满足 [原值完整性条件](platform-support.md#旧状态与迁移)；缺少原值时停在只读盘点，旧版 verify 成功不能替代该检查。不要把本附录当作当前版本安装步骤。

旧流程中的短命令 `dvt migrate prepare` 只在已校验的 `dvt` 恰好属于该节目标版本时适用。入口仍是来源版本或已切到其他版本时，必须使用该节已取得并核验的目标总控绝对路径调用 prepare；当前 `0.2.0-rc.1` 入口不能用于准备这些历史目标。

### 早期 rc 的历史 rc.17 升级检查

2026-09-29 补充：旧版本可能保存了不完整的 TCP 缓冲原值。历史命令仅供追踪，执行任何旧版 rollback 前必须先满足[原值完整性与恢复条件](platform-support.md#旧状态与迁移)；旧版自身报告 verify 成功不能证明原始三元组完整。

**历史 rc.16 直接升级到 rc.19 的完整步骤见[下文专节](#从-rc16-升级到-rc19)。** 下列固定 rc.17 的命令保留为历史只读检查示例，不是 rc.16→rc.19 的迁移入口。

由 rc.9–rc.16 管理的 VPS，在 rc.17 发布后可下载 rc.17 总控并执行 `update`。该操作读取状态中的资源档和端口带宽，校验当前 profile、目标 `SHA256SUMS` 和目标总控脚本，然后依次运行当前版本的 `verify` 与目标版本的只读 `update-preflight`。输出包括维护窗口所需的固定 URL、SHA-256 和迁移顺序。`update` 不执行 `rollback`、purge、`apply`、`reconfigure` 或重启，也不替换已发布的旧 Release 资产。

总控、`SHA256SUMS` 和 profile 构成一个不可拆分的 Release 包。不同版本的资产不得放在同一目录。例如，rc.16 总控不能与 rc.17 的 `SHA256SUMS` 和 profile 混放；总控检测到版本不一致时会拒绝执行，且不会自动改用联网下载。以下联网命令和后续回滚示例均使用独立的 `mktemp -d` 目录。

```bash
(
  set -e

  dvt_tmp="$(mktemp -d)"
  trap 'rm -rf -- "$dvt_tmp"' EXIT

  curl --fail --show-error --silent --location \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 15 \
    --max-time 120 \
    -o "$dvt_tmp/debian-vps-tuning.sh" \
    https://github.com/alieismy/debian-vps-tuning/releases/download/v0.1.0-rc.17/debian-vps-tuning.sh

  printf '%s  %s\n' \
    '2530f70a5a675c4733d5bc0109ccbcc35daee23a9e460d920a4b346a3216bfc7' \
    "$dvt_tmp/debian-vps-tuning.sh" | sha256sum -c -

  bash "$dvt_tmp/debian-vps-tuning.sh" update
)
```

使用 `update --target v0.1.0-rc.17` 可指定目标版本。自动发现不跨 `major.minor` 发布线：当前版本为 rc 时，可选择同线更高 rc 或稳定版；当前版本为稳定版时，自动排除 prerelease。跨线升级必须通过 `--target` 指定目标，且仍会拒绝降级和重复升级。显式指定 prerelease 视为主动选择，不受稳定通道的自动排除规则限制。

`update` 只检查升级兼容性并生成操作计划，不改写磁盘上的旧脚本、系统配置或 3X-UI。检查通过不表示升级完成。维护窗口内仍需按输出和对应历史流程顺序执行 rollback/purge、重启、目标版本的 `preflight`/`apply`、再次重启及 `verify`。GitHub API 查询失败或触发匿名速率限制时，可用已审阅的 `--target` 跳过自动发现；目标 Release 资产仍会接受校验。

跨版本可以采用“清除旧版后安装最新版”，但清除必须由**旧版固定 Release**根据旧状态执行
`verify → rollback/purge`。不得手工删除 sysctl 文件、unit、状态目录或 swap，也不得让新版
`apply` 覆盖旧版 state。旧版恢复检查和第一次重启通过后，才进入最新版
`preflight/apply → reboot → verify`。若旧状态缺失、损坏或来自没有可靠状态契约的早期脚本，
应先保存只读证据，再使用对应旧版恢复逻辑、经审查的人工清理，或在业务备份和控制台均已
验证时干净重装 OS。干净重装是独立恢复路径，不等于在原系统手工删除文件。

### 从 rc.16 升级到 rc.19

历史流程补充限制（2026-09-29）：若 `original_sysctls` 中的 `net.ipv4.tcp_rmem` 或 `net.ipv4.tcp_wmem` 只有一个字段，停止在只读检查，不执行下列 rollback/reboot。旧版恢复代码不能补回缺失原值；处理边界见[旧状态与迁移](platform-support.md#旧状态与迁移)。

**可以直接迁移，不必先经过 rc.17/rc.18。** 以下编号流程适用于主机仍由原版 rc.16 管理、`dvt --version` 显示 rc.16、现有 profile 的 `status`/`verify` 通过且状态为 `VERIFIED` 的情况；目标系统、资源档及 100–1000 Mbps 端口带宽也须仍落在 rc.19 支持范围内。若 `dvt` 总控已提前切到 rc.19、但状态仍记录 rc.16，请改用[下文的混合版本入口](#总控已是-rc19但状态仍是-rc16)，不要用 rc.19 的 `dvt status`/`verify` 代替旧 profile 核验。其他版本、状态或原版核验不符时，停在只读盘点，不运行 `recover`、`apply`、`rollback` 或覆盖状态文件。rc.19 的发布只验证了 Linux fixture 与资产完整性，不能代替这台 VPS 的迁移验收。

迁移会撤销 rc.16 受管配置（包括清理由它创建的 swap），然后应用 rc.19 配置，**需要两次人工重启**。在维护窗口前确认服务商控制台/救援入口可用、系统与代理业务备份可恢复、SSH 管理路径和内存余量足够。以下每个代码块均在被迁移 VPS 的 root shell 执行；任一命令失败即停止，不跳过 checkpoint 阶段，也不要把不同版本的总控、清单和 profile 放在同一目录。

1. **只读核对 rc.16 状态并取得固定 rc.19 总控。** 下方目录必须尚不存在；已存在时先检查旧任务，不覆盖或换名绕过。下载后用固定 SHA-256 校验，`update` 依次验证 rc.16 来源与 rc.19 目标的只读预检，不会回滚或应用配置。

   ```bash
   set -Eeuo pipefail
   test "$(id -u)" -eq 0
   dvt --version
   dvt status
   dvt verify
   test ! -e /root/dvt-rc16-to-rc19
   test ! -L /root/dvt-rc16-to-rc19
   install -d -m 0700 /root/dvt-rc16-to-rc19
   curl --fail --show-error --silent --location \
     --proto '=https' --proto-redir '=https' \
     --connect-timeout 15 --max-time 120 --max-redirs 5 \
     --remove-on-error \
     -o /root/dvt-rc16-to-rc19/debian-vps-tuning.sh \
     https://github.com/alieismy/debian-vps-tuning/releases/download/v0.1.0-rc.19/debian-vps-tuning.sh
   printf '%s  %s\n' \
     'fb3d69bf9ca4bdf2a961411d8262fd77950c7f72f68ecb886e33ae3d3509f84e' \
     /root/dvt-rc16-to-rc19/debian-vps-tuning.sh | sha256sum -c -
   bash /root/dvt-rc16-to-rc19/debian-vps-tuning.sh update --target v0.1.0-rc.19
   ```

   预期升级计划显示来源 `0.1.0-rc.16`、目标 `v0.1.0-rc.19`、当前 profile 及保留的端口带宽，最后输出“升级检查通过；系统配置未修改”。这一步仍未完成升级。特别注意，当前安装的 `dvt` 仍是 **rc.16**：下一个 `migrate prepare` 必须调用刚校验的 **rc.19 总控**，不能直接运行 `dvt migrate prepare`。该总控会从固定 Release 校验并取得旧版 profile、目标 profile 和迁移工具。

2. **准备 checkpoint，核对后才进入写入阶段。** checkpoint 路径也必须尚不存在。`prepare` 会创建 root-only checkpoint、复制并固定两版 profile 和迁移器，但不修改当前受管配置。

   ```bash
   set -Eeuo pipefail
   test ! -e /var/lib/debian-vps-tuning-migrations/rc16-to-rc19
   test ! -L /var/lib/debian-vps-tuning-migrations/rc16-to-rc19
   bash /root/dvt-rc16-to-rc19/debian-vps-tuning.sh migrate prepare \
     --checkpoint /var/lib/debian-vps-tuning-migrations/rc16-to-rc19
   bash /var/lib/debian-vps-tuning-migrations/rc16-to-rc19/dvt-migrate.sh status \
     --checkpoint /var/lib/debian-vps-tuning-migrations/rc16-to-rc19 |
     jq -e 'select(.phase=="PREPARED" and .source_version=="0.1.0-rc.16" and .target_version=="0.1.0-rc.19") | {phase,source_version,target_version,profile_id,port_speed_mbps}'
   ```

3. **在维护窗口回滚旧版并重启。** 此步使用 checkpoint 内固定的 **rc.16 profile** 执行 `PURGE_CREATED_SWAP=1 rollback`，会更改主机配置。命令成功并提示第一次重启后，人工执行 `reboot`，再从控制台或 SSH 确认主机重新可达。

   ```bash
   set -Eeuo pipefail
   bash /var/lib/debian-vps-tuning-migrations/rc16-to-rc19/dvt-migrate.sh rollback \
     --checkpoint /var/lib/debian-vps-tuning-migrations/rc16-to-rc19
   reboot
   ```

4. **第一次重启后应用 rc.19，再人工重启。** `continue` 会验证 boot ID 已变化，执行目标 profile 的 `preflight`/`apply`，并写入第二次重启门禁。若它失败，保留 checkpoint 和现场输出，先诊断，不重复 `apply` 或手工修改 state。

   ```bash
   set -Eeuo pipefail
   bash /var/lib/debian-vps-tuning-migrations/rc16-to-rc19/dvt-migrate.sh continue \
     --checkpoint /var/lib/debian-vps-tuning-migrations/rc16-to-rc19
   reboot
   ```

5. **第二次重启后完成严格核验，最后切换 `dvt` 安装入口。** 第二次 `continue` 只有在 boot ID 再次变化且目标 `verify` 形成 `VERIFIED` 后才把 checkpoint 标记为 `COMPLETE`。此前不要运行 rc.16 的 `dvt verify` 来判断 rc.19 状态；`dvt` 的安装入口要在 checkpoint 完成后才更新。

   ```bash
   set -Eeuo pipefail
   bash /var/lib/debian-vps-tuning-migrations/rc16-to-rc19/dvt-migrate.sh continue \
     --checkpoint /var/lib/debian-vps-tuning-migrations/rc16-to-rc19
   bash /var/lib/debian-vps-tuning-migrations/rc16-to-rc19/dvt-migrate.sh status \
     --checkpoint /var/lib/debian-vps-tuning-migrations/rc16-to-rc19 |
     jq -e 'select(.phase=="COMPLETE" and .source_version=="0.1.0-rc.16" and .target_version=="0.1.0-rc.19") | {phase,source_version,target_version,profile_id}'
   curl --fail --show-error --silent --location \
     --proto '=https' --proto-redir '=https' \
     --connect-timeout 15 --max-time 120 --max-redirs 5 \
     --remove-on-error \
     -o /root/dvt-rc16-to-rc19/install.sh \
     https://github.com/alieismy/debian-vps-tuning/releases/download/v0.1.0-rc.19/install.sh
   printf '%s  %s\n' \
     '3bef587d479f5771da9af8d193baa63b7a7f8480016adf5514dfc944429a8ed3' \
     /root/dvt-rc16-to-rc19/install.sh | sha256sum -c -
   bash /root/dvt-rc16-to-rc19/install.sh --no-launch
   dvt --version
   dvt status
   dvt verify
   ```

   最后还需独立确认控制台/SSH、3X-UI/Xray 服务和真实客户端业务连接。安装器只切换 `dvt` 文件入口，不执行 `apply`；旧版目录、checkpoint 与备份保留供核验和恢复，不因命令完成而立即删除。此流程不运行 `probe`/iperf3，也不宣称线路性能改善。

#### 总控已是 rc.19，但状态仍是 rc.16

这种中间状态下，`dvt status`/`verify` 调用 rc.19 profile；该 profile 要求自己的版本与 schema 4 状态中的 `script_version` 一致，因此可能把有效的 rc.16 状态报告为笼统的“状态文件为空、损坏、包含多份 JSON 或 schema/profile 不匹配”。**单凭这条报错不能判断状态已损坏，也不能据此运行 `recover`。** 先只读检查 `state.json` 是 root 所有的非空普通文件、只有一个 JSON 对象且标明 rc.16；然后运行 `dvt update --target v0.1.0-rc.19`。当前 rc.19 总控会从固定 rc.16 Release 获取并校验来源 profile，用它执行旧版 `verify`，再执行 rc.19 目标只读预检。任一步失败都停止；不能把仅通过 JSON 结构检查当作可迁移证明。

```bash
set -Eeuo pipefail
STATE=/var/lib/proxy-vps-tuning/state.json
test "$(id -u)" -eq 0
test -f "$STATE" && test ! -L "$STATE" && test -s "$STATE"
test "$(stat -c '%u' "$STATE")" = 0
jq -e -s 'length == 1 and (.[0] | type == "object" and .schema_version == 4 and .script_version == "0.1.0-rc.16" and (.profile.id | type == "string") and (.network.port_speed_mbps | type == "number"))' "$STATE"
dvt update --target v0.1.0-rc.19
```

仅在输出“升级检查通过；系统配置未修改”且来源 `verify`、目标预检均成功后，使用已安装的 rc.19 总控准备 checkpoint；不必重新运行上面第 1 步的 `dvt status`/`verify`，也不需要另建目录下载总控。下面路径也必须尚不存在：

```bash
set -Eeuo pipefail
test ! -e /var/lib/debian-vps-tuning-migrations/rc16-to-rc19
test ! -L /var/lib/debian-vps-tuning-migrations/rc16-to-rc19
dvt migrate prepare --checkpoint /var/lib/debian-vps-tuning-migrations/rc16-to-rc19
bash /var/lib/debian-vps-tuning-migrations/rc16-to-rc19/dvt-migrate.sh status \
  --checkpoint /var/lib/debian-vps-tuning-migrations/rc16-to-rc19 |
  jq -e 'select(.phase=="PREPARED" and .source_version=="0.1.0-rc.16" and .target_version=="0.1.0-rc.19") | {phase,source_version,target_version,profile_id,port_speed_mbps}'
```

此后按上面第 3、4 步使用 checkpoint 内固定的迁移器，完成旧版回滚与两次人工重启；第 5 步执行到 `COMPLETE` 检查为止。由于 `dvt` 入口已经是 rc.19，跳过第 5 步的安装器下载和 `--no-launch`，直接执行 `dvt --version`、`dvt status`、`dvt verify`，并独立检查业务。中途失败时保留现场和 checkpoint，不跳阶段。

### 从 rc.15 升级到 rc.16

rc.16 不改变 17 个受管 sysctl、BBR + fq、自动缓冲矩阵、swap、journald、NOFILE、schema 4、预算 ledger 或迁移 checkpoint。新增的是 benchmark 硬超时/进程组回收与策略路由只读证据。先从独立目录运行 rc.16 总控的只读 `update --target v0.1.0-rc.16`；维护窗口确认控制台和备份后执行：

```bash
dvt migrate prepare --checkpoint /var/lib/debian-vps-tuning-migrations/rc15-to-rc16
bash /var/lib/debian-vps-tuning-migrations/rc15-to-rc16/dvt-migrate.sh rollback --checkpoint /var/lib/debian-vps-tuning-migrations/rc15-to-rc16
# 人工 reboot；确认 boot ID 已变化后：
bash /var/lib/debian-vps-tuning-migrations/rc15-to-rc16/dvt-migrate.sh continue --checkpoint /var/lib/debian-vps-tuning-migrations/rc15-to-rc16
# 再次人工 reboot；确认 boot ID 已变化后重复 continue，执行最终 verify：
bash /var/lib/debian-vps-tuning-migrations/rc15-to-rc16/dvt-migrate.sh continue --checkpoint /var/lib/debian-vps-tuning-migrations/rc15-to-rc16
```

编排器固定复制 rc.15 与 rc.16 profile、校验摘要和 boot gate；它不自动重启，也不替代服务商控制台、维护窗口、严格代理验证或真实业务冒烟。任一步中断时按 checkpoint 的 `phase` 恢复，不手工删除旧状态或跳过重启。

### 从 rc.14 升级到 rc.15

rc.15 不改变 17 个受管 sysctl、BBR + fq、自动缓冲矩阵、swap、journald、NOFILE 或 schema 4。新增的是共享流量预算 ledger 与持久化迁移 checkpoint。先从独立目录运行 rc.15 总控的只读 `update --target v0.1.0-rc.15`；维护窗口确认控制台和备份后执行：

```bash
dvt migrate prepare --checkpoint /var/lib/debian-vps-tuning-migrations/rc14-to-rc15
bash /var/lib/debian-vps-tuning-migrations/rc14-to-rc15/dvt-migrate.sh rollback --checkpoint /var/lib/debian-vps-tuning-migrations/rc14-to-rc15
# 人工 reboot；确认 boot ID 已变化后：
bash /var/lib/debian-vps-tuning-migrations/rc14-to-rc15/dvt-migrate.sh continue --checkpoint /var/lib/debian-vps-tuning-migrations/rc14-to-rc15
# 再次人工 reboot；确认 boot ID 已变化后重复 continue，执行最终 verify：
bash /var/lib/debian-vps-tuning-migrations/rc14-to-rc15/dvt-migrate.sh continue --checkpoint /var/lib/debian-vps-tuning-migrations/rc14-to-rc15
```

编排器固定复制旧版与目标版 profile、校验摘要和 boot gate；它不自动重启，也不替代服务商控制台、维护窗口、严格代理验证或真实业务冒烟。任一步中断时按 checkpoint 的 `phase` 恢复，不手工删除旧状态或跳过重启。

### 从 rc.13 升级到 rc.14

rc.14 不改变 17 个受管 sysctl 的集合、BBR + fq、自动缓冲矩阵、swap、journald、NOFILE 或 schema 4 基础结构；新增的是显式带宽重配置事务和恢复元数据。由于 profile 版本和哈希已变化，rc.14 不得对 rc.13 状态直接执行 `apply` 或 `reconfigure`。

rc.14 发布后，先用其总控执行 `update --target v0.1.0-rc.14` 做只读检查。在维护窗口使用固定且已校验的 rc.13 Release 执行 `verify`、`PURGE_CREATED_SWAP=1 rollback` 和重启，再从独立目录运行 rc.14 `preflight`、`apply`、重启和严格 `verify`。建立 rc.14 `VERIFIED` 状态后，服务商后续改变端口带宽才使用 `reconfigure`。

### 从 rc.12 升级到 rc.13

rc.13 不改变 rc.12 的 17 个受管 sysctl、qdisc、自动缓冲矩阵、swap、journald、NOFILE 或 schema 4 状态结构。变化仅包括只读 TCP 诊断字段、TcpQuality `v1.00013` 固定资产与流级重传证据契约，以及 HTB 实验器对当前脚本版本的绑定。由于 profile 版本与哈希已经变化，rc.13 仍不得直接对 rc.12 状态执行 `apply`。

迁移管理状态时，先用 rc.13 总控执行 `update --target v0.1.0-rc.13` 做只读检查。检查通过后，在维护窗口使用固定且已校验的 rc.12 Release 依次执行 `verify`、`PURGE_CREATED_SWAP=1 rollback` 和重启；随后从独立目录运行 rc.13 的 `preflight`、`apply`、重启及严格 `verify`。如只需新诊断或 TcpQuality 证据能力，可继续由 rc.12 管理配置生命周期，并从独立目录运行 rc.13 的只读/独立工具；不得用 rc.13 `apply` 改写 rc.12 状态。

### 从 rc.11 升级到 rc.12

rc.12 不改变 rc.11 的 17 个 sysctl、qdisc、自动缓冲矩阵、swap、journald 或 NOFILE。状态 schema 升级为 4，用于记录厂商 `/etc/sysctl.conf` 的原始哈希、备份、迁移后哈希和恢复状态；只有只读 `update-preflight` 可以读取合法的 schema 3 状态。rc.12 不得直接对已有 rc.11 状态执行 `apply`。新增测量能力包括结构化 benchmark 证据和独立 TcpQuality 证据工具。

迁移管理状态时，先用 rc.12 总控执行 `update --target v0.1.0-rc.12` 做只读检查。检查通过后，在维护窗口使用固定且已校验的 rc.11 Release 依次执行 `verify`、`PURGE_CREATED_SWAP=1 rollback` 和重启；随后从独立目录运行 rc.12 的 `preflight`、`apply`、重启及严格 `verify`。

如果只需要新增测量能力，可继续由 rc.11 管理配置生命周期，并从独立目录执行 rc.12 的只读 `diagnose`、显式授权的 `benchmark` 或 `tcpquality-evidence.sh`。不得用 rc.12 的 `apply` 改写 rc.11 状态。

### 从 rc.10 升级到 rc.11

rc.11 不改变 rc.10 的 17 个 sysctl、qdisc、swap、journald、NOFILE 或状态结构；主要新增内容是只读 `diagnose` 和用户授权的 `benchmark`。由于六份 profile 的脚本版本和 SHA-256 已改变，rc.11 不得直接对已有 rc.10 状态重复执行 `apply`。

先用 rc.11 总控执行 `update --target v0.1.0-rc.11` 做只读检查。检查通过后，在维护窗口使用固定且已校验的 rc.10 Release 依次执行 `verify`、`PURGE_CREATED_SWAP=1 rollback` 和重启；随后从独立目录运行 rc.11 的 `preflight`、`apply`、重启及严格 `verify`。rc.10 与 rc.11 的总控、清单和 profile 不得放在同一目录。

如果只需要新增诊断或 benchmark，而不迁移管理状态，可继续由已安装的 rc.10 管理配置生命周期，并从独立临时目录运行 rc.11 profile 的只读 `diagnose` 或显式授权的 `benchmark`。不得用 rc.11 的 `apply` 覆盖 rc.10 状态。

### 从 rc.8/rc.9 或旧 v5/v6 升级到 rc.10

`tcpFastOpen` 查询无输出不是必须升级的故障。rc.10 只增加检测和说明，不修改 3X-UI/Xray 配置。其主要配置变化是按 512M、1G 和 2G 使用 1×、1.25× 和 1.5× BDP 档位；200 Mbps 仍为 16 MiB，1000 Mbps 下的 1G 和 2G 分别为 32 MiB 和 64 MiB。

对已经由 rc.8 或 rc.9 管理、且 `/var/lib/proxy-vps-tuning/state.json` 有效的主机，先使用该历史版本对应的 rc.10 总控的 `update --target v0.1.0-rc.10` 做只读兼容性检查并保存它输出的 URL、SHA-256、profile 和端口带宽。检查通过后，另选维护窗口。以 rc.9 为例，应在独立临时目录重新下载并校验 rc.9 总控，再由 rc.9 固定 Release profile 完成 verify/rollback/purge：

```bash
(
  set -e

  dvt_rc9_tmp="$(mktemp -d)"
  trap 'rm -rf -- "$dvt_rc9_tmp"' EXIT

  curl --fail --show-error --silent --location \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 15 \
    --max-time 120 \
    -o "$dvt_rc9_tmp/debian-vps-tuning.sh" \
    https://github.com/alieismy/debian-vps-tuning/releases/download/v0.1.0-rc.9/debian-vps-tuning.sh

  printf '%s  %s\n' \
    '09cbb77591760fa1789729c31f64e03b29f145f50c8c419bca6057b23f492979' \
    "$dvt_rc9_tmp/debian-vps-tuning.sh" | sha256sum -c -

  bash "$dvt_rc9_tmp/debian-vps-tuning.sh" verify

  env PURGE_CREATED_SWAP=1 \
    bash "$dvt_rc9_tmp/debian-vps-tuning.sh" rollback
)

dvt_rc9_status=$?
printf 'rc9_rollback_exit=%s\n' "$dvt_rc9_status"
[ "$dvt_rc9_status" -eq 0 ] || exit "$dvt_rc9_status"

reboot
```

重新登录后，在另一个独立临时目录中下载并校验 rc.10 总控，执行 `preflight --port <原状态中的端口带宽>`。预检通过后，再执行 `apply --port <相同带宽>`、重启和 `verify`。已安装 3X-UI 时，还应使用该历史版本的严格代理验证；不能借用当前安装入口完成旧版核验。

`PURGE_CREATED_SWAP=1` 只尝试删除状态确认由本项目创建的 `/swapfile-proxy`。如果 `swapoff` 失败，脚本会保留 swap、fstab 行和状态，不能强制删除。外部 swap 不归 rollback 管理，也不会被删除。任何步骤失败后都应停止并保留当前状态；不得跳过重启或直接执行后续 `apply`。

旧 v5/v6 不具备 rc.8+ 的状态与所有权契约，rc.10 无法判断原 sysctl、qdisc 或 swap 的归属。迁移前应保存 `sysctl`、`tc -j qdisc show`、systemd unit、swap 和旧脚本备份，按对应旧脚本的清理流程退出旧配置并重启。确认旧 sysctl/service 文件不再生效后，才能运行 rc.10 `preflight`。出现 sysctl 冲突时，必须按实际文件归属合并或移除；rc.10 的 `rollback` 不能作为旧脚本的卸载器。

### rc.2 空状态恢复

早期 rc.2 曾在初始 JSON 构造失败时留下空 `state.json`，但 qdisc 快照仍然存在。`recover` 只处理这一已知的“首次系统写入前”遗留场景，并要求显式确认：

```bash
env ALLOW_EMPTY_STATE_RECOVERY=1 \
  bash ./debian12-1c1g-vps-tuning.sh recover
```

只有满足以下全部条件时，`recover` 才会隔离状态目录：`state.json` 是空 JSON 流；不存在项目管理文件；不存在 `/swapfile-proxy` 或对应 fstab 行；fq helper 未运行；当前 qdisc 与保存快照的语义一致。原状态目录会改名保留，不会删除。一般 JSON 损坏、有效状态，或无法证明问题发生在首次系统写入前的情况，不得使用 `recover`。
