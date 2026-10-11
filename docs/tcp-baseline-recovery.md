# 旧 TCP 快照恢复与新基线迁移候选

状态：`0.2.0-rc.2` 未发布候选。本文和源码工具不构成生产变更授权。适用范围限 Debian 13、`debian13-1c1g` / `debian13-1c2g`、100/200/500 Mbps、来源 rc.11/rc.12/rc.16/rc.17，且两项 TCP 原值均因已确认的旧缺陷保存为字符串 `4096`。

## 恢复语义

首先使用同主机、同部署的应用前证据。证据无法补足时，经操作员明确接受，选择有来源的替代值，并将本次操作记录为新恢复基线的建立过程。工具不宣称恢复了缺失的历史事实。

| 模式 | 值的来源 | 来源记录 |
|---|---|---|
| `historical` | 已核对同主机、同部署的应用前记录 | `historical_originals_recovered=true`；需要显式关联确认和匹配的两个部署时间戳 |
| `replacement` | 已核对的参考记录，或本机当前已验证的完整运行值 | `historical_originals_recovered=false`；需要 `accept_new_baseline=true` |

时间戳、摘要和操作员确认用于绑定证据，不能独立证明一份历史文件真实、完整、从未被修改。参考机与目标机同为 Debian 13 不等于历史值相同。引用当前运行值时，它只作为本次旧版退出时的明确替代值；第一次重启后，实际生效的系统参数才是新版安装前的新基线。

必须区分两类恢复：

- **本次升级失败的恢复点：** 迁移前正常工作的主机配置和业务数据。生产 rollback 前须落实可恢复的系统/业务备份及控制台入口。本工具的文件归档不是整机备份，也不保存 swap 内容或业务数据库。
- **新版未来卸载的恢复点：** 第一次重启后、目标 apply 前实际采集的配置。目标 profile 保存完整原值；迁移器额外记录两项实际 TCP 值，并与目标状态的原值逐项核对。

## 工具及写入边界

[tools/recover_tcp_baseline.py](../tools/recover_tcp_baseline.py) 是源码树中的一次性恢复工具，使用 Python 3 标准库；不是已发布 `dvt` 子命令，也不由安装器部署。运行前应固定整个候选提交并核对工具摘要，来源 profile 则使用已发布版本的固定 SHA-256。不得混用来源和目标 Release 的清单。

| 操作 | 行为 |
|---|---|
| `inspect` | 持既有 DVT 锁、只读输出主机/部署绑定、状态摘要、运行保护摘要和 TCP 值；不生成已批准计划 |
| `prepare` | 核对已批准计划、固定来源 verify 和前后状态；写入新的 root/0700 私有归档，不改受管 state 或系统配置。来源 CLI 的 verify 可使用自己的常规锁元数据入口 |
| `activate` | 持 DVT 锁，重新核对主机/部署、文件、17 项 sysctl、qdisc、swap、boot ID 和归档；只原子更新 state 中两个原值并增加 `tcp_baseline_recovery` 来源记录 |
| `undo` | 仅在文件/运行配置/boot ID 均未变化、state 仍为该候选时，逐字节恢复原始 state；不执行系统回滚 |
| `status` | 验证归档和当前保护条件，识别 PREPARED / ACTIVATED；状态已变化时拒绝，要求核对迁移 checkpoint |

`activate` 不修改当前 TCP、受管文件、版本号、schema、档位、带宽或旧部署时间戳。`original_sysctls` 的两个工作值附带明确来源，原始历史文件另存且保持原字节。不能把工作状态中的替代值单独摘出后称为历史原值。

工具拒绝重复恢复、未知状态、其他原值缺失、源脚本摘要不符、错误或重复证据、跨主机计划、运行漂移、符号链接、不安全权限和锁冲突。状态原子替换中断后以原件/候选摘要判断位置；部分生成的归档没有完整 receipt，不能激活，也不自动覆盖。

## 逐台计划

每台使用独立的 `VPS-NN` 编号、计划及归档目录。地址、machine-id 摘要、实际证据路径和主机计划只保存在私有目录，不进入公开仓库。不得把一台的计划、state、归档或 machine-id 绑定复制给另一台执行。

先在相应主机用已核对的源码工具获取只读材料：

```bash
python3 /root/dvt-recovery/recover_tcp_baseline.py inspect --host-id VPS-01
```

这里的工具路径和编号仅为操作示例；先按实际编号和经核对的文件路径调整。`inspect` 要求 Linux root、现有普通 DVT 锁和 root/0600 state。缺少这些条件时停止，不创建锁或修复权限来掩盖差异。

每份计划包含以下字段，实际值来自该台的 inspect 和已核对资产；不存在可直接跨主机执行的通用计划：

```json
{
  "schema_version": 1,
  "host_id": "VPS-01",
  "approved": false,
  "target_version": "0.2.0-rc.2",
  "binding": {},
  "guard_sha256": "填写该台 inspect 的 guard_sha256",
  "mode": "replacement",
  "accept_new_baseline": false,
  "vectors": {
    "net.ipv4.tcp_rmem": "填写已核对的三个整数",
    "net.ipv4.tcp_wmem": "填写已核对的三个整数"
  },
  "source_profile": {
    "path": "填写固定旧版本 profile 的绝对路径",
    "sha256": "填写固定发布资产的 SHA-256"
  },
  "evidence": {"kind": "current-verified-runtime"}
}
```

`binding` 必须完整复制该台 inspect 对象，包含 machine-id 摘要、当前 state 摘要、来源版本/schema、profile、带宽和两个时间戳。`current-verified-runtime` 的两项值必须与该台当前运行值一致。它们是有意选择的过渡替代值，不是恢复出的历史值。

使用文件证据时，将 `evidence` 改为包含 `kind`、绝对 `path` 和 `sha256` 的对象。文件须包含唯一的 `net.ipv4.tcp_rmem = min default max` 和 `net.ipv4.tcp_wmem = min default max` 行，也接受 key 与值以制表符分隔。历史模式的 `kind` 为 `same-host-same-deployment`，还需 `host_deployment_confirmed=true` 和与 binding 相同的 `timestamps`；参考机证据的 `kind` 为 `reference`，仍属于 replacement。

经逐台审阅后才设置 `approved=true`；replacement 还需 `accept_new_baseline=true`。这些确认代表操作员决策，不是程序证明了证据真实性。

## 与迁移器接续

1. 在已授权的生产维护准备中，以 `prepare --plan /绝对路径/plan.json --archive /绝对路径/新归档目录` 创建归档。归档必须位于旧 `/var/lib/proxy-vps-tuning` 之外；保留 prepare 输出的计划 SHA-256。
2. 核对归档、恢复点与生产变更授权后，以 `activate --archive ... --expect-plan-sha256 ...` 激活工作状态。只激活状态不能证明已升级。
3. 用同一候选版本的固定目标总控重新执行 update 和 migrate prepare。迁移器仍要求完整三元组和来源 verify；对于带恢复记录的 state，还核对主机、候选 state、来源资产和整个恢复归档，将副本及 receipt 摘要写入迁移 checkpoint。
4. 后续按迁移 checkpoint 执行旧版 rollback、第一次重启、目标 preflight/apply、第二次重启、目标 verify。迁移器在第一次重启后记录实际 TCP 基线，目标 state 必须保存相同的完整值；不是以过渡值或参考机值覆盖重启后的真实记录。
5. 要求 checkpoint 为 COMPLETE，并独立完成 SSH、3x-ui 和实际代理业务验收。保留原归档及 checkpoint，不把 CI fixture 或函数级预检当作这一步的证据。

迁移开始前若取消，可在保护条件仍匹配时使用 `undo`；已创建的迁移 checkpoint 会因源 state 摘要变化而拒绝 rollback。rollback 开始后，或目标 state 已生成、发生重启/文件/sysctl/qdisc 变化时，不能使用此 undo。按迁移阶段及系统/业务备份恢复，保留故障现场。工具没有“强制恢复”“忽略漂移”或自动重启入口。

## 验证范围

回归位于 [test_tcp_baseline_recovery.py](../tests/test_tcp_baseline_recovery.py)：五台编号组合、历史/替代来源区别、计划/证据/源码摘要、原件不变、有限字段修改、漂移拒绝、归档损坏、原子写入前后中断、权限和并发锁。Linux root 集成用真实恢复事务和迁移 CLI，profile 与 boot ID 使用临时 fixture，验证来源归档跨阶段保留、两个重启门禁及新版基线采集。

这些测试不修改 CI 宿主内核参数，也不证明生产主机迁移、备份还原或业务验收成功；实际执行结果应另行记录。
