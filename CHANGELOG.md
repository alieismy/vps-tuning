# Changelog

## [0.2.0-rc.4] - 2026-10-13

- 修正入口与受管状态版本不一致时的菜单引导：默认本地能力诊断，标明不可用的受管操作，保留显式选择的只读联网升级检查；不会因直接回车自动联网、迁移或写入配置。
- 增加真实 Linux PTY（伪终端）回归，验证输入、确认和分派；系统执行使用测试替身，不代表跨终端视觉或真实 VPS 验收。
- 只读 update-preflight 和迁移器接受 `0.2.0-rc.3` 来源，保留 rc.2 与既有 0.1.0-rc.1–rc.19 来源；目标为 rc.4，所有迁移门禁及平台/端口限制不变。同步版本、生成 profile 和摘要链。
- 调优内容不变，不建议已正常运行的 rc.2/rc.3 主机仅为菜单升级。发布状态及验证边界见 [rc.4 说明](docs/releases/v0.2.0-rc.4.md)。

## [0.2.0-rc.3] - 2026-10-13

- 重做无 action 时的 `dvt` 交互菜单：单屏框式主页、分组双语菜单和副作用标签，框外显示主机、档位、受管记录和运行值。默认项按受管记录选择首个只读动作；非 root 或平台不支持时只开放能力诊断。设计见 `docs/interactive-cli-design.md`。
- 菜单无效输入重新提示，第 3 次仍无效时以退出码 2 结束；读到 EOF 时不执行任何操作。菜单路径的 `rollback` 新增确认，确认默认 N，EOF 视为否；菜单动作结束后显示结果页，退出码不变。`probe`、`benchmark` 改列为命令参考，不再从主菜单分派。
- 无终端且未指定 action 时补充 `ssh -t` 和自动化示例；支持 `NO_COLOR`、`DVT_ASCII=1` 和窄终端开放布局。CLI 语法、action、退出码定义以及非终端下的检测结果与执行计划文本不变；交互提问处读到 EOF 现在退出 0（旧版菜单路径为 1），端口带宽无效输入改为重新提示。
- 只读 update-preflight 和迁移器增加 `0.2.0-rc.2` 来源，保留 `0.1.0-rc.1`–`rc.19`，目标为 `0.2.0-rc.3`。迁移器仍限 Debian profile 和 100–1000 Mbps 端口；TCP 基线恢复工具随版本更新，只接受同版本归档。
- 同步九份生成 profile、版本入口和摘要链。以 Pre-release 发布；提交、CI 与公开资产回验见[验证说明](docs/validation.md#rc3-release-validation)。`0.2.0-rc.2 → 0.2.0-rc.3` 尚无真实主机迁移证据。

## [0.2.0-rc.2] - 2026-10-11

- 修复 `UPDATE_PREFLIGHT=1` 时旧 schema 4 因版本不一致被目标 profile 拒绝的问题；限定已有 `0.1.0-rc.1` 至 `rc.19` 来源，保留 profile、provider、所有权和状态阶段校验。
- 限定 `UPDATE_PREFLIGHT` 只能用于 profile 的 `preflight` 动作，阻止借兼容模式进入写操作；普通模式报告来源与当前版本，保持版本边界。
- `update` 成功提示先通过 `migrate prepare` 的 `PREPARED` 门禁；缺失 TCP 原始三元组仍拒绝迁移，不猜值、不改写旧状态。
- 同步九份生成 profile、版本入口和摘要链，增加真实预检入口与控制器调用回归。验证范围见 `docs/releases/v0.2.0-rc.2.md`；公开 rc.1 资产保持不变。

- 增加完整源码中的 TCP 基线恢复工具，区分同部署历史原值和明确接受的替代基线；迁移器保存来源归档并核对第一次重启后的实际 TCP 基线。工具不由安装器部署，也不扩大迁移来源。
- 运行验收补记（2026-10-11）：VPS-01 至 VPS-05 均已完成旧版至 rc.2 的迁移、入口安装、严格代理服务验证及用户确认的面板、真实代理和重连基本业务验收；恢复来源和证据边界见[五台验收记录](docs/validation.md#rc2-fleet-acceptance)。该补记不改变已发布制品，也不证明量化性能收益或长期稳定性。

## [measurement-explanation-v0.1.0] - 2026-09-30

- 独立发布离线测量解释工具 `0.1.0`：校验既有报告后显示绝对重传次数、字节暴露量、原阈值所需整数次数和候选限制，保留原分类与原始证据。
- 缺少或遗漏较高 sweep 档汇总时输出 `INCOMPLETE`；中文逐样本缺失值显示“不可评估”，JSON 保留 `null`。
- 提供完整源码 ZIP、中文说明和摘要清单，固定提交 `1c5e922`；属于独立 Pre-release，不设为 Latest、不进入 `dvt update` 主程序升级通道，也不替代 `v0.2.0-rc.1` 安装资产。验证与下载见[工具发布说明](docs/releases/measurement-explanation-v0.1.0.md)。

## [0.2.0-rc.1] - 2026-09-29

- 新增第三阶段 Debian 12/13、Ubuntu 24.04 LTS 的 x86_64/ARM64 持久配置与自适应资源 profile；受管带宽接受 1–10000 Mbps，按内存封顶 socket buffer，新 profile 默认不创建 swap。七组独立 VM 生命周期全部通过并复核归档，见 `docs/platform-support.md`。
- 修复原始 `tcp_rmem/tcp_wmem` 快照截断制表符三元组的问题；回滚前拒绝不完整原值，恢复后读回核对，迁移准备不接受缺失原值的来源状态。历史丢失字段不自动重建。

- 修复真实单机验收发现的 iproute2 6.15 fq weights 恢复解析问题：整形前验证完整恢复语法，按实际解析能力选择限定兼容参数，冻结并校验恢复参数。首轮失败后已恢复原 fq；后续正常事务与公共路径 SIGINT/SIGTERM 复验通过，完整扫描与性能效果未验收，详见 `docs/temporary-htb-retest-2026-09-28.md`。

- 新增按实际 Linux 能力运行的 `diagnose` 和独立 `measure`，无需先 apply 或匹配 Debian/CPU/RAM/架构档位；`diagnose --managed` 保留原 profile 诊断。
- 加入带官方出处的 Leaseweb/Clouvider 固定公共目录、有限 RTT 排序和有预算协议尝试、自有端点入口及 1–10000 Mbps 显式测试 cap。
- 新测量在同一 IP/端口/出口上执行单流 application pacing、重复速率阶梯及首尾低速控制；记录有效窗口、receiver goodput、sender 重传/GiB、RTT 和资源状态。报告仅给路径观察，不识别服务商 policer、不自动整形。
- 共享采集与解析从 profile 模板提取，提取阶段保留旧 profile 采集语义；本候选后续另增加跨架构支持与上述恢复修复。新证据使用独立 schema；离线校准器 0.1.2 另行接受同格式的 0.2.0-rc.1 受管 probe。
- 新版账本继续读取 schema 1 的 rc.19 窗口，不重置额度；迁移器接受 rc.1–rc.19 来源至新候选。测量本身不需要迁移受管状态。
- 新增第二阶段 `htb-sweep`：复用自动选点和预算，显式接口/整形上下界/application cap，首尾低档与上界 reference、粗扫及最多三档精扫。仅允许可完整恢复的单根 fq，使用冻结 checkpoint、独立恢复看护和所有权门禁；恢复失败不生成完成报告。
- 新增离线 HTB 回归和两个隔离网络命名空间内的真实 tc/iperf3 CI，验证定制 fq 恢复、部分失败、外部漂移、看护及信号；验证结果见 `docs/validation.md`。第一阶段固定提交的真实低流量证据不代表第二阶段已在 VPS 验收；跨平台持久配置的实现与运行证据另见平台支持矩阵。

## [0.1.0-rc.19] - 2026-09-27

### Added

- 增加仓库内离线工具 `tools/calibrate_probe.py`，验证现有 probe 的双层摘要与完成标记，按路径/方向生成负载 RTT 画像和受资源约束的 buffer 实验候选；不增加主动流量，不自动应用或推断服务商限速器。
- HTB 分析器增加 sender 改善而 receiver 退化的 median/MAD 描述性复核提示，不改变原有 shortlist、暴露和恢复门禁。
- profile 锁冲突显示经进程身份核对的 PID 与持锁秒数；信息不完整时保留通用冲突提示，不接管或终止其他进程。

### Fixed

- 离线校准器 0.1.1 接受与 rc.18 采集契约一致的 rc.17 证据，避免仅为离线分析要求升级 VPS；仍拒绝未支持版本、混合版本和跨脚本/启动周期的样本。
- 定向修复四处 swap 列表的提前退出管道，避免合法长路径列表在 `pipefail` 下出现 SIGPIPE 假阴性；保留生产者失败状态。

### Boundaries

- 本轮只实现实测校准第一阶段；默认 BBR + fq、17 项 sysctl、BDP 档位、非持久 HTB 和 schema 边界不变。
- rc.18 已于 2026-09-15 发布且保持不可变；rc.19 作为独立 Pre-release 发布。迁移器允许 rc.1–rc.18 来源进入 rc.19，既有 checkpoint/重启门禁不变。

## [0.1.0-rc.18] - 2026-09-15

### Fixed

- 修复 Linux 内核自动创建的 `mq 0:` 根 qdisc 无法通过显示出来的 `parent :N`/`0:N` 直接替换叶 qdisc 的问题：对全 `fq_codel` 拓扑选择无冲突的非零根 handle，重建后重新读取队列，再逐叶切换为 `fq`。
- 回滚按当前可寻址 `mq` 根 handle 与保存的队列 minor 重建 parent，并在语义比较中仅规范化同一 `mq` 下的 parent 表示，避免把 ingress/clsact 或其他 qdisc 误判为等价。
- `mq 0:` 混合自定义 `fq`/`fq_codel` 拓扑在任何写入前拒绝处理，防止根 qdisc 重建静默丢失现有 `fq` 参数。

### Added

- 增加 OCI 类 `mq 0:` 的状态化 fixture，覆盖全 `fq_codel` 转换、全 `fq` 无操作、混合拓扑拒绝、显式非零 `mq`、根重建失败、队列 minor 漂移和卸载恢复。

### Unchanged

- 保持 rc.17 的 17 项受管 sysctl、资源感知 BDP 缓冲、默认 `BBR + fq`、schema 4 managed state、schema 3 benchmark 摘要、共享预算 ledger、非持久 HTB 与生产授权边界。

## [0.1.0-rc.17] - 2026-09-10

### Fixed

- 识别 HTB `parent MAJOR:MINOR` 下的 FQ 叶 qdisc，并在缺少预期叶子计数时拒绝生成可用摘要。
- benchmark phase summary 升级为 schema 3，分别记录 root/leaf drop、requeue 与 HTB root `overlimits`，避免叶子异常被 root 零值掩盖。
- HTB 候选分析器对旧摘要、缺失字段以及任一受管 root/leaf drop 或 requeue 输出 `REVIEW_BLOCKED`，不再生成 shortlist。

### Added

- 脱敏 `ss -tin` 辅助采样新增 `pacing_rate`、`delivery_rate`、`minrtt`、`dsack_dups`、`rcv_ooopack`、`snd_wnd` 和 `rcv_wnd` 白名单字段。

### Unchanged

- 默认 profile 仍为 17 项受管 sysctl、资源感知 BDP 缓冲和 `BBR + fq`；HTB 仍为非持久研究入口，rate、burst/cburst 和生产授权边界不变。

## [0.1.0-rc.16] - 2026-08-31

### Added

- benchmark 每个方向在独立进程组内执行，增加默认有界硬超时、TERM→KILL 升级和 `INT`/`TERM`/失败路径子进程回收；超时仍保留 `INCOMPLETE` 并按计划 payload 保守结算预算。
- `diagnose` 和 benchmark 增加 IPv4/IPv6 policy rules；检测到自定义规则时保存对应地址族的全部路由表并警告常规默认路由网卡发现不覆盖该拓扑。
- 新增 rc.16 timeout/process-group、策略路由分类和 rc.15→rc.16 checkpoint migration fixture。

### Unchanged

- 17 个受管 sysctl、BBR + 根 `fq`、资源感知 BDP 缓冲、swap、journald、NOFILE、schema 4 和非持久 HTB 边界不变。
- 未引入外部调优材料中的扩张 sysctl、`initcwnd/initrwnd`、固定 MTU、RPS/RFS、UDP、MSS Clamp、CAKE 或永久 HTB。

## [0.1.0-rc.15] - 2026-08-30

### Added

- 新增 root-only、原子更新且 fail-closed 的共享流量预算 ledger；benchmark、probe、TcpQuality 与 HTB runner 共用窗口额度，失败按计划上界保守核算。
- 新增持久化 `migrate` checkpoint/resume，固定旧版/目标版 profile 并强制两次 boot-ID 重启门禁。
- 新增 Linux root fixture，覆盖超预算拒绝、实际字节提交、失败保守结算、迁移中断续接和两次重启门禁。

### Changed

- 总控、六份生成 profile、installer、TcpQuality 工具和 HTB managed-state 绑定统一升级为 `0.1.0-rc.15`。
- 无法量化计划 payload 的 benchmark 不再执行；TcpQuality 必须由操作者显式声明计划 payload 上界。
- P0 低流量验收策略进入实现态；HTB 与多轮 TcpQuality 继续保持研究专用，不属于逐机升级门禁。

### Compatibility and evidence boundary

- 17 个受管 sysctl、BBR + fq、buffer、swap、journald、NOFILE 与 schema 4 未改变；跨版本仍由旧版固定资产清理，不允许 rc.15 覆盖旧状态。
- 本地和 CI fixture 不等于目标 VPS、重启持久性、控制台恢复、严格代理或真实业务验收；本候选发布不产生公网测速流量。

本项目采用 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

## [0.1.0-rc.14] - 2026-08-28

### Added

- 新增显式 `dvt reconfigure --port <MBPS>`。它只接受同版本、同 profile、完整验证通过的 `VERIFIED` 状态，保留 RTT 和显式 buffer，只在自动模式下按新端口重新推导 buffer。
- 新增 `RECONFIGURING` 事务状态、root-only state/sysctl 备份、候选完整验证、失败证据及 `dvt recover` 恢复路径；中断、sysctl 应用失败或候选验证失败时优先恢复旧配置，恢复失败保留 `DEGRADED` 和备份。

### Changed

- 100→200 Mbps 等有效 sysctl 值不变的带宽变化只更新受管 sysctl 注释、哈希和状态；2 GiB 档 200→500 Mbps 等实质变化只通过本项目 sysctl 文件更新相关 buffer，不重建 qdisc。
- 总控、六份 profile、installer、TcpQuality 工具版本和 HTB managed-state 绑定同步为 `0.1.0-rc.14`；状态 schema 仍为 4。

### Safety

- 普通 `apply` 的参数不一致门禁保持不变；`verify`、`rollback`、`preflight` 和 `apply` 不会越过未完成的重配置事务。重配置不修改 qdisc、swap、journald、NOFILE、路由、防火墙、DNS、MTU、代理服务或持久 HTB。
- rc.14 不直接接管 rc.13 状态；跨版本仍使用固定 Release 的只读 `update` 和人工 rollback/reapply 流程。已发布 rc.13 的 tag、Release、资产和发布说明保持不变。

### Validation

- 新增缺失 `--port`、无状态、非 `VERIFIED`、跨版本/profile、同值幂等、等价值升级、实质升降级、显式 buffer 保留、外部修改、备份哈希异常、sysctl/候选失败、自动恢复和恢复失败门禁 fixture。
- 本地候选不等于目标 VPS 验收；真实 rc.14 安装、迁移、重配置、故障恢复、重启持久性、代理链路与性能仍需独立验证。

## [0.1.0-rc.13] - 2026-08-24

### Changed

- TcpQuality 固定基线升级到 release `v1.00013`、commit `73606e2460bde21bb2e253842971f8ca8c9eb51c`；同时固定三个脚本、`rootfs-manifest.json`、amd64 rootfs 大小/哈希，以及 rootfs 内 TCP_INFO helper 和两份 eBPF 重传脚本的审计元数据。
- `tcpquality-evidence.sh` 要求显式选择 `local-evidence` 或 `public-report`，并确认上游会临时创建/删除 `iptables`/`ip6tables` 目标计数链。前者固定使用 `--debug --no-rank-upload`，仅保留本地 debug archive；后者明确允许报告与附属 debug bundle 上传，不再让上传和主机交互边界隐含在上游默认值中。
- 每轮 TcpQuality 证据增加唯一 debug archive 及哈希，并生成稳定的 `retransmission-evidence.tsv`：优先记录 eBPF 序列/SKB 去重来源，其次记录 socket TCP_INFO；回退到整机 `nstat` 时标记 `MEASUREMENT_DEGRADED`，不得作为流级重传率或调优因果证据。
- `diagnose` 和 TcpQuality 主机快照只读增加 `tcp_window_scaling`、`tcp_moderate_rcvbuf`、`tcp_slow_start_after_idle`、`tcp_mtu_probing`、`tcp_limit_output_bytes`、`tcp_notsent_lowat`；TcpQuality 快照另保存默认/参考出口、`/proc/stat`、`/proc/net/softnet_stat` 和 `ss -s`。`diagnose` 在前两个值不为 `1` 或不可读时只输出告警，不自动修改。
- 总控、六份 profile、installer 与 HTB 实验器基线同步为 `0.1.0-rc.13`；状态 schema 保持 4。已发布 rc.12 的 tag、Release 和资产保持不变。
- HTB rate plan/runner/analyzer 升级为 schema 3：流量前执行真实 profile `verify`，冻结 managed profile/version/state/port/state SHA-256，并要求每个 benchmark metadata 再次匹配；candidate plan 还绑定已人工复核 reference 的 manifest、analysis 和 completion 摘要，直接生成计划时也必须显式提供 ack 与三项摘要字段；每样本新增正 `overlimits`、最低 sender 速率暴露、CPU idle/steal、softnet 和接口零异常硬门禁，任一失败均 `REVIEW_BLOCKED` 且 shortlist 为空。
- `experiment-plan.sh` 改为一个调用只生成一个显式 `window-id` 的 `aba` 或 `bab` 三阶段窗口；移除组合式 `--repeat-cycles`，要求反向窗口使用不同 ID、新证据目录和独立 operator invocation。
- `dvt htb` 改用 `/usr/local/sbin/htb-aggregate-experiment` 稳定执行器；开始新实验前要求它与当前 Release 资产 SHA-256 一致，避免 watchdog 因从版本目录直接启动而拒绝建立。新增 VMISS Basic 1C1G / 200 Mbps 完整 campaign SOP；旧 v0.2.1 文档明确降级为历史审计材料。

### Safety

- 17 个受管 sysctl、BBR + fq、自动缓冲矩阵、swap、journald 和 NOFILE 均未改变；未加入 `tcp_slow_start_after_idle=0`、全局 `tcp_notsent_lowat`、更大 socket buffer、固定 MTU/MSS 或持久化 HTB。
- 只读新增字段不进入 `PROFILE_SYSCTL_KEYS`，异常告警也不改变受管状态的 `verify` 语义。目标 VPS 是否支持 eBPF/BTF 必须由运行证据确认；`tcp_info_*` 或 `nstat` 回退不会被误报为 eBPF 成功。
- HTB200 reference、candidate sweep、两个正式窗口和真实代理复验均保持非持久化；reference 人工复核、shortlist 和两个窗口通过也不自动授权开机整形。正式 TcpQuality B stage 固定 `TCPQUALITY_RUNS=1`，避免越过 40 分钟 watchdog。

### Validation

- 新增固定资产常量、模式、debug archive 与 flow-level/降级解析 fixture；补齐 `1C1G / 200 Mbps / 200 ms → 16 MiB` 自动缓冲 fixture，以及两个非受管 TCP 默认值的正常、异常和不可读告警 fixture；六份 profile 仍由单一模板生成。最终本地门禁和目标 VPS 运行验收状态见 [验证矩阵](docs/validation.md)。
- HTB fixture 增加错 profile 在流量前阻断、benchmark/reference 绑定、零 overlimits、低 offered load、高 CPU steal、畸形 CPU/softnet 计数拒绝、稳定执行器同/异 hash、独立 `aba`/`bab` window 和旧组合参数拒绝测试；文档同步 schema 3、三类 gate 与 Basic 完整顺序。
- 本轮未连接目标 VPS，未运行真实 TcpQuality、iperf3 或 HTB；旧 commit 的整机 `TcpRetransSegs` 增量与 v1.00013 流级百分比属于不同测量基线，不能直接拼接比较。

## [0.1.0-rc.12] - 2026-08-18

### Added

- 新增固定 Release 的 `install.sh`：外层 installer SHA-256、内置发布清单摘要和逐资产摘要形成两层门禁；安装到版本化 root-owned 目录并提供 `/usr/local/bin/dvt`，安装过程不自动 apply 或发流量。
- 新增 advisory-only `dvt probe`：必须指定获授权 iperf3 endpoint，按显式/已验证端口上限强制单流 `iperf3 --bitrate`，在预算内重复采样并聚合有效窗口、吞吐中位数和精确 bytes 归一化重传。
- 新增 `dvt htb` 受限 wrapper：简化 preflight、10 秒 smoke、status/stop 和 reference/sweep；候选扫描必须先验证 reference 完成状态、清单、有效窗口并显式确认人工复核。
- 新增独立的 VMISS Debian 13 1C2G / 200 Mbps HTB A/B/A SOP，使用与历史 1C1G 证据隔离的目录、10 秒 smoke gate、A1/B1/A2 冷却和人工恢复边界。
- 新增实验性 HTB 候选速率发现工具链：只读计划生成器按首尾根 `fq` 基线和正序/反序轮次输出 JSON 与 payload 预算；显式 runner 复用 v0.3.0 HTB 状态/恢复门禁和 rc.12 benchmark，并按秒保存不含 endpoint/PID/进程名的 TCP_INFO 白名单指标；只读分析器用 receiver goodput 与 sender retransmits/GiB 的 median/MAD 形成 `REVIEW_REQUIRED` shortlist。
- `benchmark` 可通过 `BENCHMARK_OUTPUT_DIR` 将原始 iperf3 JSON、分方向结构化摘要、主机 TCP/接口/qdisc 计数器、运行元数据和总结果持久化到新的 root-only 证据目录，并生成可复核的 `SHA256SUMS`；
- `benchmark` 在产生流量前按显式 `BENCHMARK_RATE_CAP_MBPS` 或合法管理状态中的端口上限估算 payload 流量预算，并把数值、来源、方向数、总时长和“不含协议开销”边界写入运行元数据；
- 分方向摘要增加 sender 吞吐、sender retransmits、每 GiB 重传数、host-wide TCP/接口增量和 qdisc 增量；存在 `mq` 叶子时汇总 leaf，否则汇总 root，避免 root/leaf 重复计数；
- 新增独立的 `tcpquality-evidence.sh`，只接受已审计 commit `5d1f85a6b8916b73ec0389dbc9b4ed4aa27dae01`、三个固定脚本哈希和固定 rootfs 哈希，保存三轮原始日志、CSV、节点快照、节点漂移和证据清单。
- 新增只读 `experiments/htb-aggregate/experiment-plan.sh`，生成可冻结的 A/B/A、反向复验、冷却时间和可选低速控制点 JSON；它不执行流量或系统变更，也不授权持久化整形。
- 新增厂商 sysctl 配置归属迁移：`preflight` 只读识别 `/etc/sysctl.conf` 中唯一且值严格为 `fq`/`bbr` 的基线，`apply` 完整备份并原子迁移，`verify` 校验双侧哈希，`rollback` 在无外部修改时恢复原文件。

### Changed

- `benchmark` 新增 opt-in `BENCHMARK_ENFORCE_RATE_CAP=1`；与显式 `BENCHMARK_RATE_CAP_MBPS` 同时使用时向 iperf3 传递 `--bitrate`。旧 benchmark 默认行为保持不变。
- 总控菜单和命令行增加 `probe`/`htb`，并只调用同一 `SHA256SUMS` 已校验的 companion 资产；Release 清单扩展到安装后运行所需的全部脚本。
- 临时 HTB 执行器升级为 v0.3.0：严格限定 rc.12 schema 4、`VERIFIED`、200 Mbps 的 `debian13-1c1g`/`debian13-1c2g`，并把实际 profile 和 managed-state SHA-256 写入活动状态；实验期间发生 profile/state 漂移时拒绝继续或按旧假设 stop。
- 总控和六份 profile 版本同步为 `0.1.0-rc.12`，固定 Release tag 改为 `v0.1.0-rc.12`；状态 schema 升级为 4，只读 `update-preflight` 保留对合法 schema 3 状态的兼容；
- benchmark 证据目录采用 `INCOMPLETE → COMPLETED` 终态提交；最终结果绑定核心证据清单哈希，完成标记再绑定清单与结果哈希；计数器缺失/回退、iperf3 字段缺失/类型错误或证据清单校验失败均按验证失败处理；
- TcpQuality 证据协议从人工约定升级为可执行工具：显式检查每个关键步骤，拒绝覆盖既有目录，验证固定 12 列节点 TSV，记录实际节点 URL、CSV/节点快照哈希，并分别报告逻辑节点增删、节点 IP 变化和精确快照一致性。
- 已安装参数与本次 `apply` 输入不一致时，明确说明该调用尚未写入，并区分“输入错误直接 verify/按原参数重试”与“确需改参时显式 purge、重启和重新 apply”；避免普通 rollback 留下 `SWAP_RETAINED` 后再二次清理。
- `/etc/sysctl.conf` 不存在且无需迁移时，新状态中的原始 UID、GID 和 mode 记录为 `null`，不再用 `0/0/000` 表示不存在的文件；脚本仍不创建该文件。状态校验兼容修正前本地候选生成的完整 `0/0/000` 组合，以便安全执行 `verify` 或 `rollback`，但拒绝残缺组合。

### Validation

- 两个允许 profile 及不支持 profile、旧 schema、旧 rc、错误端口和活动 state 哈希漂移的静态 fixture 已覆盖；Debian 13 1C2G 的 rc.12 生命周期基线已冻结，HTB smoke 与 A/B/A 仍待目标机执行。
- 原 1C1G/v0.2.1 SOP 和运行哈希保持不变，不把历史运行证据上推为 v0.3.0 或 1C2G 通过。
- 候选扫描默认/自定义计划、流量预算、非法速率/冷却、runner 计划 schema、mock preflight/start/双 ACTIVE/benchmark/stop/postflight、socket 隐私、合成 shortlist、benchmark manifest/hash 和缺失 `COMPLETED` 负向 fixture 已覆盖；真实 iperf3、目标 VPS qdisc、信号中断和跨窗口统计仍待验证。
- 六份 profile 已由单一模板重新生成；新增 benchmark 缺失/回退计数器、空字段 JSON、`mq` 叶子、manifest 失败终态，以及 TcpQuality pinned 校验失败、节点 schema/漂移 fixture；
- 本地 Bash 语法、静态门禁、控制器 fixture、生成一致性、固定 ShellCheck 0.11.0 和 Release 清单校验已通过；
- rc.11 已有 Debian 13、1C1G、200 Mbps 生命周期和固定 TcpQuality S1/S2 私有证据；这些结果用于改进 rc.12 测量方法，不等同于 rc.12 最终哈希的目标 VPS 运行验收。
- Debian 13、1C1G、100 Mbps、10 GB ext4 的 rc.12 本地候选已完成错误参数拒绝、显式 purge、100 Mbps apply、重启 verify 和幂等门禁，并验证缺失的 `/etc/sysctl.conf` 不会被创建；后续提示与状态语义修正改变了 profile 哈希，最终候选仍须重新绑定哈希验收。

### Safety

- installer 固定 tag 且禁止回退到可变分支/`latest`；同版本目录内容不一致时拒绝覆盖。probe 不反写探测值、不修改 qdisc/sysctl、不授权持久化 HTB；公共测速点可达不等于获得批量测试授权。
- 候选扫描只测试本机 egress 上传，不把下载方向远端 sender 重传归因给本地 HTB；不假设固定 MSS、不计算 packet loss percentage、不使用固定全局重传阈值，也不创建或授权持久化整形。
- 17 个受管 sysctl、BBR/fq、自动缓冲矩阵、swap、journald 和 NOFILE 均未改变；schema 4 仅增加厂商 sysctl 迁移证据和恢复状态；
- 只有 `/etc/sysctl.conf` 中唯一、规范且相同值的 `fq`/`bbr` 定义可自动迁移；不同值、重复定义、其他受管键、其他 sysctl 文件、符号链接和非 root 所有文件继续阻断。回滚发现迁移后文件被外部修改时拒绝覆盖并保留 `DEGRADED` 状态；
- `benchmark` 仍只连接用户明确授权的 iperf3 服务端，不安装软件、开放端口或选择公共服务器；持久化目录必须是尚不存在的绝对路径；
- benchmark 流量估算只是按配置 cap 计算的 payload 上界，不含协议开销；没有显式 cap 或合法管理状态时不猜测数值；
- TcpQuality 工具不执行 `apt`、`sysctl`、`tc`、systemd、swap、网络配置或第三方安装，只读取已固定依赖并产生测试流量和证据文件。
- HTB 排程生成器与已完成 smoke/B1 验证的 qdisc 执行脚本 v0.2.1 分离；排程 JSON 不自动调用 `start`、TcpQuality 或 `stop`。

## [0.1.0-rc.11] - 2026-08-04

### Added

- `diagnose` 增加 `/proc/stat` CPU user/system/softirq/steal 增量、接口收发/丢包/错误增量、可识别 ethtool 错误增量，以及代理主进程和直接子进程的 CPU time、RSS、线程数和 FD 数前后证据；
- `benchmark` 增加 `BENCHMARK_OMIT_SECONDS`、`BENCHMARK_IP_FAMILY` 和 `BENCHMARK_RUN_ID`，并输出脚本 SHA-256、boot ID、管理状态、网络参数、拥塞控制、qdisc 和 iperf3 版本等运行元数据；
- 增加 CPU 与接口计数 fixture，以及 benchmark 预热、地址族和 run ID 的输入边界测试。

### Changed

- `benchmark` 的上传和下载分别采样 TCP、softnet、CPU、接口及 qdisc，避免把两个方向的异常计数合并；默认每个方向预热 3 秒并从 10 秒有效统计中排除；
- 初始化 benchmark 阶段退出状态，避免成功的首个上传阶段因空整数比较被误判为失败；
- `diagnose` 固定复用采样开始时识别的默认路由接口，并在采样结束后再次输出默认路由；诊断和 benchmark 在信号中断时清理 root-only 临时目录；
- README 纳入 rc.10 第二次 TcpQuality 报告，明确同配置组内波动大于或接近 v6/rc.10 组间差异，并给出固定 commit、脚本哈希和参数的重复测试约束；
- 总控和六份 profile 版本同步为 `0.1.0-rc.11`，固定 Release tag 改为 `v0.1.0-rc.11`；状态 schema 保持为 3。

### Safety

- 17 个受管 sysctl、qdisc、swap、journald 和 NOFILE 配置保持不变；不加入 `tcp_slow_start_after_idle`、第三方内核、CAKE、MTU/MSS、CPU steering 或全局 IPv6 策略；
- 新增诊断仅输出进程名称和资源统计，不输出进程命令行；`ss -tinp` 仍只在显式设置 `DIAG_INCLUDE_SOCKET_DETAILS=1` 时输出；
- benchmark 仍要求用户显式提供获授权的 iperf3 服务端，不自动安装软件、开放端口或选择公共服务器。

### Validation

- 六份 profile 已从单一模板重新生成；Bash 语法、控制器 fixture、生成一致性、CPU/接口增量、benchmark 输入边界及既有事务/qdisc 故障注入通过；
- 已校验官方发布包 SHA-256，并使用固定 ShellCheck 0.11.0 复核总控、六份 profile、模板提取 helper 与测试脚本；
- rc.11 尚未取得最终哈希目标 VPS 的 `diagnose`、授权 benchmark、生命周期或真实 VLESS + REALITY + TCP 性能证据。

## [0.1.0-rc.10] - 2026-08-04

### Added

- `diagnose` 改为默认 5 秒增量采样，增加 TCP 重传/超时/监听溢出/TFO、每 CPU softnet、`tc -s -d`、网卡错误、队列 RPS/XPS mask 和接口 IRQ 证据；
- 增加只读报告 3X-UI 生成配置中 `tcpFastOpen`、`tcpKeepAliveIdle`、`tcpKeepAliveInterval` 是否显式存在，不读取或输出其他代理配置；
- 新增显式 `benchmark` action：只在用户提供 `BENCHMARK_HOST` 且已安装 iperf3 时执行 upload/download/both，并输出 JSON 与内核计数增量；
- README 增加 rc.8/rc.9、旧 v5/v6 升级边界，TFO/keepalive 的内核与应用层区别，以及 update、诊断和 benchmark 用法。

### Changed

- 自动 socket 缓冲按 512M/1G/2G 分别采用 1×/1.25×/1.5×BDP，再向上选择 16/32/64 MiB，并继续受 16/32/64 MiB 资源上限保护；
- 默认 200 ms 下，512M、1G、2G 在 100/200/500/1000 Mbps 分别为 16/16/16/16（1000 Mbps 警告）、16/16/16/32、16/16/32/64 MiB；
- 状态 `network` 增加 `buffer_target_numerator`/`buffer_target_denominator`，schema 保持 3，以保留 rc.8/rc.9 回滚兼容性；
- 总控新增只读 `update`，支持同一 `major.minor` 发布线的稳定/rc 通道和显式 `--target`，校验当前/目标资产，执行当前 verify 与目标 update-preflight，并输出人工迁移材料；不自动 rollback/purge/apply/reboot；
- 总控和六份 profile 版本同步为 `0.1.0-rc.10`，固定 Release tag 改为 `v0.1.0-rc.10`。
- 重复 `apply` 只对同一脚本版本和同一网络参数保持无写入幂等；旧状态仍允许 `verify`，但升级 apply 明确要求先 rollback。
- `verify` 也会检查外部 sysctl 文件对受管 key 的重复归属，同值重复定义不再漏报；`diagnose` 只读展示冲突，符号链接按规范路径去重。
- 本地总控、清单和 profile 混用不同 Release 时，完整性错误会提示版本碰撞和独立目录做法；升级文档固定使用版本隔离的临时目录。

### Safety

- 继续不自动启用 RPS/RFS/XPS、IRQ/CPU affinity、busy polling、ECN 或额外高风险 sysctl；新增队列信息仅只读采集；
- benchmark 不自动安装软件、修改 UFW、开放服务端口、选择公共测试点或测试代理业务链路，并把并行数限制为 1–4；
- `tcpFastOpen` 未显式出现只报告为未显式配置，不把 `net.ipv4.tcp_fastopen=3` 误报为 Xray listener 已启用 TFO，也不直接编辑 3X-UI 生成 JSON。
- 完整性校验失败不会自动回退联网下载；不同版本资产混放仍安全拒绝执行。

### Validation

- 六份 profile 已由同一模板重新生成；`bash -n`、控制器 fixture、分档 BDP 资源矩阵、版本选择、跨版本 apply 拒绝、诊断增量、benchmark 参数、状态构造与既有事务/qdisc 故障注入通过；
- ShellCheck v0.11.0 已覆盖总控、六份 profile 和测试脚本；rc.10 Release 尚未发布，公开资产重下载、CI 和真实 VPS 生命周期/性能矩阵待执行；rc.9 的 Debian 13 1C1G/1000 Mbps 证据仅作为历史基线，不上推为 rc.10 通过。

## [0.1.0-rc.9] - 2026-08-03

### Added

- 新增 `debian-vps-tuning.sh` 总控入口，自动识别 Debian 12/13、amd64 和 1C512MB、1C1GB、1C2GB、2C2GB 四个资源档；
- 新增交互安全引导，带宽默认 200 Mbps，支持 100–1000 Mbps；先执行 preflight，确认后才 apply；
- 新增显式 `guided/preflight/apply/verify/status/diagnose/rollback/recover` 调用模式；`diagnose` 只读采集网络与 softnet 状态；
- 新增本地及固定 GitHub Release 资源解析、严格 HTTPS 下载和目标 profile SHA-256 校验；
- 新增 Debian 12/13 的 512 MiB profile、控制器映射、资源缓冲上限、常规 `pfifo_fast`、NOFILE 待安装状态、清单、失败下载和退出码透传测试；
- 预置受状态哈希保护且可回滚的 `x-ui.service` drop-in，设置 `LimitNOFILE=65536`。

### Changed

- 六份资源脚本内部版本同步为 `0.1.0-rc.9`；状态 schema 保持 3；
- 两个兼容名称为 `1c2g` 的 2G 档位正式支持 1–2 vCPU；总控和底层 profile 均校验 CPU/RAM 组合，不新增重复 2C2G 脚本；
- socket 上限按 512M/1G/2G 资源分别限制为 16/32/64 MiB；journald 和磁盘保留量按资源档收敛，swap 默认仍为 1 GiB；
- 2C2G 沿用 2G 网络、swap 和 journald 参数，不启用 RPS/RFS/XPS、IRQ affinity 或 CPU affinity；
- README 将总控入口作为普通用户首选，独立 profile 作为离线、审计和恢复入口；
- Release 必须上传总控脚本、六份 profile 和 `SHA256SUMS`，控制器不回退到 `master`、`main`、`latest`、HTTP 或第三方源。

### Fixed

- swap purge 仅在成功生成同目录临时文件、保留权限并完成原子替换后才更新 `/etc/fstab`；过滤或替换失败时保留原文件并返回失败；
- 总控入口在无 `--port` 和 `PORT_SPEED_MBPS` 时为重复 `apply` 复用已安装状态中的端口带宽，显式参数继续优先。

### Validation

- `bash -n`、四资源档控制器/底层 fixture、六份模板生成一致性及状态/qdisc 故障注入测试已通过；
- ShellCheck v0.11.0 已覆盖总控脚本、六份 profile 和测试脚本；
- 固定 rc.9 Release 的八个资产已发布，并从公开下载地址重新下载后通过 `SHA256SUMS`；
- Debian 13、1C1G、1000 Mbps、ext4 目标机已通过安全引导、首次 apply、安装 3X-UI 前重启验证、安装后严格验证及再次重启后的严格验证；重复 apply、rollback 和业务性能仍待执行。

## [0.1.0-rc.8] - 2026-08-02

### Fixed

- rollback 在 `tc` 恢复命令成功后强制重新读取 qdisc 并与原始快照做语义比较；不一致时记录 `DEGRADED`、保留 `state.json` 和 `qdisc-original.json`，不再删除证据后报告成功；
- 原快照的 `handle 0:` 按 tc 的 unspecified 语义处理，允许受支持的 classless qdisc 使用内核自动分配 handle；原快照显式保存非零 handle 时，恢复命令会携带该 handle 并继续严格比较；
- 保留 `target`、`interval` 和 `ce_threshold` 的 ±1 微秒量化容差，kind、parent、root、显式 handle 和其他 options 仍严格比较。

### Validation

- 增加 `handle 0:` 与自动 handle 等价、显式 handle 不得漂移及显式 handle 恢复命令测试；
- 增加 qdisc 恢复命令成功但后置比较失败的故障注入，确认 rollback 返回失败、保留状态并记录 `ROLLBACK_PENDING → DEGRADED`；
- Debian 12 1C2G、200 Mbps 目标机使用与发布件哈希一致的 rc.7 完成 preflight、apply、立即/重启后 verify、重复 apply、严格 3X-UI verify、rollback、回滚后重启、重新 apply 和最终重启后严格 verify；外部 `/swapfile-3xui` 和 3X-UI/Xray 保持正常；
- 该目标机显示恢复命令后的自动 handle 为 `8001:`，时间字段回显相差 1 微秒，重启后回到原始 `0:` 和精确时间值，由此触发 rc.8 后置验证和 handle 语义整改；
- rc.8 已完成本地静态和失败注入验证，仍需在目标机复测主动 rollback 后置验证。

## [0.1.0-rc.7] - 2026-08-02

### Fixed

- `verify` 对 sysctl 值先折叠首尾空白及连续空格/制表符，再比较字段内容，修复 `tcp_rmem`、`tcp_wmem` 数值一致却因内核对齐格式不同而误报；
- 原始 sysctl 的回滚完成判断使用同一归一化规则，避免已恢复的多值参数仅因显示空白不同而被误判；
- NOFILE 审计显式以制表符传递 soft/hard 两列，不再受脚本全局 `IFS` 排除空格的影响；同时按 `/proc/<PID>/limits` 的固定字段读取值；
- README 的 VPS 命令示例统一按 root shell 编写，不再包含 `sudo`。

### Validation

- 增加 sysctl 多空格/制表符等价和数值变化不等价测试；
- 增加与目标机 `/proc/<PID>/limits` 输出一致的 NOFILE soft/hard 分列测试；
- Debian 12 1C1G、1000 Mbps 目标机已完成 rc.6 `recover` 和 `preflight`；rc.6 `apply` 写入后仅因 sysctl 空白格式误报而触发自动回滚，回滚成功并清理管理状态；
- rc.7 的 apply、verify、重启后 verify 和重复 apply 仍待目标机执行。

## [0.1.0-rc.6] - 2026-08-02

### Fixed

- 修复 Debian 12 自带 jq 1.6 对空输入可能仍返回成功，导致空 `state.json` 绕过 `jq -e` 校验的问题；状态校验现在先检查非空，再用 slurp 强制输入恰好包含一个完整对象；
- 移除流式 `jq | atomic writer` 状态接口；所有状态创建和更新改为“同目录临时文件 → 检查 jq 退出码 → 非空/单对象/schema 校验 → 原子替换”，上游失败不再提交目标文件；
- `state_set_phase`、`refresh_managed_files` 和 swap 所有权更新统一使用同一提交路径，任何失败都保留上一个有效状态；
- 为已确认发生在首次系统写入前的 rc.2 空状态增加显式 `recover`，仅在管理文件、swap 和 qdisc 安全门全部通过时隔离证据目录；
- apply/rollback 的关键步骤不再依赖 `set -e` 在函数或 OR-list 中的隐式行为，改为显式检查并传播失败。
- 区分独立 `preflight` 与 `apply` 内部预检：前者遇到既有状态给出操作提示，后者仍允许相同参数的 `VERIFIED` 状态进入幂等验证路径。

### Validation

- 增加空文件、空白文件、`null`、缺字段对象、多个 JSON 文档和有效状态的校验矩阵；
- 增加无效临时 JSON 不得改变既有目标状态、jq 转换失败不得覆盖状态的失败注入测试；
- 增加 rc.2 空状态受控隔离测试；
- 目标 Debian 12 1C1G、1000 Mbps VPS 已确认 `state.json` 为空、qdisc 快照完整且当前 qdisc 与快照一致；随后 rc.6 `recover` 成功，`preflight` 通过，`apply` 因 sysctl 空白格式误报而自动回滚成功。

## [0.1.0-rc.5] - 2026-08-02

### Fixed

- `fq_codel` 回滚不再把 `tc` 输出中的数据包后缀 `p` 拼入 `limit` 输入，也不再给字节数追加 `b`，修复 `limit 10240p` 导致的恢复命令失败；
- qdisc 语义比较对 `target`、`interval` 和 `ce_threshold` 允许 ±1 微秒回显量化差异，避免把 5000/100000 与 4999/99999 误判为配置漂移；
- qdisc 快照缺失、哈希不匹配、语义不一致或恢复命令失败时，输出具体接口、期望值、实际值或失败命令；
- `preflight` 检测到 `DEGRADED` 等未完成事务时不再误报通过，并对已安装、保留 swap 和异常状态分别给出下一步；
- README 说明 Debian 最小化镜像没有 `sudo` 时，root 用户应直接执行命令。

### Validation

- 增加 `fq_codel` 参数恢复命令回归测试，确保命令使用 `limit 10240` 和原始字节数；
- 增加 qdisc 时间字段 ±1 微秒等价及非时间参数差异测试；
- Debian 12 1C1G、1000 Mbps 目标机已确认 rc.4 回滚失败时当前 qdisc 为 `fq_codel limit 10240p`；rc.5 rollback/apply/重启验证仍待执行。

## [0.1.0-rc.4] - 2026-08-01

### Fixed

- 状态机增加 `APPLYING` 阶段，区分“只建立快照”和“已经开始系统写入”；
- `PREPARED`、`ROLLBACK_PENDING` 或 `DEGRADED` 状态在项目文件、原始 qdisc 和原始 sysctl 均已恢复时，可安全清理残留事务状态；
- qdisc 回滚增加忽略 `refcnt` 和 JSON 字段顺序的语义比较，当前状态已等于快照时不再执行无意义的 replace；
- 参数冲突错误同时输出保存值和当前值；回滚对 service、qdisc、文件、daemon-reload、sysctl 和 swap 分步骤报告失败原因。

### Validation

- 增加 qdisc 语义等价与参数差异回归测试；
- 增加 `APPLYING` 必须先于首个系统写入的不变式检查；
- Debian 12 1C1G、1000 Mbps 目标机确认 rc.3 状态冲突和无诊断回滚失败，rc.4 恢复和 apply 仍待执行。

## [0.1.0-rc.3] - 2026-08-01

### Fixed

- 状态 JSON 构造器不再使用 jq 保留字 `label` 作为变量名，修复 `apply` 在状态初始化阶段退出码 3 的问题；
- 原子 JSON 写入失败时清理临时文件；
- 状态尚未提交前发生错误时，自动清理本次进程创建的 qdisc 快照和空状态目录，不再误报为无法回滚的已安装事务。

### Validation

- 静态测试实际提取并编译四份脚本内的状态 JSON jq 过滤器；
- 增加 jq 保留字和未提交状态清理的不变式检查；
- Debian 12 1C1G、1000 Mbps、XFS 目标机已完成 `preflight`，修复后的 `apply`/重启/回滚仍待重新执行。

## [0.1.0-rc.2] - 2026-08-01

### Fixed

- 已有根 `fq` 或 `mq` 下已有 `fq` 叶子不再被重复替换，回滚也不再重置其自定义 fq 参数；
- `verify` 在没有项目状态时返回明确、可操作的错误信息；
- swap 预检增加根文件系统白名单：允许 ext2/ext3/ext4/XFS，已知不适用或未知文件系统安全跳过自动创建。

### Validation

- 静态测试增加 qdisc 不变式、XFS swap 白名单和未安装 `verify` 提示检查；
- 补齐 T1–T6 目标机、M0–M11 生命周期和 Q1–Q5 qdisc 回归矩阵；真实 VPS 结果仍待执行和回填。

## [0.1.0-rc.1] - 2026-08-01

### Added

- Debian 12/13、1C1G/1C2G 四种独立调优脚本；
- 200 Mbps 默认配置和 100–1000 Mbps 参数范围；
- BBR + fq 能力检测、TCP 缓冲、队列和 keepalive 配置；
- `preflight`、`apply`、`verify`、`status`、`rollback` 接口；
- root-only JSON 状态、管理文件哈希和进程锁；
- 常规根 qdisc 与 `mq` 叶子处理；
- 固定路径、受限大小和事务式创建的应急 swap；
- journald 空间限制；
- 以 `x-ui.service` 为主的 3X-UI/Xray 进程和 NOFILE 审计；
- 静态验证脚本、GitHub Actions、验证文档和安全报告说明。

### Known limitations

- 这是预发布版本；目标 VPS 运行矩阵尚待完成；
- 只支持 Debian 12/13 amd64；
- 不支持复杂 qdisc、策略路由、TProxy、网关或 Docker 防火墙治理。
