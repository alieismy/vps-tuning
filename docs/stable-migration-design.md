# 正式版迁移实施契约

2026-11-24。用户已批准执行[修订方案](stable-release-plan.md)。本轮实施标识为 `0.2.0-rc.6` 本地开发候选，未发布；正式目标保留为 0.2.0。生产维护、重启和公开发布需分别授权。

## 输入与兼容

- 保留 migrate prepare/rollback/continue/status，新增只撤销准备的 cancel。目标须与当前迁移器版本相同，允许目标 rc.6 或正式 0.2.0；来源 rc.4/rc.5，正式目标另外接受 rc.6。正式版本能力不意味着 rc.6 可以执行任意未来目标。
- 当前只接受 Debian 12/13 的既有 profile，端口 1–10000 Mbps；源与目标同 profile，实际 OS/架构/资源由固定 profile 核验。保留已有 ARM64 代码路径，不宣称新实机验收；不扩大 Ubuntu 迁移。
- checkpoint schema 2，与既有 schema 1 分离。旧 checkpoint 使用自己的固定工具，禁止新版原地转换。managed state schema 4 不变。
- prepare 从来源完整 VERIFIED 状态冻结 port、RTT、auto/explicit buffer。已有项目 swap 自动保留其大小意图；未创建项目 swap 时要求显式 `--swap-policy disabled` 或 `--swap-policy create --swap-mib N`，不从 false 推断用户意图。对已有项目 swap 不允许借迁移更改大小/启用策略。
- 可显式指定一个 `--proxy-unit UNIT`；未指定时，在准备时发现已加载 x-ui.service 则绑定它。配置阶段不启用严格运行时代理验证，第二次重启后按绑定 unit 严格验证。

## 持久材料与互斥

checkpoint 位于受管目录外，包含原始 state、队列/厂商恢复文件、固定来源/目标脚本及迁移器。恢复目录清单摘要写入 checkpoint，每次继续都核验；未知源目录内容先拒绝，不代为搬移账本。

单次写操作持有独立 migration flock，与 profile 的 fd 9 锁分离。root-only 的迁移登记目录保存唯一 active checkpoint，跨重启约束未完成任务；只有 COMPLETE 或未执行系统写入的 cancel 释放登记，历史证据不删除。半成品 prepare 保留并停止，不伪造 PREPARED。锁不承诺阻止其他 root/旧工具，维护窗口仍须串行。

所有阶段 JSON 更新先写临时文件，校验后原子替换。每个 boot gate 绑定实际 boot ID；重复 continue 不跳过重启。COMPLETE 重复读取/核验不再次 apply；cancel 只接受 PREPARED 且来源 state 未变。

## 阶段及恢复

PREPARED → ROLLBACK_RUNNING → ROLLED_BACK_REBOOT_REQUIRED → APPLY_RUNNING → TARGET_APPLIED_REBOOT_REQUIRED → VERIFY_RUNNING → COMPLETE。

来源固定脚本 rollback/purge；失败停留并保全。第一次重启后读取并记录来源受管键的实际基线，核对来源原值，不符合则停止；重试 apply 前核验基线未变。目标 apply 成功须 VERIFIED，APPLIED 残留不推进。第二次重启后确认目标、参数、恢复基线、配置与绑定服务，才 COMPLETE。

目标调用使用清洁环境和已冻结选项，来源恢复也隔离继承环境。不可把旧 state 拷回作为回退；目标失败用目标恢复路径，回到来源需单独确认并用固定来源资产重新应用。

## 验证责任与完成边界

本地实际函数测试覆盖版本、参数冻结、环境、快照校验与状态接续；Linux root 测试覆盖登记/并发和完整事务。扩展现有 QEMU runner，以公开 rc.4/rc.5 固定 tag 资产作为来源，真实安装、重启、迁移、重启并验证目标；只在隔离环境执行，不连接 VPS。

W0 盘点仅输出非敏感状态摘要与版本/能力，不输出地址、完整代理配置或凭据。本机无 WSL/Docker/QEMU，因此真实 Linux/七平台运行结果必须由获授权 Linux 环境补齐，不以入口存在计为通过。
