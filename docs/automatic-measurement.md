# 独立诊断与公共端点速率阶梯测量

适用：`0.2.0-rc.1` 完整且经过摘要核验的 bundle。实现边界见[第一阶段契约](automatic-measurement-design.md)，研究依据见[可研](tcpfit-policer-refactor-feasibility-2026-09-28.md)。本地适用门禁、[Linux CI](validation.md)及[单机低流量功能验收](automatic-measurement-acceptance-2026-09-28.md)已通过；更多平台上的公网测量、IPv6、高速区间与业务收益仍未验收。持久配置的生命周期证据由[平台支持矩阵](platform-support.md)单独记录。

## 能做什么

`dvt diagnose` 按 Linux 实际能力读取系统、路由、qdisc、TCP 与资源计数，无需 root 或已安装 profile；不可读取项显示 unavailable。`dvt diagnose --managed` 保留原来的 profile 专用增量/代理诊断及支持范围。安装完整新 bundle 不等于对主机 apply，也不升级旧 managed state。

`dvt measure` 在未 apply 的主机上也能运行，不检查 Debian/Ubuntu 名称、amd64/ARM64 或 CPU/RAM 档位。它需要 Python 3.9+、Bash、iperf3、iproute2（ip/tc/ss）、jq、awk、GNU coreutils 及 util-linux（flock/setsid）。`ping` 可缺失，仅影响 RTT 排序。主动测量仍须 root，因为复用 root 所有的共享账本；不自动安装依赖。平台没有相关计数能力时，该样本不能被标为有效。

当前实现只测 **VPS 出向单流 TCP**，用 iperf3 `--bitrate` 控制目标速率，保持当前 qdisc 和 sysctl；已有 HTB 仍会限制结果。1–10000 Mbps 是参数范围，不代表这些速率或所有发行版已运行验证。测试 cap 与服务商套餐、网卡显示速率、实测 goodput 和持久整形值是不同概念。

限速测试建议使用 iperf3 3.18 或含等效修复的版本。3.16 在本轮 CI 的 1 Mbps 测试中因 sender CPU 约 100.7% 被 `CPU_PRESSURE` 拒绝；[ESnet 的 3.18 说明](https://github.com/esnet/iperf/blob/2a2984488d6de8f7a2d1f5938e03ca7be57e227c/RELNOTES.md)明确修复限速 CPU 过高问题。此类拒绝不代表路径容量不足，也不自动授权升级依赖。

## 使用

在完整且经过摘要核验的源码/bundle 根目录中，先看不联网、不写文件的计划：

```bash
bash debian-vps-tuning.sh measure --rate-cap 20 --plan-only
```

安装本版本后也可用 `dvt measure`；固定版本联网入口见 [README](../README.zh-CN.md#安装)，旧 rc.19 安装不含新入口。完整本地 bundle 的安装入口为 `bash install.sh --source-dir "$PWD" --no-launch`。安装会更新 `dvt` 指向，但不迁移受管状态；已有状态的 verify/rollback 继续使用对应原版本脚本，迁移前须检查[原始快照完整性](platform-support.md#旧状态与迁移)。旧 profile 增量诊断与 `DIAG_*` 参数见[操作指南](usage.md#诊断与故障定位)。

确认所在机器可访问目录中的公开服务，并选择一个**新的、私有且父目录已存在的**证据目录。执行资产须由 root 所有且不可被 group/world 写入；安装器会设置这些权限，直接运行源码时也会核验摘要及文件权限。以下是显式启动流量的命令示例，本地开发验证没有执行它：

```bash
dvt measure --rate-cap 20 --family 4 --budget-mib 600 \
  --ledger /root/dvt-traffic/window.json --window-id path-check-01 \
  --output-dir /root/dvt-measure-01
```

命令先显示目录、额度、期限、速率和样本计划，再询问一次；非交互使用 `--yes` 表示接受该计划。默认最多尝试 4 个地址/公布端口组合、每档 3 次、每次 5 秒、流量调度期限 300 秒；最后的只读快照、账本结算和证据提交可能延长退出时间。目录公开服务会看到 VPS 的来源地址；报告中的网络地址只保存在本机，分享前需脱敏。

自有端点可加 `--host iperf.example.net --server-port 5201`。公共模式不允许任意覆盖端口；节点忙时只能在目录列出的端口和尝试上限内回退。IPv4 与 IPv6 分别绑定实际 IP/出口；ICMP 无响应仍允许有预算的协议尝试。不保证挑中物理最近或容量足够的节点。

默认阶梯为 cap 的 10%、25%、50%、75%、100%（向下取整，最小 1 Mbps，重复值合并），低速档在首尾各重复一组。协议预检固定为 1 Mbps，也计入预算。没有无限速基线、omit 预热或额外多流。

## 预算、失败与结果

预算按 application payload 记账，不包含 TCP/IP/链路、重传或服务商计费开销。每次 iperf3 启动前按 `rate × 125000 × (seconds + 10 + 8 + 5) + 1 MiB` 预留：覆盖 phase 超时余量、supervisor 等待与 TERM/KILL 清理窗口，并留有 pacing 余量。成功按 sender bytes 结算，失败保守扣除该次预留；因此剩余额度有时不足以启动下一档，即使该档正常完成的估算字节较少。不会扩大额度或自动新建窗口。

同一 ledger 的 `window-id` 和预算必须一致；保留旧窗口历史，不能删账或换 ID 绕过额度。账本读写失败时停止并保留未确认的 reservation，需依据证据核对；不能手工把未知消费改成 0。`Ctrl-C`/TERM 通过 runtime trap 回收本次 iperf3 进程组并尝试保守结算；SIGKILL/掉电可能留下占用，需检查原账本。共享超时回收已通过 Linux fixture；新测量链路的 SIGINT/SIGTERM 已在单台 Debian 13 的 loopback 真实 iperf3 上验证，公共路径中断及其他平台仍待验证。

完整采集不等于已识别拐点：

| 状态 | 含义 |
|---|---|
| `NO_RISE_IN_TESTED_RANGE` | 有效控制与完整阶梯中未确认重传上升；不证明无 policer 或最大容量 |
| `RETRANSMISSION_RISE_OBSERVED` | 在当前发送方式下观察到重复的重传上升区间；需路径/业务复核，不输出整形推荐 |
| `INSUFFICIENT_EVIDENCE` | 样本/控制缺失、预算/时间不足、负载不足、receiver 背离、资源压力或路径不同；不生成区间 |

筛选阈值是 `max(100, 5 × 首部控制中位重传/GiB)`，每档至少两次达到阈值才算重复上升；这是显式经验性筛选，不能换算为真实丢包率。sender 至少达到目标的 90%，不得超过 110%；receiver 至少为 sender 的 80%，还必须通过原有有效窗口与字节算术校验。CPU/softnet/qdisc 异常阻止生成区间。测试所得近端 RTT 不回填业务 BDP。

每次运行保存原始 iperf3 JSON、共享计数器/窗口摘要、路径、发现过程、每次预留与结算、计划和最终结果。`SHA256SUMS` 由 `COMPLETED` 绑定；异常保留 `INCOMPLETE`。预算/时间耗尽可以生成完整的“部分测量”报告；命令返回 0 表示证据报告完成，不表示网络健康或性能验收。

```bash
dvt report --input-dir /root/dvt-measure-01
```

离线 `report` 先核验摘要再显示结果；也可用 `python3 dvt-measure.py report --input-dir ...`。独立测量使用 `dvt.path-measurement/1`，不输入旧 `tools/calibrate_probe.py` 冒充 `VERIFIED` profile 证据。

完整仓库另提供[测量证据解释工具](measurement-explanation.md)，用于查看每个样本的绝对重传次数、字节量、单事件分辨率和候选限制：

```bash
python3 tools/explain_measurement.py --input-dir /root/dvt-measure-01
```

它先校验原报告，不改写原分类或证据；`--json` 可输出派生解释。[独立工具 0.1.0](releases/measurement-explanation-v0.1.0.md) 已提供完整源码包，未包含在主程序 `0.2.0-rc.1` bundle 中，也不会自动开展复验或设置限速；无需为使用该工具升级 VPS。

## 阶段边界

第一阶段固定 `d650709` 已有上述低流量运行证据。第二阶段新增独立的 [`htb-sweep`](temporary-htb.md)，会临时修改所选接口的 qdisc，其恢复验证与真实 VPS 授权单独记录；普通 `measure` 保持不写 qdisc。第三阶段 Ubuntu/ARM64/自适应持久配置的生命周期结果见[平台支持](platform-support.md)；诊断可运行本身不能替代 apply 的支持条件或生命周期证据。
