# 跨平台持久配置支持

日期：2026-09-29。适用：`0.2.0-rc.1` 预发行版；第三阶段实现与七组隔离客体生命周期验收完成，范围以本页矩阵和[验证说明](validation.md)为准。旧 rc.19 的公开资产与支持范围不变。

## 平台与资源选择

候选纳入 Debian 12、Debian 13、Ubuntu 24.04 LTS，架构为 `x86_64` 与 `aarch64`。使用原生 systemd 的完整 Linux 主机；需要实际可用的 BBR、fq、sysctl 和可恢复 qdisc，系统名称不替代能力检查。其他 Ubuntu 版本、其他发行版和容器持久化未纳入。

- 原 Debian 四个 CPU/内存组合仍映射原六份 profile，ID、BDP 系数、内存上限、swap/journald 默认保持兼容；ARM64 上也按相同的资源组合选择。
- 其他 Debian 组合选择 `debian12-adaptive` 或 `debian13-adaptive`；Ubuntu 24.04 选择 `ubuntu2404-adaptive`。至少 1 个可用逻辑 CPU、384 MiB 可识别物理内存，不再按最大 CPU/RAM 档位拒绝。
- 已有 `.profile.id` 必须与选择结果一致。跨 OS、资源缩放导致的 profile 切换不自动覆盖旧状态；仍需按原恢复和迁移流程处理。
- 安装器只安装经过同一清单校验的资产。持久 `preflight/apply/verify/reconfigure/rollback` 复用既有事务、文件所有权、mq/fq 拓扑处理与恢复入口。

## 缓冲和带宽策略

受管 `--port` 接受 **1–10000 Mbps**，默认仍为 200 Mbps。此值是服务商套餐上限的配置输入，参与 BDP（带宽时延积）计算，不创建限速器，也不代表通过相应速率的性能验收。

自适应 profile 使用以下明确上限：

```text
socket_cap = min(256 MiB, max(16 MiB, physical_RAM / 32))
BDP_target = port_Mbps × 125 × target_RTT_ms
auto_buffer = min(socket_cap, 向上选择 16/32/64/128/256 MiB)
```

BDP 超过封顶时明确报告 `auto-clamped`；显式 `BUF_MAX` 超过资源上限则拒绝。socket 上限不是预分配内存，也不是所有连接的总内存保证；连接数与业务占用仍须观测。现有 profile 保留 1×/1.25×/1.5×BDP 的策略。全部计算使用字节，不新增 `tcp_mem`，不假定 ARM64 的内存页大小。

新增 profile 默认 `ENABLE_SWAP=0`，管理员仍可显式启用原有受管 swap 事务。journald 使用固定 128 MiB 持久/64 MiB 运行上限，不随物理内存无限放大。17 项受管 sysctl、BBR+fq 默认和非持久 HTB 边界保持。

schema 4 的 `profile` 增加 `os_id`/`os_version` 描述字段；Debian 保留 `debian_version`，Ubuntu 将其置为 `null`。旧 schema 4 读取契约不要求新增字段，不会把 Ubuntu 伪装成 Debian。现有迁移器仍只接受已定义的 rc.1–rc.19 Debian 来源，未为不存在的 Ubuntu 历史版本放宽来源检查。

## 旧状态与迁移

2026-10-04 补充：以下固定 rc.1 路线对旧 schema 4 存在目标预检版本误拒绝，详见[迁移指南的已知问题](migration.md)。修复位于未发布的 [rc.2 候选](releases/v0.2.0-rc.2.md)，其本地 fixture 不继承下方 rc.1 的真实平台生命周期结论。

安装新版本只替换执行入口，不迁移旧 managed state。现有主机应保留原版本脚本和状态，用目标版本的 `update --target v0.2.0-rc.1` 做只读检查，再由目标版本的 `migrate prepare` 检查来源和恢复条件。只有 checkpoint 成为 `PREPARED` 后才可按其输出进入回滚、两次重启和目标 apply/verify；具体命令见[当前迁移指南](migration.md#迁移到-v020-rc1)，不要套用历史 rc.16→rc.19 的命令来迁移新版本。

本轮发现更早版本可能只保存 `tcp_rmem/tcp_wmem` 的第一项。缺少另外两项时，新迁移器拒绝创建 checkpoint，新回滚路径保留状态并拒绝写入。即使项目文件已经消失，仍不能据此证明内核原值已恢复，因此完整性检查也不为“仅清理残留状态”跳过。这是有意保留的恢复边界。

遇到拒绝时，保留状态、原版完整资产和备份，停在只读盘点。只有可核验的应用前快照或原始配置能支持逐项恢复；不能把当前调优值、发行版默认值或同型号主机的值猜作原值，也不要删除/修改状态来绕过检查。没有原始证据时，应在独立恢复任务中评估有业务备份的干净系统重建；本版不能自动补回历史丢失字段。

## 验证矩阵

| 平台 | x86_64 | ARM64 |
|---|---|---|
| Debian 12 | `5b53adc` 完整生命周期通过 | `5b53adc` 完整生命周期通过 |
| Debian 13 | `5b53adc` 完整生命周期通过 | `5b53adc` 完整生命周期通过 |
| Ubuntu 24.04 LTS | `5b53adc` 完整生命周期通过 | `5b53adc` 完整生命周期通过 |

证据来自固定 `5b53adc72320471225c1b3c55bf741703985d81f` 的 [CI 36540841895](https://github.com/alieismy/debian-vps-tuning/actions/runs/36540841895)，七个 job 全部成功，七份归档的大小、GitHub digest 和客体状态均已逐项复核。表中六组 adaptive 外另有 Debian 13 x86_64 legacy，其 1024 MiB swap 创建、重启验证和回滚清理通过。26 项发布文件与该提交及固定运行实现 `9ea12a6` 逐字节一致，后续发布文档同步不改变这些运行资产。

Ubuntu ARM64 首轮在 cloud-init 处理 APT 索引时达到 25 分钟准备期限，尚未执行项目安装。后继测试由同版本 ARM runner 提供官方 jq 依赖包，准备阶段通过，但仍花费约 22 分钟；安装、首次 apply、同值幂等通过后，在重配置过程中达到 600 秒测试期限。两次失败记录均保留，不计为通过。

第二轮客体启用 QEMU `max` 的 QARMA5 指针认证算法。[QEMU 8.2.2 官方说明](https://github.com/qemu/qemu/blob/v8.2.2/docs/system/arm/cpu-features.rst#tcg-vcpu-features)明确指出 QARMA 软件模拟开销高。`5b53adc` 只对 Ubuntu ARM64 TCG 客体使用 `max,pauth-impdef=on`，保留指针认证能力，记录 CPU 模型；它不提供密码强度或硬件性能证据。镜像、产品代码、资源、期限、两次重启与全部恢复断言不变。后继完整生命周期通过：准备约 5.5 分钟、首次应用阶段约 7 分钟，随后两次重启与全部恢复对照通过；这一测试环境修正不修改 VPS 配置。

`tests/platform-vm.py` 使用固定日期目录和官方镜像摘要、一次性 SSH 凭据、严格主机密钥校验和独立 QEMU 客体；生命周期覆盖校验安装、重复安装、preflight、apply、同值幂等、1→10000→1 Mbps 重配置、真实客体重启、verify、rollback 及再次重启。比较 17 项 sysctl、qdisc 参数、受管文件和状态，保存镜像/架构/内存/页大小/boot ID 及运行输出。客体内不执行公网 iperf3，不接触用户 VPS。

adaptive 矩阵的 x86_64 客体为 KVM 4C4G，ARM64 客体在 ARM runner 上使用 QEMU/TCG 2C1536M；legacy 为 x86_64 1C1024M。软件模拟验证的是实际 ARM64 内核与用户态的功能行为，不用于比较性能。更大 RAM 的封顶另由输入边界回归覆盖；本矩阵不能证明特定云厂商 24 GiB 等大内存机型、64 KiB 内存页或其业务性能。

控制器与资源策略另有原有档位、扩展组合、极端输入、缓冲封顶及显式超限的离线回归。它们不能替代上表的原生生命周期，更不能证明 3X-UI/Xray 业务或吞吐改善。

首轮固定 `d38ec3f` 的 x86_64 客体在回滚读回对照中失败：快照采集把 `tcp_rmem/tcp_wmem` 的制表符分隔三元组截为首项，内核接受单值写入但保留后两项。修正保留完整向量、在回滚前拒绝不完整旧快照，并在恢复后读回核对。迁移准备也拒绝缺少原值的来源状态；更早版本丢失的字段不能由本候选自动重建，不应手工猜值或绕过检查。首次失败不记为生命周期通过，后继修正须重新运行。

客体另外覆盖内核自动创建的 `fq 0:` 完整参数恢复、owner SIGKILL 及期限看护接管，不发送公网测试流量。这些属于隔离 VM 证据，不冒充用户业务 VPS 的故障注入验收。

## 与前两阶段的关系

自动 `measure` 仍不修改系统配置。临时 `htb-sweep` 仍只接受单根 fq；Ubuntu/ARM64 的持久 apply 支持不会扩大临时实验到 mq。候选区间必须满足原预算与有效性门禁；未出现可靠拐点并不阻止独立的平台功能验收。持久 HTB 仍是需临时实验与业务对照的独立策略，没有在本候选中启用。

旧 `probe`、离线 `calibrate_probe.py` 和 `dvt htb` 研究入口保留各自的速率/证据范围。离线校准明确拒绝 adaptive profile，不能把生成器中 256 MiB 的绝对封顶误当成小内存主机的实际资源预算；这不影响独立 `measure`、`htb-sweep` 或持久配置生命周期。
