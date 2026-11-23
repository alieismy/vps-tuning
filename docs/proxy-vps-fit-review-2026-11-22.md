# 100 Mbps–2 Gbps 代理 VPS 文档与代码评审

2026-11-22。评审对象为主线 `c4e68b8`、主程序 `v0.2.0-rc.4` 和独立离线解释工具 0.1.1。本文是独立评审意见。判断面向 Debian 13、Ubuntu 24.04 主用、Debian 12 兼容，以及原生 systemd 部署的代理服务，以 3X-UI 3.11.0 为具体目标。

**结论：有条件适合作为这些主机的 TCP 配置基线。** 全新安装在原生 systemd、常规路由与可恢复队列的前提下覆盖三种系统和目标带宽输入。新机日常路径最需要关注的是实际 Xray 进程和出口队列能否得到验证；带宽变更、迁移和主动实验有各自的适用条件。现有证据没有量化 2 Gbps 端到端代理吞吐，本次也没有统一迁移的业务需求。对现有正常主机，本轮没有提出改变 17 项 sysctl、默认 BBR + fq 或启用持久整形的依据。

## 优先处理的问题

以下定位均针对评审提交。各项尚未分配实施责任人或日期。修复公开运行资产应进入单独版本决策。R1–R6 沿用首轮编号。日常代理节点优先看 R1 与出口队列核验；R3、R5 及临时 HTB 问题按是否使用相应工具判断。

### R1 · Major · 严格验证可能在未检查代理进程的情况下通过

操作指南要求严格验证确认 x-ui 主进程和直接 Xray 子进程的运行时文件描述符上限（NOFILE）。模板的 `verify_proxy_services` 在 `MainPID` 无效或 `/proc/<pid>/limits` 不可读时跳过整段核验。子进程列表为空也能通过，有子进程时对枚举结果逐个检查 NOFILE，没有辨认哪个是 Xray。显式要求多个 unit 时，未加载项会被跳过，一个活动项就能满足最终计数。[操作契约](usage.md#入口不可用时的严格代理验证) · [profile 模板](../tools/profile-template.sh.in) 第 1503–1538 行

离线抽取 Debian 13 生成脚本实际函数，模拟 `REQUIRE_PROXY_SERVICE=1`、显式 `x-ui.service`、loaded/active、配置 NOFILE 为 65536、MainPID 为 0，函数返回 0。该用例复现的是严格检查的返回值。主机上的面板、端口和客户端连接仍各需自己的证据。自检另以有效 MainPID 和可读的合成进程限额复验：无子进程返回 0，仅有一个限额达标的未识别子进程也返回 0；子进程软限额 1024 或显式要求的唯一 unit 未加载均返回非零。该反例更接近面板在运行、核心未工作的情形。复验替换了 systemd、进程枚举及 /proc 数据，未复现真实主机事故。最小修订是严格检查不能取得所要求的运行时证据时明确失败或报未核验；只有在已启用并要求 Xray 提供业务时才核对预期核心，保留安装前和仅运行面板的合法状态。

### R2 · Major · 首次 apply 已发布文件，所有权记录可能尚未落盘

在 `APPLYING` 阶段，`write_managed_file` 先用 `mv` 发布文件，调用者随后用 `refresh_managed_files` 记录哈希。当文件已成功落到目标路径、状态仍为 APPLYING 且哈希尚未登记时，自动或后续回滚遇到该文件，`assert_owned_file` 会因该阶段缺少哈希退出。离线使用实际 writer 和所有权判定函数，在临时目录模拟已发布、未登记的文件。文件存在，回滚所有权检查退出 4。测试以替身提供 root 元数据和状态读取，未模拟真实磁盘掉电。[profile 模板](../tools/profile-template.sh.in) 第 448、1104、2404、2631 行

该窗口涉及 sysctl、journald、x-ui drop-in 和 fq helper 等首次写入。结论限于自动回滚不能完成，现有状态与文件可保留作人工恢复依据。修订可复用已有状态与哈希机制，在发布文件前登记预期摘要，恢复时逐个核对。用“发布前中断／发布后登记前中断／外部同名文件”验证，维持现有拒绝删除未知文件的保护。

### R3 · Critical（使用指南所示账本路径时）· 完整回滚可能清掉仍在使用的预算账本

高级指南的 probe、benchmark 和 HTB 示例把 ledger 放在 `/var/lib/proxy-vps-tuning/traffic-ledgers/`。预算工具允许在这一位置创建账本，完整回滚及保留 swap 后再 purge 的路径会递归清理整个受管状态目录。随后同名 ledger 不存在时，预算工具可重新创建窗口。由此可能丢失已消耗及已预留的流量额度，下一次主动测量可能超过原先批准的应用流量预算。README 的 `/root/dvt-traffic/` 示例不在该目录中。另一个同类风险是手工选择受管目录内部的迁移 checkpoint；迁移指南给出的默认 checkpoint 位于独立目录。[高级指南](advanced-measurement.md) 第 41、67、140、209 行 · [预算工具](../dvt-traffic-budget.sh) 第 75、120 行 · [完整回滚](../tools/profile-template.sh.in) 第 2387、2474 行 · [迁移准备](../dvt-migrate.sh) 第 182、210 行

自检用临时状态目录和记录删除意图的替身执行实际 SWAP_RETAINED 分支：普通回滚没有请求删目录，显式 purge 才请求整目录清理。未安装时，若独立测量先在该树下建立账本，首次 preflight/apply 的受管路径检查反而会因“已有目录、无有效状态”退出 4。Critical 限于仍需保留账本而又执行完整清理的场景；超出流量预算还需要后续重新建账并发流量，没有观察到真实损失。应优先修正文档示例；新版本在创建 ledger/checkpoint 前拒绝指向受管清理目录的规范路径，回滚发现既有未归属文件时保留现场。已有部署应先盘点账本位置，保留窗口、条目和未结算预留。复审用临时目录和有余额、有预留的账本验证完整回滚与 purge 后仍能接续同一窗口。

### R4 · Major · 迁移中断于 APPLIED 后，continue 会提示一次无法完成迁移的重启

首次 apply 先把状态写为 `APPLIED`，通过配置验证后再写为 `VERIFIED`。一般非零退出、INT 或 TERM 会触发首次 apply 的退出处理并尝试回滚。只有不可捕获中断等情形使 APPLIED 留在磁盘上时，迁移器从 `APPLY_RUNNING` 接续时接受这两种状态并要求第二次重启。目标版本普通 verify 可以检查 `APPLIED`，但它是只读操作。末段又要求落盘状态为 `VERIFIED`，导致流程停在 `VERIFY_RUNNING`。[迁移器](../dvt-migrate.sh) 第 274、287、302 行 · [profile 模板](../tools/profile-template.sh.in) 第 1654–1667、2640–2645 行

本轮以实际 `continue_stage`、`update_phase` 和 `verify_settings` 函数、临时 JSON 与受控 boot ID 运行了三次接续。第一次退出 0 并要求重启，第二次退出 2，第三次仍退出 2，状态始终为 `APPLIED`。核验主机配置的下层调用由成功替身代替，排除了配置校验失败这一干扰。建议在请求第二次重启前拒绝将 APPLIED 推进到重启阶段，并指向目标版本的恢复说明，保留状态和证据；分别回归正常 `VERIFIED`、中断 `APPLIED` 及重复 continue。

同一工具还先检查 checkpoint 不存在，随后用可复用已有目录的 `install -d` 建立它；各个写阶段未持有贯穿“读阶段—执行—写阶段”的 checkpoint 锁，阶段更新共用 `migration.json.tmp`。两个同时执行或重试的写进程可能争用目录或覆盖阶段。正常单操作者串行流程不触发竞争。保留为并发条件风险：源码能确认互斥缺口，本次没有并发运行证据支持对具体后果单独定为 Major。先用两实例检查目录与阶段是否确实争用；若处理，范围限于独占建目录和同一 checkpoint 的写操作。[迁移器](../dvt-migrate.sh) 第 170–183、206–214、307–315 行

### R5 · Major · 高级测速预算对预热字节和实际发送速率的处理不完整

- **成功结算。** 旧 benchmark、probe 和候选速率 sweep 预留时计入预热，完成后仅加总来自 iperf3 `end.sum_sent.bytes` 的有效窗口字节。非零 `--omit` 会先产生预热流量，并将预热排除在测试统计之外，账本因而会释放一部分已经消耗的额度。已核到 iperf3 3.18 在生成结束统计时从发送总量扣除预热字节。旧 probe 默认预热 2 秒、旧 sweep 默认 3 秒；父级预留模式由父级结算，子 benchmark 不重复扣账。显式设为零预热，以及新版 measure 固定使用零预热时，这一项不触发。[iperf3 3.18 统计实现](https://github.com/esnet/iperf/blob/3.18/src/iperf_api.c#L3905) · [计数模板](../tools/measurement_counters.sh.in) 第 233 行 · [benchmark](../tools/profile-template.sh.in) 第 3156 行 · [probe](../dvt-probe.sh) 第 278 行 · [旧 sweep](../experiments/htb-aggregate/rate-sweep-run.sh) 第 573 行 · [iperf3 参数说明](https://software.es.net/iperf/invoking.html)
- **预算上界。** 直接 benchmark 默认不向 iperf3 传入 `--bitrate`。在 2 Gbps 主机上以 200 Mbps 做预算估算时，发送端仍可快于估算速率；事后提交实际字节不能追回已用流量。即使显式限速，旧工具失败路径仅按有效窗口加预热预留，执行器硬超时与终止宽限允许更长的存活时间，失败扣款缺少最坏情况下的上界证明。进程额外存活不证明额外发送；本轮没有测出超时流量。项目要求主动测试在批准的本地预算内启动。[项目预算契约](network-tuning-and-test-strategy.md) · [预算与限速实现](../tools/profile-template.sh.in) 第 2875、2920、2988、3068 行 · [执行器](../tools/measurement_phase.sh.in) · [高级测量说明](advanced-measurement.md)
- **直接可复核的文档错误。** 指南示例为 200 Mbps、有效 10 秒、预热 3 秒、双方向。按当前预留公式需 650,000,000 字节，示例只给 629,145,600 字节，空账本也无法启动。该拒绝符合预算门禁。另有旧 probe 在 reserve 后才校验输出目录，目录已存在即退出，网络尚未启动，额度仍为 RESERVED。旧 sweep 与 TcpQuality 也在 reserve 后才建立输出目录及错误处理，目录创建失败同样可能误占额度；这是本地准备顺序的 Minor 问题。[示例](advanced-measurement.md) 第 55–70 行 · [probe 顺序](../dvt-probe.sh) 第 202–217 行

建议在现有预算路径处理三件事。先完成无流量的本地准备。使用硬预算时，需要可靠的发送上界；开放速率的研究应如实说明预算能力。正常结算要覆盖预热，缺少可信全程字节时可采用有依据的保守扣款，并至少计入已知发送量。当前 `commit-unknown` 只扣原计划，已知有效字节超过计划时直接套用仍会少记。[账本结算](../dvt-traffic-budget.sh)

文档示例可缩短时长或降低测试速率，保留原预算。复审使用离线样本和受控端点即可，不需要在业务机上跑高速测试。

### R6 · Major · 仅改套餐带宽时，错误提示会引导用户完整回滚

已管理主机误用 `apply --port` 改套餐时，拒绝写入新的受管配置是正确行为。独立 preflight 会提示 reconfigure，apply 自身的参数不一致分支却统一提示 purge 项目 swap、rollback、重启并重新 apply。对于同版本、同 profile、状态为 `VERIFIED` 且只改变套餐带宽的情形，现有 `dvt reconfigure --port <Mbps>` 可以保留其他设置。照错误提示执行会引入一次不必要的回滚和重启，也可能触及 R3 的账本目录。建议只调整分情况提示，保留异版、损坏状态和其他参数的原有门禁；用 500→2000 Mbps 的同版样例检查退出码、无写入及推荐入口。[模板](../tools/profile-template.sh.in) 第 2492–2519、2617–2620 行 · [README 常用操作](../README.md#常用操作)

### 日常验证与诊断

- **Major，实际出口检查可能空跑。** `verify_current_qdiscs` 只遍历当前默认路由接口，枚举为空时失败数仍为零。实际函数以空接口列表返回 0，以单个 fq 接口返回 0，以单个 HTB 接口返回 1。首次 preflight 另有非空检查，因此影响是后续 verify 对当前出口的证明力。建议只在本应检查的接口数为零时报告无法验证；无须强制当前接口集合与安装时相同。[profile 模板](../tools/profile-template.sh.in) 第 796–800、1559–1584 行
- **fq 服务持久性证据。** apply 使用 `systemctl enable --now` 安装开机恢复队列的 oneshot 服务，并设置 `RemainAfterExit=yes`。verify 核对文件摘要、`FragmentPath` 和当前队列，但不查 unit 是否 enabled 或 active。若服务随后被禁用且当前队列仍为 fq，这些检查仍可通过，verify 不能证明 helper 下次启动会执行。系统默认队列和网络初始化仍可能得到 fq。收回将这项单列 Major 的判断；仅当要承诺 helper 开机生效时，补查 unit 的启用状态与执行结果。此项为当前源码核对，未对真实 unit 作更改。[profile 模板](../tools/profile-template.sh.in) 第 1376、1395、1639–1642 行
- **Minor，3X-UI 自定义目录。** 3.11.0 的 Debian unit 默认工作目录与 DVT 读取的 `/usr/local/x-ui/bin/config.json` 相符。上游允许 `XUI_BIN_FOLDER`，DVT 固定读默认路径。重定位后可能提示不可读，或在旧文件仍存在时报告旧值。该项影响 TCP Fast Open/keepalive 诊断解释。建议把默认路径前提写明，无法确认来源时显示“未确认活动配置”，无需读取面板数据库。设计范围第 61 行写明解析生成 JSON，第 101 行却称不读 Xray JSON；可随相应文档修订统一为“读取生成文件，仅输出指定 socket 字段”。没有证据显示凭据泄露。[设计范围](design-scope.md) · [DVT 诊断](../tools/profile-template.sh.in) 第 2730–2748 行 · [上游 unit](https://github.com/MHSanaei/3x-ui/blob/v3.11.0/x-ui.service.debian) · [目录选择](https://github.com/MHSanaei/3x-ui/blob/v3.11.0/internal/config/config.go) · [Xray 配置与进程](https://github.com/MHSanaei/3x-ui/blob/v3.11.0/internal/xray/process.go)

### 主动测量与临时 HTB 另有两项可重现的遗漏

- **Major，仅限使用临时 HTB 的故障恢复。** 独立看护在超时后确认 owner 仍在，随后发信号。若 owner 恰在这两步之间退出，`os.kill` 可抛出 `ProcessLookupError`，控制流跳过后面的 `restore`。对实际 `watch` 注入该异常，恢复调用数为 0；让同一函数在检查时已发现 owner 退出，恢复调用数为 1。若另一路径尚未恢复，临时整形可能继续影响整接口。建议仅对“目标进程已不存在”继续执行已有恢复，保留其他错误及快照归属检查。未在真实 Linux 重现竞态或残留限速。[临时 HTB 看护](../dvt_htb_transaction.py) 第 433–455 行
- **Major，仅限相应多队列网卡的测量。** 共享计数器用接口、作用域、类型和 handle 拼接键，缺少 parent。合成 `tc` 输出中，不同 parent 的两个 `fq 0:` 生成同一键，实际差分函数退出 44；单叶对照返回 0。parent 为 `1:a` 时，实际采集函数将叶子归为 `other`。这会使样本失败或缺少相应叶子的统计，不能据此判断路径掉包或带宽不足。建议将 parent 纳入队列身份并接受十六进制句柄，复用已有差分核验。该采集路径与持久配置的 mq 转换/回滚是不同函数。[共享计数器](../tools/measurement_counters.sh.in) 第 102–130、142–164、233–267 行

## 需求与实际覆盖

| 用户场景 | 当前可用能力 | 已达到的证据层级 |
|---|---|---|
| Debian 13 主用 | 兼容旧资源档，其他受支持资源选 adaptive。支持 x86_64、aarch64 | rc.4 双架构隔离客体通过，另有 x86_64 legacy。2026-10-09 至 11 日记录的五台 rc.2、100/200/500 Mbps 的面板、真实代理及重连由用户逐台确认；历史 1 Gbps 主机另有旧版主机侧严格 verify。 |
| Ubuntu 24.04 主用 | 自适应 profile，原生 systemd，支持两架构 | rc.4 双架构全新安装、重配置、重启和回滚有 VM 证据。仓库未提供该系统上 3X-UI 3.11.0 的对应客户端验收。 |
| Debian 12 兼容 | 与 Debian 13 相同的资源选择机制 | rc.4 双架构 adaptive 生命周期记录齐全；本轮未发现需要为 Debian 12 单建策略的证据。 |
| 100–2000 Mbps 全新安装或同版改套餐 | 受管带宽 1–10000 Mbps。重配置要求同 profile 且已有 VERIFIED 状态 | 客体在 1 Mbps 输入执行 apply，重配置到 10000 并 verify，回到 1 后再重启；高速配置跨重启及真实高速流量未在这条序列中验证。本轮补测生成函数的 100/500/1000/2000。没有测得 2 Gbps 客户端吞吐。 |
| 已有主机跨版本迁移 | rc.4 仅接受指定 Debian 来源及 100–1000 Mbps；不含 Ubuntu、2000 Mbps 和 0.2.0-rc.1 来源 | 文档与代码一致。属于已知能力缺口；新安装支持某系统不能当作存量升级承诺。 |
| 3X-UI 3.11.0 原生代理 | 上游版本对应 Xray-core 26.10.21；正常默认安装仍由 x-ui 启动 Xray。DVT 管主机 TCP 与服务限额 | 仓库明示历史负载基线为 3X-UI 3.4.2／Xray 26.6.27。旧记录和上游契约不足以证明目标版本已在这些主机通过。 |

非默认配置还要区分两种操作。同版本 reconfigure 会保留原 RTT 和显式缓冲；跨版本迁移 checkpoint 固定带宽，目标 preflight/apply 显式传递带宽，未从来源状态固定重放自定义 RTT、显式缓冲或 swap 设置。在没有额外环境参数的正常调用下采用目标默认值。既有自定义值应在迁移前核对；尚无要求改造为通用参数迁移器的依据。[重配置](../tools/profile-template.sh.in) 第 2525–2556 行 · [迁移器](../dvt-migrate.sh) 第 214–222、268–278 行

平台范围还要求至少一个可用逻辑 CPU、384 MiB 可识别内存、原生 systemd、可用 BBR/fq 与可恢复的常规队列拓扑。独立测量、只读诊断和受管安装的前提不同。判断依据见[平台契约](platform-support.md)、[五台验收](validation.md#rc2-fleet-acceptance)、[实际 VM 步骤](../tests/platform-guest.sh)、[迁移准入](migration.md#先判断能否迁移)、[主入口](../README.md)和[上游固定版本](https://github.com/MHSanaei/3x-ui/releases/tag/v3.11.0)。

## 2 Gbps 在低内存与长 RTT 下意味着什么

`--port` 填服务商套餐上限，用于估算 TCP 带宽时延积（BDP）。在 2000 Mbps、往返时延 200 ms 时，1×BDP 是 50,000,000 字节，约 47.68 MiB。下表来自实际生成脚本的参数函数。Debian 13 行使用固定资源档，Ubuntu 24.04 行为 adaptive 输入不同的模拟可识别内存。最后一列是脚本按字节和套餐速率换算的时间，没有测量网络。

| 资源档 | 策略目标 | 自动缓冲上限 | 报告模式 | 换算覆盖 |
|---|---:|---:|---|---:|
| 固定 512 MiB | 1×BDP | 16 MiB | auto-clamped | 67 ms |
| 固定 1 GiB | 1.25×BDP | 32 MiB | auto-clamped | 134 ms |
| 固定 2 GiB | 1.5×BDP | 64 MiB | auto-clamped | 268 ms |
| Ubuntu adaptive，1024 MiB | 1×BDP | 32 MiB | auto-clamped | 134 ms |
| Ubuntu adaptive，1984 MiB | 1×BDP | 62 MiB | auto-clamped | 260 ms |
| Ubuntu adaptive，2048 MiB | 1×BDP | 64 MiB | auto | 268 ms |
| Ubuntu adaptive，4 GiB | 1×BDP | 64 MiB | auto | 268 ms |

**Minor，adaptive 有一条可重现的错误告警。** 1984 MiB 样例将候选的 64 MiB 档降至 62 MiB，但 62 MiB 仍高于 50,000,000 字节目标，脚本却报告“未达到 1/1×BDP 性能目标”。1024 MiB 样例才确实低于目标。两者都发生了内存封顶，两者的 `auto-clamped` 都成立。最小修订是按最终字节上限是否小于目标选择告警文字，保留现有封顶、取整和状态语义。复验只替换生成脚本读取内存的函数。[告警条件](../tools/profile-template.sh.in) 第 225–242 行

固定 2 GiB 档的 64 MiB 已覆盖一倍 BDP，截断的是它额外要求的 1.5 倍余量。相同带宽下，较短 RTT、并发短连接与跨洲单条长连接的瓶颈可以不同。代理还分别连接客户端和目标服务，两段路径的 RTT、方向、协议及 CPU 开销均可能不同。应读实际可识别内存：Ubuntu 24.04 总控选 adaptive；同样标称 2 GiB 的 Debian 固定档与 Ubuntu adaptive 可有不同系数和封顶。固定 Debian 档默认启用项目 swap 创建策略，adaptive 默认关闭；还取决于已有 swap、文件系统等前置条件。固定 2 GiB 档的计算结果不能外推给全部 2 GiB VPS。没有目标机内存、实际路径 RTT、并发和用户症状时，不宜统一增大缓冲或据此估算一条代理连接的实际速度。[缓冲计算](../tools/profile-template.sh.in) 第 185–242 行 · [资源档声明](../tools/render_profiles.py)

独立 `measure` 测 VPS 向对端发出的单流 TCP，适合定位特定路径问题。以默认 5 秒、600 MiB 预算离线生成 `--rate-cap 2000 --plan-only`，第一组正式样本速率为 200 Mbps，单次预留需 701,048,576 字节（668.57 MiB），已经超过整个默认窗口。协议预检另计。停止是预期保护行为。旧 probe 的 1000 Mbps 上限和旧 HTB 的 200 Mbps 研究对象是另一组已说明的限制。项目默认的低流量客户端验收适合常规业务机。[测量计划](../dvt-measure.py) 第 111–135 行 · [测量指南](automatic-measurement.md) · [历史实验入口](advanced-measurement.md)

## 复审条件与验证记录

1. **业务适配。** 若要对某一组合给出业务兼容结论，优先复用该主机已有、可绑定版本的证据；缺失部分随下一次正常部署补齐。撤回固定要求两种系统各取一台的建议。记录实际 DVT、面板和 Xray 版本、资源、套餐带宽、核心进程与 NOFILE、重启后状态，以及真实客户端的首次连接、传输和重连。使用正常服务的地址族和协议即可。已有 Debian 12 VM 兼容记录可继续复用；需要对具体 Debian 12 业务主机作承诺时再补相应实机证据。
2. **性能主张。** 仅在需要判断具体吞吐或出现卡顿、断流时，先固定客户端路径、方向、RTT、并发和流量预算，再对照同条件的主机 CPU/steal、重传、队列和实际业务吞吐。历史 TcpQuality 的不同时段顺序比较，以及临时 HTB 的恢复成功，均不足以识别真实代理提速的原因。[已有业务性能矩阵](validation.md#业务性能矩阵)
3. **工程证据。** 首轮评审检查中英文入口、平台/操作/迁移/测量指南、验证记录、发布说明、总控与安装链、主模板和生成资产、恢复与预算工具、测量/HTB 及解释工具与相关测试。历史发布与实验按版本归属和可支持的主张抽查，未逐行重做全部历史研究。生成一致性通过，24 项运行清单摘要和 README 安装器摘要相符；本地 Python 发现 154 项，143 项通过、11 项跳过；ShellCheck 0.11.0 检查 29 个脚本及 9 个生成 helper 通过。
4. **证据来源。** 首轮已读回评审提交的 Linux CI 成功状态，包含静态、安装器/迁移、隔离 HTB 和 ShellCheck 步骤；另读回 rc.4 固定提交的七个客体作业均成功。本轮没有重跑 Linux root 生命周期、连接真实 VPS、操作面板或执行公网测速。候选与正式实现分别核对：10 月本地候选已有部分相同问题的回归或修复线索，不能计成当前主线已修复；立项时可优先核对、复用适用部分。后续复审以正式改动、针对性反例、目标平台验证和业务回传分别更新结论。[主线 CI](https://github.com/alieismy/vps-tuning/actions/runs/41200090850) · [平台 CI](https://github.com/alieismy/vps-tuning/actions/runs/38337708776)
5. **本次自检。** 在正式提交对应的生成脚本和模块上，以离线正反例核对严格服务验证、账本清理分支、空出口列表、多队列差分、临时 HTB 看护及 adaptive 告警。另重跑平台 profile 8 项、临时 HTB 22 项、主动测量 25 项，合计 55 项通过。上述替身只验证指定分支的返回值、输出和调用。全量 154 项统计及 CI 读回属于首轮记录。

## 2026-11-23 实施接续

用户批准实施后，已形成 [rc.5 本地候选](releases/v0.2.0-rc.5.md)。上文 R1–R6 及附加发现描述评审基线 c4e68b8，代码定位对应该基线。候选修复严格服务和空接口核验、首次文件发布登记、账本及 checkpoint 路径与完整清理、APPLIED 接续提示、测量预算、改套餐指引、多队列计数、临时 HTB 看护及缓冲告警。Xray 诊断标明默认路径与活动来源未核验。

并发 checkpoint、fq helper 开机证据和业务兼容按自检后的限定结论保留。软件节拍预算增加硬超时与终止余量，但实际物理流量上界仍需运行证据。旧 HTB 同速软件 cap 可能使整形暴露不足；即使 overlimits 有值，也不能排除节拍对突发、CPU 和重传的影响，不能直接与旧无节拍归档作因果比较。阶段和会话记录实际限速元数据。

实施自检进一步修正恢复归档审批目标、显式服务参数解析退出码和离线校准报告的 rc.5 兼容遗漏。清理前发现未知文件时保留完整现场；检查后其他 root 写入的并发窗口仍可能留下新文件而丢失部分事务材料，不能据此宣称完整并发恢复。最终验证记录和限制见候选说明与项目备忘。
