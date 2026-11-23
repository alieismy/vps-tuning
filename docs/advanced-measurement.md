# 高级测量与历史 HTB 研究入口

本页当前命令示例和预算、结算说明适用于 `v0.2.0-rc.5` 本地未发布候选中的 legacy `probe`/`benchmark`/TcpQuality 接口。历史 HTB 附录继续按其明确指定的旧版 bundle 执行，已发布 rc.1 的预算和默认限速行为见对应固定版本。本页不属于默认安装、迁移或日常验收步骤。无需自建对端的新版入口优先见 [自动测量](automatic-measurement.md)；通用临时整形见 [htb-sweep](temporary-htb.md)。

当前工具的 `./...` 示例从完整且已校验的同版本 bundle 根目录执行；历史 HTB 附录则使用它明确指定的旧版 bundle，不能在当前源码目录直接照抄历史相对路径。

## 选择入口

| 工具 | 对端与作用 | 主要范围 |
|---|---|---|
| `measure` | 公共自动选点或显式对端；不改 qdisc/sysctl | 按 Linux 能力运行，无需 apply；详见独立指南 |
| `probe` | 显式获授权对端；短样本且强制 iperf3 cap | legacy profile 路径，cap 100–1000 Mbps，不套用新版测量范围 |
| `benchmark` | 显式获授权对端；分方向结构化证据 | 研究使用；预算估算和实际限速需分别检查 |
| TcpQuality | 固定上游脚本/rootfs 与动态节点 | 有独立上传和临时防火墙影响，须满足下方前提 |
| 旧 `htb` | 显式对端、reference/sweep/A/B/A | 有受管版本和 Debian 13 / 200 Mbps 等窄范围；不是 `htb-sweep` |

主动流量必须符合事先批准的窗口预算。`probe` 仅在症状触发的有预算诊断中使用；benchmark、TcpQuality 和旧 HTB 研究还要求独立高额度测试机及明确机制问题。所有工具共享相应 ledger，不得删账或换窗口绕过额度。application payload 预算不包括协议、重传及服务商计费差异。

## 显式对端的 dvt probe

`dvt probe` 只用于真实业务症状触发后的有预算诊断，不是日常、升级或发布默认门禁。它要求显式提供你控制或明确获准使用的 iperf3 服务端；默认从 `VERIFIED` 管理状态读取 100–1000 Mbps 套餐端口上限，也可用 `--rate-cap` 明确指定。每个方向固定单流，并把该值通过 `iperf3 --bitrate` 实际应用到测试流量，而不只是写入估算。必须先用 `--plan-only` 查看包含硬超时和终止宽限的保守预留，再显式设置不超过已批准窗口的 `--budget-mib`；计划和工具预算均不含协议开销，也不能替代服务商面板的剩余额度检查：

```bash
dvt probe --host iperf.example.com --server-port 5201 --plan-only
```

确认 endpoint 授权和预算后，执行两个单向短样本。下例为 100 Mbps、每样本有效 5 秒、零预热，名义 payload 合计 125,000,000 字节。按每样本 20 秒硬超时、5 秒终止宽限和 1 MiB 发送余量，保守预留共 627,097,152 字节，低于本例的 600 MiB 窗口预算。

```bash
dvt probe \
  --host iperf.example.com \
  --server-port 5201 \
  --rate-cap 100 \
  --samples 2 \
  --seconds 5 \
  --omit 0 \
  --direction upload \
  --family 4 \
  --budget-mib 600 \
  --ledger /root/dvt-traffic/change-20260829.json \
  --window-id change-20260829 \
  --output-dir /root/dvt-probe-100m-a1 \
  --yes
```

每个样本继续复用 profile 已有的 JSON 窗口校验、精确 sender bytes、重传/GiB、主机 TCP 与 qdisc 增量、`INCOMPLETE → COMPLETED` 和 SHA-256 证据链；顶层结果只给出中位数和 `REVIEW_REQUIRED`/`REVIEW_BLOCKED`。它不探测或改写服务商套餐上限，不修改 sysctl/qdisc，不给出持久化 HTB 速率，也不经过 3X-UI、Xray、订阅客户端或 TUN 链路。公共测速站“可以连通”不等于已获长期或批量测试授权，授权与使用条款必须由执行者另行确认。

## 研究专用 benchmark

`benchmark` 不修改系统配置，但会产生高带宽 TCP 流量。运行前必须准备并获准使用 iperf3 服务端；脚本不安装软件包、不开放端口，也不选择公共服务器。

默认测试依次执行上传和下载。每个方向先预热 3 秒，该阶段不计入统计，再记录 10 秒有效窗口。自 rc.16 起，每个 iperf3 方向被放入独立进程组，默认硬超时为 `BENCHMARK_SECONDS + BENCHMARK_OMIT_SECONDS + 15` 秒；超时先发送 TERM，5 秒后仍未退出则发送 KILL。可用 `BENCHMARK_PHASE_TIMEOUT_SECONDS=1..300` 显式覆盖，但小于计划测量窗口会按预期使样本失败。设置 `BENCHMARK_OUTPUT_DIR` 后，脚本分别保存原始 iperf3 JSON、结构化摘要、TCP/softnet/CPU/接口增量、qdisc 前后统计和 `policy-routing.txt`，并生成运行元数据、总结果及核心证据 `SHA256SUMS`。证据目录必须是尚不存在的绝对路径；脚本以 `0700` 权限创建，并拒绝覆盖已有目录：

```bash
env BENCHMARK_HOST='iperf.example.com' \
  BENCHMARK_PORT=5201 \
  BENCHMARK_SECONDS=5 \
  BENCHMARK_OMIT_SECONDS=3 \
  BENCHMARK_PHASE_TIMEOUT_SECONDS=23 \
  BENCHMARK_PARALLEL=1 \
  BENCHMARK_IP_FAMILY=4 \
  BENCHMARK_DIRECTION=both \
  BENCHMARK_RATE_CAP_MBPS=50 \
  BENCHMARK_ENFORCE_RATE_CAP=1 \
  BENCHMARK_RUN_ID='case-1c1g-ipv4-a1' \
  BENCHMARK_OUTPUT_DIR='/root/dvt-benchmark-case-1c1g-ipv4-a1' \
  DVT_TRAFFIC_LEDGER='/root/dvt-traffic/change-20260829.json' \
  DVT_TRAFFIC_WINDOW_ID='change-20260829' \
  DVT_TRAFFIC_BUDGET_BYTES=629145600 \
  bash ./debian-vps-tuning.sh benchmark
```

`upload.summary.json` 和 `download.summary.json` 使用 schema 3。`measurement_window` 会核对 sender/receiver 的实际秒数、`bytes × 8 ÷ seconds` 与报告 bitrate 的一致性，以及 receiver bytes 不得在容差外超过 sender bytes。任一检查失败时，原始 JSON 和报告值仍保留，但摘要标记为 `INVALID_MEASUREMENT_WINDOW`；该样本不得用于吞吐或重传对比。benchmark 的 `PASS` 只表示采集和哈希链完整，不等于测量窗口可用于分析。

摘要中的 `sender.retransmits` 是对应方向的 iperf3 sender 统计，`host.tcp_delta` 是测试窗口内的整机全局计数，`qdisc_delta` 是本地 qdisc 统计。三者不可互换：背景连接会计入整机统计，本地 qdisc drop 也不等于远端路径丢包。

本次源码修订要求 benchmark 实际传入 iperf3 `--bitrate`。`BENCHMARK_RATE_CAP_MBPS` 显式值优先，缺省时读取合法管理状态中的 `network.port_speed_mbps`。多流时将总 cap 等分为每流 bps。`BENCHMARK_ENFORCE_RATE_CAP=0` 会在网络测试前被拒绝。已发布旧 bundle 仍保留其原行为，使用时需核对版本。

名义窗口估算为 `cap × 125000 × (seconds + omit) × 方向数`。实际保守预留为 `(cap × 125000 × (phase_timeout + 5) + parallel × 1048576) × 方向数` 字节，覆盖硬超时、TERM→KILL 宽限和每流发送余量。上例每方向硬超时 23 秒，双方向预留 352,097,152 字节，可在 600 MiB 空窗口内启动。probe 对每个样本使用相同公式，固定硬超时为有效窗口加预热加 15 秒。旧 HTB runner 从各阶段的 cap 计算同样的保守预留，可能高于历史计划文件所列的名义窗口值，并在会话元数据中记录实际预留。 该 runner 的软件 cap 与 HTB class rate 相同，软件节拍可能使 HTB overlimits 不足。分析器继续要求每个样本有正 overlimits 和足够的速率暴露，缺少这些证据时结果为 REVIEW_BLOCKED。若要改变 offered rate 以验证整形机制，需要另行确定实验输入和预算。

候选 runner 会从通过完整性与版本绑定核验的 benchmark 元数据提取实际记录的软件限速方法、范围和每流 bps，写入 stage-result 及完成后的 session-meta。未完成会话的已完成阶段仍可单独查看。软件节拍还可能影响突发、CPU 和重传，因此即使 overlimits 为正，也不能把这些样本与旧无软件节拍归档直接用于 HTB 因果比较。现有分析器继续读取旧归档；其输出不会完整展示新增限速记录，复审时须连同 stage-result/session-meta 核对。

软件节拍及这些余量用于限制负载和保守记账，无法保证物理网络字节绝对上界。预算不含协议、重传及服务商计费差异。直接 benchmark、probe、TcpQuality 和 HTB runner 共享相应 root-only ledger。零预热成功时提交可得的实际 sender bytes。非零预热的有效窗口统计不含预热，成功时按计划预留与已知有效字节两者的较大值保守结算。失败时同样保留已知有效字节下界。未能结算的 reservation 继续占用额度。TcpQuality 的手工计划金额无法证明动态上游负载的流量上界，需使用已独立批准的研究额度。

`sender.retransmits_per_gib` 按 iperf3 sender bytes 归一化。schema 3 分别保存 `qdisc_root_totals` 和 `qdisc_leaf_totals`；`qdisc_health` 对两层的 drop/requeue 独立判定，根与叶的 bytes 不相加。`mq` 拓扑的 `qdisc_active_totals` 仍使用叶子作为流量汇总，普通根 qdisc 和 HTB 使用 root；HTB root `overlimits` 是整形暴露证据，FQ 叶子 drop/requeue 不会再被 root 零值掩盖。缺少预期 HTB→FQ 叶子时摘要生成失败。这些指标只适合比较服务端、方向、时段和参数一致的重复测试，不能单独用于性能排名。

创建持久化目录后，脚本先写入 `INCOMPLETE`。上传/下载摘要、策略路由证据、核心证据清单、`benchmark-result.json` 和 `COMPLETED` 全部提交成功后，才删除该标记。`policy-routing.txt` 总是保存 IPv4/IPv6 rules；只有检测到自定义 rule 时才展开对应地址族的 `route show table all`。这只是只读诊断，不能证明项目支持复杂策略路由 apply。`SHA256SUMS` 覆盖原始测试数据、计数器、策略路由、元数据和分方向摘要；为避免循环依赖，不覆盖 `benchmark-result.json`、`COMPLETED` 和 `INCOMPLETE`。`benchmark-result.json` 保存核心清单哈希，`COMPLETED` 绑定核心清单与最终结果哈希。

判定一组持久化证据有效，必须同时满足以下条件：

1. 命令退出码为 0；
2. 结果状态为 `PASS`；
3. 存在 `COMPLETED`；
4. 不存在 `INCOMPLETE`；
5. 两条哈希链均可重新计算并匹配。

以上条件只证明证据完整。若要把某一方向纳入性能比较，还必须满足对应摘要
`.measurement_window.valid == true`；否则保留现场并重测，不得从 `PASS` 推导吞吐或重传结论。

`BENCHMARK_IP_FAMILY=4` 或 `6` 用于固定地址族；`auto` 由系统解析和连接过程选择。比较 IPv4 与 IPv6 时，应分别运行并保存各自的默认路由。`BENCHMARK_OMIT_SECONDS=0` 用于观察包含 slow start 的短连接；非零值用于比较稳态吞吐，两类结果不能混入同一序列。

该测试只测量 VPS 与 iperf3 服务端之间的直连 TCP，不经过 VLESS + REALITY + TCP 客户端链路。公共测试点的单次结果不能直接代表代理体验。`BENCHMARK_PARALLEL` 范围为 1–4；1C1G 和 1C2G 基线应先使用 1。iperf3 参数语义见 [ESnet 官方文档](https://software.es.net/iperf/invoking.html)。

## 固定 TcpQuality 证据采集

`tcpquality-evidence.sh` 独立于系统调优生命周期，不自动下载“最新”脚本或 rootfs，也不执行 `apply`。当前资产沿用 rc.13 固定的 TcpQuality release `v1.00013`、commit `73606e2460bde21bb2e253842971f8ca8c9eb51c`、三个脚本、`rootfs-manifest.json` 和 amd64 rootfs。固定目录还必须包含记录 rootfs 内 TCP_INFO helper 与两份 eBPF 脚本审计值的 `PINNED-METADATA.txt`，以及覆盖五个下载资产的 `SHA256SUMS`。

`PINNED-METADATA.txt` 的字段和值必须精确如下；这些值记录的是已检查的上游 release 资产，不代表目标 VPS 内核一定允许 eBPF/BTF：

```text
tcpquality_release_tag=v1.00013
tcpquality_commit=73606e2460bde21bb2e253842971f8ca8c9eb51c
rootfs_manifest_file=rootfs-manifest.json
rootfs_manifest_sha256=555a53df40cbdd2778771c089d1bc2c2e1c0a52b5565ad15d2e01d52b90dd0f6
rootfs_file=tcpquality-rootfs-amd64.tar.gz
rootfs_size=140748758
rootfs_sha256=c624b5cc611b7177c42608110024764e59dfd0a88150257137ae4e6d7f9f9d18
tcp_info_helper_path=usr/local/lib/libtcpquality-tcpinfo.so
tcp_info_helper_size=14152
tcp_info_helper_sha256=159d31efc9dbfda7b5f552455d160ebde295c937dcc3f8b24d21fb5934cd8253
retrans_seq_path=usr/local/libexec/tcpquality-retrans-seq.bt
retrans_seq_size=1865
retrans_seq_sha256=4ab10e0993becb37c5bff64e1f0ae4860959ff2ad16b372578701ffcf5c36aab
retrans_skb_path=usr/local/libexec/tcpquality-retrans-skb.bt
retrans_skb_size=819
retrans_skb_sha256=b84d979a000b86515c3eb8b776d3e2b276031e418a659aa828eb7afbdab4bd89
```

`TCPQUALITY_MODE` 必须显式选择。推荐 `local-evidence`：上游参数固定增加 `--debug --no-rank-upload`，保留本地 debug archive，但不上传公开报告或 debug bundle。`public-report` 会使用 `--debug`，上传公开报告；报告成功后还可能上传线路、speedtest 和 probe debug bundle，其中可能包含公网地址、节点地址、路由和响应细节。上游 TOS 测速还会临时创建并删除 `iptables`/`ip6tables` 计数链；chroot 不隔离网络命名空间，所以必须在维护边界可接受且确认当前防火墙可恢复后显式设置 `TCPQUALITY_ACK_TRANSIENT_FIREWALL=1`。证据目录必须尚不存在：

```bash
env \
  TCPQUALITY_PIN_DIR='/root/tcpquality-pinned-73606e2460bde21bb2e253842971f8ca8c9eb51c' \
  TCPQUALITY_EVIDENCE_DIR='/root/rc13-evidence/tcpquality-s2' \
  TCPQUALITY_COMMIT='73606e2460bde21bb2e253842971f8ca8c9eb51c' \
  TCPQUALITY_ROOTFS_SHA256='c624b5cc611b7177c42608110024764e59dfd0a88150257137ae4e6d7f9f9d18' \
  TCPQUALITY_MODE='local-evidence' \
  TCPQUALITY_ACK_TRANSIENT_FIREWALL=1 \
  TCPQUALITY_RUNS=3 \
  TCPQUALITY_DELAY_SECONDS=60 \
  TCPQUALITY_COUNT=30 \
  TCPQUALITY_PACKET_SIZE=0 \
  TCPQUALITY_PARALLEL=16 \
  TCPQUALITY_PLANNED_PAYLOAD_BYTES=629145600 \
  DVT_TRAFFIC_BUDGET_TOOL='/usr/local/lib/debian-vps-tuning/current/dvt-traffic-budget.sh' \
  DVT_TRAFFIC_LEDGER='/root/dvt-traffic/research-20260829.json' \
  DVT_TRAFFIC_WINDOW_ID='research-20260829' \
  DVT_TRAFFIC_BUDGET_BYTES=2147483648 \
  bash ./tcpquality-evidence.sh
```

每轮测试保存原始日志、唯一 CSV 和唯一 debug archive，并在测试前后分别采集 `all`/`tos` 节点表。`debug-inventory.tsv` 固定 archive 哈希；`retransmission-evidence.tsv` 从 archive 中提取每个 TOS 方向的 `metric_source`、TCP_INFO、eBPF 去重值、分母、比例、回退原因和测量状态。只有 `ebpf_seq`、`ebpf_skb`、`tcp_info_getsockopt` 或 `tcp_info_ss` 可作为流级重传证据；`nstat` 必须标记为 `MEASUREMENT_DEGRADED`，不得解释成该测速连接的重传率。节点响应通过固定 12 列 TSV 结构校验后才原子写入。`node-inventory.tsv` 记录各快照哈希；`node-drift.tsv` 区分逻辑节点增删、同一逻辑节点的 IP 变化，以及完整快照是否一致。`summary.txt` 记录实际节点 URL、模式和上传边界。

固定 commit、脚本和 rootfs 只能固定本地执行资产；远端节点、测速端点、运营商路径和测试时段仍是动态实验输入。最终 `SHA256SUMS` 覆盖 summary、文本、TSV、CSV 和日志，但不覆盖终态标记。`COMPLETED` 绑定清单哈希，`INCOMPLETE` 与 `COMPLETED` 不得同时存在。任何关键采集或校验失败都会终止后续轮次并保留失败现场。

节点变化不会自动使整组测试失效，但比较时必须剔除或单独标注不一致节点。旧 commit 的整机 `TcpRetransSegs` 增量与 v1.00013 的流级百分比属于不同测量基线，不能串接为同一时间序列。包装层自身不写 sysctl/qdisc/systemd/swap，也不调用主机包管理器；固定上游的 `--all` 会访问节点和测速端点、加载临时 eBPF 探针并创建/删除目标计数链，因此不是零内核交互的纯只读操作。

## 参数参考

| 变量 | 默认值 | 范围/说明 |
|---|---:|---|
| `BENCHMARK_HOST` | 无 | benchmark 必填，用户授权的 iperf3 服务端 |
| `BENCHMARK_PORT` | `5201` | `1–65535` |
| `BENCHMARK_SECONDS` | `10` | `5–120`，每个方向 |
| `BENCHMARK_OMIT_SECONDS` | `3` | `0–10`，每个方向的预热时间，不计入 iperf3 统计 |
| `BENCHMARK_PARALLEL` | `1` | `1–4` |
| `BENCHMARK_IP_FAMILY` | `auto` | `auto`、`4` 或 `6` |
| `BENCHMARK_DIRECTION` | `both` | `upload`、`download` 或 `both` |
| `BENCHMARK_RATE_CAP_MBPS` | 合法管理状态的端口带宽，否则拒绝执行 | 可选 `1–100000`；总 cap 等分后传给各 iperf3 流的 `--bitrate` |
| `BENCHMARK_RUN_ID` | 自动生成 | 可选的 1–96 字符运行标签；仅限字母、数字、点、下划线、冒号和连字符 |
| `BENCHMARK_OUTPUT_DIR` | 临时目录 | 可选的持久化证据目录；必须是父目录已存在、目标尚不存在的绝对路径 |
| `TCPQUALITY_MODE` | 无 | 证据工具必填；`local-evidence` 禁止报告/debug 上传，`public-report` 明确允许报告及附属 debug bundle 上传 |
| `TCPQUALITY_ACK_TRANSIENT_FIREWALL` | `0` | 必须显式为 `1`；确认固定上游会临时创建/删除目标流量计数链，且维护窗口与恢复边界可接受 |
| `BENCHMARK_ENFORCE_RATE_CAP` | `1` | 必须为 `1`；probe 和旧 HTB runner 显式启用 |
| `BENCHMARK_PHASE_TIMEOUT_SECONDS` | 有效秒数 + omit + 15 | `1–300`；小于测量窗口会使样本失败 |

## 历史 HTB reference 与 A/B/A

以下资料保留原 rc.17/rc.18 版本边界与观察结果。不能按当前 `dvt` 或 `current` 符号链接执行旧例子，不能用新版本状态替代旧版 `VERIFIED` 条件。新通用实验使用 [htb-sweep](temporary-htb.md)；旧研究的完整协议见 [HTB SOP](experiments/htb-candidate-rate-sweep.md)。本文不给历史实验重新授权。

截至 2026-09-11，VMISS Basic 已完成三次有效的 HTB200 reference：吞吐约
187–190 Mbit/s，sender 与主机级重传增量均为 0，HTB root/FQ leaf drop/requeue 均为 0，
endpoint closeout 也已完成并清理临时 listener、进程、unit 和 UFW 规则。该结果只闭合了
本次固定 HTB200 reference 的运行与证据链；不构成 default `fq` 对照、HTB 因果收益或真实
VLESS + REALITY + TCP 业务改善证据。Basic 的 180/190/195 candidate sweep 已停止，Core
和 A/B/A 不因该 reference 自动启动；默认配置仍为 BBR + 根 `fq`，不启用持久 HTB。endpoint
closeout 与 observer 原目录属于受控私有证据，不应直接作为公开 Release、issue 附件或仓库文件。

> 默认不得在有月流量配额的业务 VPS 上执行本节。只有明确要验证聚合出口整形机制、使用
> 独立高额度测试机、已经批准完整窗口的流量预算和停止条件时，才可进入下列研究流程。

下面的可执行示例属于已经发布的 rc.17 非持久 HTB 工作流，只接受 Debian 13 rc.17 schema 4、
`VERIFIED`、200 Mbps 的 `debian13-1c1g` 或 `debian13-1c2g` 基线。安装后的短命令把原有工具链
包装为带阶段门禁的入口。HTB watchdog 要求执行器从稳定路径运行；`dvt htb preflight` 不会
隐式写入该路径。确认没有活动 HTB 后，先从同一固定 rc.17 Release 显式安装并按 manifest 校验：

```bash
DVT_ROOT='/usr/local/lib/debian-vps-tuning/0.1.0-rc.17'
test -d "$DVT_ROOT"
HTB_TOOL='/usr/local/sbin/htb-aggregate-experiment'
test ! -e /run/htb-aggregate-experiment/active.json
install -o root -g root -m 0755 \
  "$DVT_ROOT/experiments/htb-aggregate/htb-aggregate-experiment.sh" \
  "$HTB_TOOL"
EXPECTED_HTB_SHA256="$(awk \
  '$2 == "experiments/htb-aggregate/htb-aggregate-experiment.sh" {print $1}' \
  "$DVT_ROOT/SHA256SUMS")"
printf '%s  %s\n' "$EXPECTED_HTB_SHA256" "$HTB_TOOL" | sha256sum -c -

bash "$DVT_ROOT/debian-vps-tuning.sh" htb preflight
bash "$DVT_ROOT/debian-vps-tuning.sh" htb smoke --rate 190 --hold-seconds 10

bash "$DVT_ROOT/debian-vps-tuning.sh" htb reference \
  --host iperf.example.com --server-port 5201 \
  --ledger /root/dvt-traffic/htb-research-20260829.json \
  --window-id htb-research-20260829 --budget-mib 8192 \
  --output-dir /root/htb200-reference-a1

# 只有 reference 的 COMPLETED、SHA256SUMS、三类 gate 和人工复核均通过后：
bash "$DVT_ROOT/debian-vps-tuning.sh" htb sweep \
  --host iperf.example.com --server-port 5201 \
  --reference-evidence /root/htb200-reference-a1 \
  --ack-reference-reviewed \
  --rates 180,190,195 \
  --ledger /root/dvt-traffic/htb-research-20260829.json \
  --window-id htb-research-20260829 --budget-mib 8192 \
  --output-dir /root/htb-candidate-sweep-a1
```

上述命令只指向已按固定 rc.17 安装器校验安装的版本目录；缺少目录时先停止，不改用 `current`。rc.18 对照材料属于当时完整同版本本地 bundle 的记录；其中 wrapper、执行器、伴随脚本、profile 和 `SHA256SUMS` 必须来自同一版本，不与 rc.17 或当前发布线混用。

`--ack-reference-reviewed` 只是证明操作者已检查 reference 证据，不授权永久整形。wrapper
还会把该 reference 的 `SHA256SUMS`、`sweep-analysis.json` 和 `COMPLETED` 摘要写入 candidate
plan；因此完成的扫描可以追溯到唯一已复核 reference，而不记录目标机绝对路径。wrapper
要求 `/usr/local/sbin/htb-aggregate-experiment` 为 root 所有、非符号链接、不可被 group/world
写入，且 SHA-256 与当前 Release 资产一致；`status/stop` 在事故恢复时仍优先使用已安装的稳定
执行器。wrapper 不暴露“安装永久 HTB”的路径；异常时仍由 watchdog/EXIT 恢复逻辑处理，并
保留 `dvt htb status` 与 `dvt htb stop`。

`experiments/htb-aggregate/rate-sweep-plan.sh`、`rate-sweep-run.sh` 和
`rate-sweep-analyze.sh` 把候选发现分成 schema 3 只读计划、显式流量/临时 qdisc 执行和只读
分析三层。已发布 rc.17 路径只接受 rc.17 schema 4 的对应基线；历史 rc.18 runner 只有从
完整同版本 rc.18 bundle 和状态调用时才应用 rc.18 边界。两条路径都要求 `VERIFIED`、200 Mbps 的
Debian 13 1C1G/1C2G 基线；runner 在流量前执行真实 profile 的只读 `verify`，冻结 managed
profile/version/state/port/state SHA-256，并要求每个 `benchmark-meta.json` 再次匹配。只测
上传，因为本地 egress HTB 不能用于归因下载方向的远端 sender 重传。通用默认
`reference-screen` 为 3 次 HTB200；VMISS Basic 的本轮 reference 已按三次有效样本完成并
人工关闭。只有在新的独立授权、预算和停止条件下仍有明确机制问题时，才可重新生成独立
`candidate-sweep`，以相同 HTB+fq 拓扑在首尾重复 HTB200
reference，并以正序/反序轮次扫描 180/190/195 Mbit/s；每阶段至少冷却 300 秒。直接调用
plan 生成器也必须显式 ack 并提供三项 reference 摘要，不能省略阶段授权字段；plan 生成器
本身不读取主机，摘要真实性仍须由 `dvt htb` wrapper 或执行 SOP 校验。

分析以通过窗口校验的 iperf3 sender Mbit/s 作为主吞吐指标，并使用精确 sender bytes 归一化
的 `retransmits_per_gib`；receiver goodput 只作交叉核对。任一样本使用旧 summary schema、
缺少完整 HTB→FQ root/leaf 证据、测量窗口无效、HTB root `overlimits` 不为正、任一
root/leaf qdisc drop/requeue 增长、sender 未达到计划速率的 90%、CPU idle/steal 不合格，或 softnet/
接口异常计数增长时，输出 `REVIEW_BLOCKED` 且 shortlist 为空。阈值作为 plan controls 冻结，
不是分析器隐藏常量。分析不假设固定 MSS、不推算 packet loss percentage、不使用固定全局
重传阈值。runner 的脱敏 `socket-metrics.txt` 除原有 RTT、cwnd 和重传字段外，还保留
`pacing_rate`、`delivery_rate`、`minrtt`、`dsack_dups`、`rcv_ooopack`、`snd_wnd` 和
`rcv_wnd`；它不保留 endpoint/process 信息，只作辅助归因，不能替代流级指标。扫描完成、
shortlist 非空和 HTB `overlimits` 都不授权持久化。通用命令见
[HTB200 参考筛查与候选聚合速率发现 SOP](experiments/htb-candidate-rate-sweep.md)；VMISS
Basic 1C1G 使用更完整的
[HTB campaign SOP](experiments/vmiss-basic-1c1g-200mbps-htb-campaign.md)。

候选经人工复核后，`experiment-plan.sh` 才用于生成机器可读计划。一个调用只允许一个三阶段
窗口；首窗和反向窗必须使用不同 window ID、新证据目录和独立 operator invocation：

```bash
bash ./experiments/htb-aggregate/experiment-plan.sh \
  --window-id basic-window-1 \
  --window-order aba \
  --candidate-rate 190 \
  --cooldown-seconds 300 \
  --control-rate none >./basic-window-1-plan.json

# 只有首窗结果关闭后，另一个可比窗口再单独生成：
bash ./experiments/htb-aggregate/experiment-plan.sh \
  --window-id basic-window-2 \
  --window-order bab \
  --candidate-rate 190 \
  --cooldown-seconds 300 \
  --control-rate none >./basic-window-2-plan.json
```

较低速率控制必须等候选结果分析关闭后另建窗口，例如 `--control-rate 180` 会附加独立的 `A-control-before → C1 → A-control-after`，不会自动执行或授权 180 Mbit/s。候选扫描不能替代该 A/B/A 和反序复验。

该历史 rc.18 开发候选中的执行器 v0.4.0 只接受 rc.18 schema 4、`VERIFIED`、200 Mbps 的
`debian13-1c1g` 或 `debian13-1c2g` 基线；200 仅用于同拓扑 reference，不授权超过端口
上限。正式 B stage 必须使用 `TCPQUALITY_RUNS=1`，避免三轮 TcpQuality 超过 40 分钟
watchdog。1C2G 见独立 [A/B/A SOP](experiments/vmiss-1c2g-200mbps-htb-aba.md)。原
[VMISS Basic HTB A/B/A 文档](experiments/vmiss-basic-200mbps-htb-aba.md)只保留
1C1G/v0.2.1 历史证据，不得作为当前入口。
