# 测量证据解释工具：设计与使用

创建日期：2026-09-30；更新日期：2026-10-31。工具版本 `0.1.1`，按独立源码 Pre-release 交付；当前交付状态及下载见[0.1.1 发布说明](releases/measurement-explanation-v0.1.1.md)，此前公开版本见[0.1.0 历史说明](releases/measurement-explanation-v0.1.0.md)。本文件维护解释契约，不改变主程序分类器、测量 schema、安装资产或 Release。

## 目标与范围

依据[离线研究](two-host-measurement-acceptance-2026-09-30.md#候选可信度的离线评估)，为既有 `measure` / `htb-sweep` 报告补充原始计数、字节暴露量和候选解释，承接 AM-06/AM-07。没有可信标签集来校准新阈值，因此保留原始分析结果，不输出新限速值、统计置信度、误报率或自动实验授权。

沿用仓库 `tools/` 离线工具形式，入口为 `tools/explain_measurement.py`；完整 checkout 或完整解包目录配合 Python 3 标准库运行，不安装到 VPS、不添加运行依赖，不改变主程序固定发布 bundle。未来若将其并入 `dvt report`，必须进入新的版本及资产验证；当前未集成到已发布 CLI。

## 输入、输出和不变量

```bash
python3 tools/explain_measurement.py --input-dir /path/to/completed-measurement
python3 tools/explain_measurement.py --input-dir /path/to/completed-measurement --json
```

- 输入为单个已完成报告目录；支持 `dvt.path-measurement/1` 和 `dvt.htb-measurement/1`。复用项目 `verify_report()` 的完成标记、清单及 HTB 恢复核验。校验失败退出 2，不生成解释。报告内容本身不构成真实性签名；摘要一致只证明归档内部一致。
- 输出仅到 stdout，默认中文文本，`--json` 输出独立的 `dvt.measurement-explanation/1`，`tool_version` 为 `0.1.1`。本次不增加 JSON 字段或改变原有语义。退出 0 只表示解释成功。源报告、账本、摘要不被改写；未完整测完但已正式结算的部分报告可解释，原拒绝状态保持。
- JSON 的 `source` 包含原测量 schema/version、报告和清单摘要；`original_analysis` 保留原分类、区间和限制字段。输出不包含 IP、源端口或主机路径，不引用未经验证的证据目录脚本。
- `samples` 每行包含 role、rate_mbps、eligible、payload_bytes、retransmits、重算的 retransmits_per_gib、single_event_per_gib、events_at_threshold。计数和字节要求非布尔整数、字节大于零；速率和阈值要求有限正数。计数缺失时该行 `UNAVAILABLE`，保留可用基础字段，不把未知值当零。已有数值类型非法或归一化值不一致则拒绝。
- 中文逐样本输出将缺失字节、计数和阈值所需次数显示为“不可评估”；JSON 仍保留 `null`，不将缺失值补成零。
- `candidate_observation` 只检查原候选对应的 sweep 档，输出阈值命中数、其中单重传样本数、较高档的重复上升/未上升/不完整/未覆盖状态；不把 reference 或低速控制混入普通 sweep 重复数。
- 缺少 `tested_rates`，或汇总遗漏原始样本中实际出现的较高 sweep 档时，高档观察为 `INCOMPLETE`；不能将缺失汇总解释为 `NOT_COVERED`。只有汇总存在且汇总与样本均无更高档时才输出 `NOT_COVERED`。
- 单报告无法证明独立复现，`independent_replication=NOT_ASSESSED`；`htb_entry=NOT_ESTABLISHED_BY_SINGLE_REPORT`。这些是解释边界，不是新分类门禁或对主机能力的否定。
- 同一不可变输入产生同一 JSON；不写时间戳、不联网、不调用远程命令，不保存状态，不需要凭据、root、锁或回滚。与采集并发时应使用冻结副本；摘要失败即停止，不重试到通过。数据库、服务认证和运行状态机不适用。

## 中文覆盖摘要（0.1.1）

按[最小吸收方案](tcpfit-minimal-adoption-plan-2026-10-31.md)，中文路径在原状态、候选和停止原因之后，列出归档计划中的扫描档与期望样本数、样本齐全且原汇总有效的档位，以及无样本、样本不足或含无效样本的档位。该摘要在无候选时也显示；逐样本计数和候选解释保持原有内容。

只在 `verify_report()` 成功后读取已校验摘要的 `plan.json`，按最终 `schedule` 的 `sweep` 项计数，并与实际 sweep 样本、原 `analysis.tested_rates` 对照。已追加的细扫纳入，控制与 reference 不计入；不使用发送 cap、全量 rates 列表或潜在细扫上限推测扫描覆盖。每档所称“有效”沿用原样本标记和原汇总，不重新判断样本质量。

覆盖只描述离散档位，不证明连续速率范围、网络容量或整轮测量成功。中间缺口单独列出；即使所有 sweep 样本齐全，控制漂移、reference 或原停止原因导致的 `INSUFFICIENT_EVIDENCE` 仍保留。合法计划没有 sweep 时显示“无独立扫描档”，不输出 `0/0` 或百分比。

旧计划为空对象、不可解析或所需字段不支持时，只将新增摘要降级为“计划覆盖不可评估”；计划、样本和逐档汇总矛盾时明确“资料不一致”，不补值或声称覆盖完整。该降级不覆盖既有输入拒绝：清单篡改、`INCOMPLETE`、核心文件缺失及 HTB 恢复证据不足仍退出 2。JSON 路径不解析计划内容，保留原契约；文本摘要不写回源归档。

## 数学与解释

`retransmits_per_gib = retransmits × 2^30 / payload_bytes`，单事件量为 `2^30 / payload_bytes`，越过原报告阈值所需整数事件为 `ceil(threshold × payload_bytes / 2^30)`。整数事件使用有理数计算避免浮点整数边界误差。

保留“单事件足以越阈值”与“候选确由单事件重复触发”的区别。高档没有重复上升是候选解释信息，不撤销原候选；位于最高扫描档时明确没有更高档覆盖，不伪造反证。字段不足时只输出不可评估；零重传和无候选均不证明网络健康或无 policer。

## 验证责任与接受条件

独立构造恒定清洁、持续高档上升、低档短突发、最高档候选、无候选、不完整与 HTB reference 场景，验证计数、暴露量、候选解释和原分类不变。另验证清单篡改拒绝、缺失计数、布尔/负数/非有限值拒绝、归一化冲突、整数边界和源目录不变。合成场景只证明契约，不能估算公网误报/漏报率。

再用四轮真实归档做端到端解释，核对与研究及后续复验结论一致且全部源文件摘要不变。运行现有 Python 回归及生成检查，不为离线工具另行执行公网 tc/iperf3 实验。源码纳入仓库自动发现的 unittest 门禁；验收结果必须绑定具体提交与制品，已发布版本的结果见[验证说明](validation.md#测量证据解释工具2026-09-30独立-pre-release)。

`0.1.1` 复用同一测试文件补充覆盖摘要边界，并对照修改前的解释器核验 JSON 只变化 `tool_version`、输入目录不变。本轮只完成离线合成归档验证，没有新增真实归档回读；既有四轮回读属于 `0.1.0` 历史证据。具体范围及结果见[本轮验证](validation.md#coverage-summary-20261031)。

## 后续运行决策

新公网复验、HTB 干预、业务效果和存量迁移分别记录于[累计验收记录](two-host-measurement-acceptance-2026-09-30.md)。本工具不绕过预算，不以单报告替代同路径独立复现或业务授权，也不填补历史 TCP 原值。判据数值调整仍需要独立标签数据与新版本决策。
