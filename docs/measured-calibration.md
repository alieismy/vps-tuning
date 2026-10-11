# 实测校准第一阶段：离线画像与缓冲建议

状态：随 rc.19 Pre-release 提供的仓库源码工具；这是工具行为说明，不是性能验收或生产应用批准。

当前工作树的校准器为 **0.1.2 候选**，在原 rc.17/rc.18/rc.19 白名单上增加 `0.2.0-rc.1` 和未发布 `0.2.0-rc.2` 的同格式受管 probe。仅有离线兼容检查，未新增这两个版本的真实采集证据。新独立 `measure` 使用不同 schema，不能输入本校准器；其报告入口见[独立测量说明](automatic-measurement.md)。以下 rc.19/0.1.1 实测记录保留原有证据范围。

## 使用范围

`tools/calibrate_probe.py` 在分析工作站读取已有 `dvt probe` 证据，不连接 VPS、不调用 iperf3，也不写入输入证据或系统配置。使用 Python 3.10+ 标准库；从完整仓库运行，资源倍率和上限直接读取 `tools/render_profiles.py` 的 `PROFILES`，不增加 VPS 安装依赖。该工具当前不随 17 项 Shell 安装资产分发，也不是 `dvt` 子命令。

示例（路径为占位示例，替换成已保存的 probe 目录）：

```powershell
python tools/calibrate_probe.py --evidence 'D:\Evidence\probe-run' --path-label eu-client --representative-path
```

Linux/macOS 分析工作站可使用 `python3` 和对应本地路径。输出为 stdout JSON；正常形成建议或“证据不足”时退出 0，输入完整性/结构错误时退出 2，不输出部分建议。需要保存时由调用者重定向到新的报告文件。

`--representative-path` 表示操作者确认此端点可代表拟评估路径，不表示真实代理业务已验收。未提供时仍可查看画像，但不生成配置候选。`--max-age-hours` 默认 24，允许 1–168；这是可见的筛选政策，不是网络证据普遍有效期。分析历史档案必须理解当时路径与当前路径的差别。

## 输入与证据边界

- 输入必须是已解包的完整 probe 目录；不接受单个 iperf3 JSON、压缩包或手填 RTT。
- 校验顶层和各样本的 `COMPLETED`、`SHA256SUMS`、result 摘要与嵌入元数据；必要原始文件必须出现在相应清单。拒绝 INCOMPLETE、重复 JSON 字段、非规范清单路径和文件符号链接；每文件上限 32 MiB，总读取上限 256 MiB。
- 生产端的顶层清单会按文件名排除各层 `SHA256SUMS`、`SHA256SUMS.tmp`、`COMPLETED` 和 `INCOMPLETE`。校准器单独读取子样本控制文件，并通过顶层已验的 `benchmark-result.json.evidence_manifest_sha256` 绑定子清单；完成标记中的结果摘要也必须匹配。子控制文件的读取计入总上限，不因未列入顶层清单而免除完整性校验。
- 分析器 0.1.2 仅接受 probe schema 1、benchmark result schema 1、phase summary schema 3、单流 TCP，以及同一 VERIFIED profile、白名单版本（rc.17/rc.18/rc.19 或 0.2.0-rc.1/rc.2）、脚本摘要、网络配置和启动周期。新增版本支持依据其相同的采集/汇总代码及资源定义；不放宽其他一致性门禁。一份 rc.17/iperf3 3.18 的真实完整上传 probe 已通过格式兼容核验，见[项目备忘](project-memo.md)；其他版本、方向和环境不能据此视为实测通过。现有 schema 无变化。摘要证明输入内部完整性，不构成来源签名或真实运行的独立证明；应保留可信采集来源。
- 顶层清单中的 `sample-NN` 集合必须与 `samples` 引用集合完全一致；重复轮次方向完整，`aggregates` 必须包含 upload/download 两个方向。已测方向的 `samples/valid_windows` 必须是整数，并与引用行数、已核对的 row/summary 有效窗口标记计数一致；未测方向必须为 null。不能通过删掉最后一轮引用或修改汇总计数跳过清单内的异常样本。
- 本工具要求 metadata 的 `benchmark.seconds/omit_seconds` 与 raw 的 `start.test_start.duration/omit` 均存在、为整数并逐项相等，范围分别为 5–120 秒、0–10 秒；重复样本的请求时长、预热、请求协议族和方向必须一致。缺失或矛盾属于输入契约错误（退出 2），不补默认值。该契约依据现有生产端参数与仓库 iperf3 fixture；真实旧版 iperf3 输出兼容性仍需用完整证据验证。实际 `end` 窗口时长继续使用原有 `max(0.25 秒, 请求时长的 5%)` 容差，不要求与请求值精确相等。
- 从原始 `end.sum_sent`/`sum_received` 重新核算字节、时长、吞吐，并对照 summary/row。观察到无效窗口、缺失 RTT、路径漂移或重复不足时，该方向不生成候选。校验各重复样本的方向完整性，IPv4-mapped IPv6 按实际 IPv4 解释。
- 输出使用操作者指定的匿名路径标签，不回显端点地址、主机名、启动 ID 或本机路径；输入证据仍可能含敏感信息，须在适当位置保存。

## RTT 与 BDP 的含义

RTT 来自原始 iperf3 `end.streams[].sender.min_rtt/mean_rtt/max_rtt`，单位为微秒。工具按方向汇总每次运行的最小值和均值，输出中位数与 MAD（中位数绝对偏差）。这是负载期间的观测，不是空闲 RTT；旧 iperf3 或反向测试未提供 sender RTT 时返回证据不足，不借用另一方向或固定 150ms。

候选 RTT 使用重复样本的 `min_rtt` 中位数向上取整到毫秒，下限为现有支持范围的 20ms；任一样本最小 RTT 超过 500ms 时不外推。重复最小 RTT 的 MAD 超过中位数的 25% 时暂停建议；这是首版明确公开的描述性筛选规则，不声称统计显著性。任一样本 sender 速率超过 cap 的 110% 也暂停建议；10% 是计量筛选容差，不是允许突破流量预算的授权。

BDP 候选以受管状态中的**声明套餐带宽**乘上述 RTT，再使用现有资源 profile 倍率和 16/32/64 MiB 档位封顶。观测吞吐单独展示，不把限速 probe 的吞吐当作套餐容量，也不因吞吐偏低就缩小窗口。单一路径不足以支持减小全局 socket 缓冲上限。

| 方向结果 | 行为与下一步 |
|---|---|
| `KEEP_CURRENT_CEILING` | 当前上限覆盖本次公式候选，保留上限；不证明业务性能已最优 |
| `EXPERIMENT_CANDIDATE` | 提供较大缓冲及 RTT 候选，须核对 CPU/队列证据并做单变量对照；不输出 apply 命令 |
| `RESOURCE_LIMITED` | 公式目标超出资源档位上限，报告限制；不能绕过内存保护自动扩大 |
| `INSUFFICIENT_EVIDENCE` | 列出原因，候选字段为 null；先处理缺口，不补造测量结果 |

不同方向分别决策，不合并成全局最优配置。报告不证明服务商 policer、性能收益、真实代理业务改善，也不修改 `PORT_SPEED_MBPS`、RTT、buffer 或 qdisc。当前 `reconfigure` 仍只支持端口变更。

## 三个小范围吸收项

1. HTB `rate-sweep-analyze.sh` 增加每档 `receiver_divergence_review`。只有全部原有门禁有效、首尾 reference 的 sender/retrans 与 receiver 可比较时才判断：候选 sender 的 median−MAD 高于另一档的 median+MAD，同时 receiver 的 median+MAD 低于另一档的 median−MAD，则列出需要人工复核的比较档位。该描述性提示不改变 sender 主指标、既有 shortlist 或生产授权；无效/漂移证据为 `NOT_EVALUATED`。离线分析接受 rc.18/rc.19 的原有严格绑定，实时 HTB runner 仍要求当前版本。
2. swap 定向 fixture 使用 29 项、每个路径不超过 Linux 路径长度限制的输出，并控制分段写出：原 `grep -q` 管道可返回 141，完整读取后返回 0。修正仅覆盖四个对应调用点，同时测试无 swap 和生产者失败。它是目标表达式的有效输出复现，不是真实主机 swapon 生命周期验收。
3. `flock` 仍是唯一锁仲裁机制。获取锁后记录 PID、`/proc/PID/stat` starttime 和 uptime，冲突时身份匹配才显示持锁时长。竞争者不截断锁文件、不接管、不杀进程、不显示命令行；信息缺失或过时时只报通用冲突。持锁时间是瞬时观测值。

## 验证与后续

真实采集目录的导出、可选有预算采集、Windows 离线核验及失败处理，见 [rc.19 真实 probe 核验操作单](rc19-probe-validation.md)。优先复用已有 rc.17/rc.18/rc.19 证据；该操作单不要求升级或新增主动测速。

本地可运行 `python -m unittest discover -s tests -p 'test_*.py'`，Shell 定向用例需要 Bash/jq。既有 `tests/static-check.sh` 已调用这组测试；HTB 独立套件覆盖完整分析流程中的 receiver 提示与原 shortlist 保持不变。Linux root 的真实锁竞争、swap、安装/迁移、tc/重启及业务验收由原门禁单独完成。

第二阶段的通用候选实验、第三阶段的 RTT/buffer 应用事务、持久 HTB、PPP 重拨和低速控制点实验仍是后续工作；本轮没有新增测速或生产执行授权。
