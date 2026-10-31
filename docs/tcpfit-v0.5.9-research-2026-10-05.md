# `Kylin010/tcpfit` v0.5.9（`38fbf5a`）增量研究与吸收评估

日期：2026-10-05（Asia/Singapore）

后续复核：[2026-10-31 当前工作区吸收评估](#2026-10-31-reassessment)。后续实施及发布决策见[最小吸收方案](tcpfit-minimal-adoption-plan-2026-10-31.md)；本研究中的未批准状态描述研究阶段。下文原研究与其提交、日期保持历史效力；当前建议以该复核节为准。

状态：研究证据包与决策输入；未批准实现。只读检查固定源码、补丁、Release 说明和一手技术资料；没有运行第三方脚本，没有连接 VPS，也没有产生公网测速流量。

研究模式：`rd-research` 技术与开源研究。前序研究见 [v0.5.8 研究](tcpfit-v0.5.8-research-2026-09-11.md)和 [2026-09-28 可行性评估](tcpfit-policer-refactor-feasibility-2026-09-28.md)。本报告只评估两者之后新增的唯一提交，不重做历史提交矩阵。

## 1. 结论

**结论：当前实现不需要修改，没有可直接移植的代码。置信度高。** v0.5.9 修复的问题大多是本项目早已用更强机制防住的失败模式，例如扫描流量失控、不完整扫描被说成“没有限速器”、写入失败仍报告成功，以及非交互环境自动接受默认值。这些修复为本项目保留现有设计提供了外部现场佐证，不需要追加实现。

本轮形成两项新的有条件候选，并为两项既有候选补充设计输入：

| 编号 | 内容 | 性质 | 置信度 |
|---|---|---|---|
| N1 | 高速率测量增加多流聚合对照，用于区分单流受限和聚合瓶颈 | 新增条件候选；当前 `parallel=1`，入口允许最高 10000 Mbps | 中 |
| N2 | 验证 networkd 重启或链路重建后 fq 是否仍保持 | 新增低优先级验证候选；当前只有源码推断和重启生命周期证据 | 中 |
| U1 | PPP/PPPoE 候选补充 ARPHRD 设备类型判断，并按接口过滤默认路由 | 补充 2026-09-11 既有候选 | 高（内核常量已核实） |
| U2 | 持久 HTB 补充约束：负载不足的新测量，不能覆盖或删除较强的旧配置 | 补充既有独立决策项 | 中 |

initcwnd 持久化在 v0.5.9 中需要四种入口，且存在已知缺口，这进一步支持不采纳的结论；其他机制已覆盖或不适用。

最强反对意见：tcpfit 有大量来自 10G 主机和多种网络管理器的用户现场反馈，本项目的公网证据主要来自低速单流，因此 tcpfit 发现的问题可能是本项目尚未暴露的问题。本轮逐项对照了本项目源码。凡是能对应到本项目的路径，都已存在等价或更强的控制，所以这项反对意见不会推翻“无需修改”。它确实提高了 N1 的优先级，而且只在高速测量进入范围时才需要处理。

## 2. 研究问题、基线与方法

研究问题：

1. 最新提交实际改了什么？Release 中的声明有哪些可以从仓库复现？
2. 每项变化在本项目当前实现中是否已覆盖、是否适用、能否带来新增价值？
3. 哪些内容只能作为有条件候选？进入实施需要什么新证据？

| 对象 | 固定证据 | 能证明的范围 |
|---|---|---|
| tcpfit | `main` 与 `v0.5.9` 解引用均为 `38fbf5af30daf87735f2ffbc5e0905033ee2b86e`；tag 对象 `f834e23f49862bc6f7d8556f33c78a1d5fbb7fe5`，打标时间 `2026-10-01T22:16:42Z`；Release 发布时间 `2026-10-01T22:18:44Z`，不是 draft，也不是 prerelease | 2026-10-05 读取的远端引用与源码 |
| 变更范围 | 相对 `7633158`（v0.5.8）改动 5 个文件，`+971/−132`；`tcpfit.sh` 变更 1008 行，现为 4484 行 | 补丁全文已逐段阅读 |
| 文件摘要 | `tcpfit.sh` `8331cc40950229a3280ce32406330a85b1a3d21ba398a4db3dc7e25c39783741`；`install.sh` `cb8362f96b22f196eebefe6b81d9526757cc9807222a0b1626e7303304b8450a`；与仓库内 `SHA256SUMS` 一致 | 只核对仓库文件；没有下载 Release 资产做逐字节比对 |
| 本项目 | `1c5e922c2fce916d5217bf6c238d6cd50a8c51b0`（`measurement-explanation-v0.1.0`），工作区只有用户未提交的 `AGENTS.md` 修改 | 当前源码对照；`AGENTS.md` 阶段文字落后于备忘，属于既有治理待办 |

方法：将上游克隆到会话临时目录（不进入仓库），用 `git diff 7633158 38fbf5a` 取得补丁，并结合 [Release 说明][R1] 逐项定位变化。随后在本项目的模板、测量、预算、安装和 HTB 事务源码中查找对应路径。影响判断的外部事实使用一手来源核实，包括内核提交、内核文档、systemd 手册源文件和内核 UAPI 头文件。检索关键词为英文，例如 `netdev_budget_usecs minimum 2 jiffies commit`。

证据边界：Release 中“新增流量、持久化两套回归测试，连同原有五套全部通过”、容器 networkd 验证、OVH 10G 实跑和“400 GB”用户事故，都是维护者声明。上游仓库只跟踪 9 个文件，没有测试目录，因此这些测试无法从仓库复现。本报告只把它们当作维护者报告的现场现象，不当作已复现事实。

## 3. 变化与本项目逐项对照

“已覆盖”只表示本项目源码中存在对应控制，不表示本项目参考或复制过 tcpfit。

| # | v0.5.9 变化（上游位置） | 本项目对应实现 | 判断 |
|---|---|---|---|
| 1 | 扫描流量失控：精扫档数加上限；按实测速率估算流量；超过 50 GB 或明显超出预估时确认，默认不扫；`--yes` 放行；取消后不再满速验证（[T1][T1]、[T2][T2]、[T3][T3]） | 每次尝试发流量前按 `rate×(秒数+23)+1 MiB` 预留，余额不足时以 `BUDGET_LIMIT` 停止；失败按预留额结算；精扫最多 3 档；计划可先 `--plan-only`（[D1][D1]、[D2][D2]、[D3][D3]） | **已覆盖且更强。** tcpfit 的估算不是上界：不含不限速基线及其补采、8 流复核、异常复测、向下控制点，也不含每档最多 3 次的重试（[T4][T4]、[T5][T5]）。确认发生在不限速基线之后，所以 Release 自己的表格写明拒绝后仍会用掉约 13 GB。这次事故从外部支持保留逐次预留账本，不采用“估算加确认线” |
| 2 | 菜单检测到没有终端就退出，避免自动选择 1 并跑完向导（[T6][T6]） | 非交互运行 probe 必须加 `--yes`；总控在非交互环境中必须指定 action，guided 需要终端（[D4][D4]、[D5][D5]） | 已覆盖。非交互且没有指定带宽时，总控使用默认端口速率，只影响缓冲推导，不产生流量 |
| 3 | 单流有丢包而 8 流零丢包时，按聚合结论处理；8 流负载不足时判为“判不出”（[T7][T7]） | 测量固定 `parallel: 1`，`--rate-cap` 最高 10000；负载不足标为 `UNDERDRIVEN`，接收端偏离标为 `RECEIVER_DIVERGENCE`，任一问题都进入 `INSUFFICIENT_EVIDENCE`（[D6][D6]、[D7][D7]） | **条件候选 N1**。当前低速范围不受影响。高速单流可能先受单连接窗口、CPU 或对端限制。上游说的“单流丢包不是限速器”超出了证据：按连接限速时也会出现单流有丢包、8 流干净。这个结论只能支持“聚合整形无益”，不能证明不存在限速器 |
| 4 | 记录扫描覆盖率（`VERIFIED_TO`/`REQUESTED_TO`）；中途失败或负载低于标称 70% 时判为 `INCONCLUSIVE`，并保留旧整形（[T8][T8]、[T9][T9]） | 分析器把不完整、控制无效、样本无效和负载不足都并入 `INSUFFICIENT_EVIDENCE`；无上升时只报告 `NO_RISE_IN_TESTED_RANGE`；`policer_identified=false`，不给整形建议（[D7][D7]） | 已覆盖。本项目测量不会自动应用或删除配置。“新的弱结果不得推翻旧的强结果”这条原则补充到持久 HTB 决策项（U2） |
| 5 | initcwnd 持久化改为四条入口：PPP 钩子、networkd drop-in（systemd ≥255）、dispatcher 钩子、开机单元（[T10][T10]） | 受管集合为 17 项 sysctl，不管理 initcwnd/initrwnd（[D8][D8]） | **进一步支持不采纳。** systemd 源文件确认 `[DHCPv4] InitialCongestionWindow=` 从 v255 开始提供（[N1][N1]）。上游注释承认 dispatcher 入口在 networkd 重启而链路保持 routable 时不会补回。上游此前 [`a8ad428`][C1] 也报告过小带宽限速线路上 initcwnd 32 的负面实测。路由属性的持久化、所有权和回滚成本很高，收益证据不足 |
| 6 | 回滚与恢复存档时，只在当前路由上摘除或套用窗口字段，不再回放旧的整条路由（metric 是路由键）（[T11][T11]） | 本项目不改路由。同一原则已用于 rc.18 的 mq 回滚：按当前非零根 handle 和保存的队列 minor 重建 parent，不复用保存时的 parent（[v0.5.8 报告补充](tcpfit-v0.5.8-research-2026-09-11.md#2026-09-14-补充更正mq-0-句柄寻址)） | 已覆盖（同类原则） |
| 7 | 快照和 sysctl 写入改为临时文件、完整性检查、结尾标记和原子改名；整形或验证失败时不再报告成功，退出码随之变化（[T12][T12]、[T13][T13]） | 受管文件使用临时文件、显式 `chmod`/`chown` 和 `mv`，并记录 SHA-256；状态 JSON 提交前校验；`sysctl -p` 失败即报错；有独立的 `EXIT_VERIFY`/`EXIT_ROLLBACK`（[D9][D9]、[D10][D10]、[D11][D11]） | 已覆盖。结尾标记针对“截断但 `cat` 返回 0”的场景；本项目已有退出状态检查、哈希记录和应用后核验，再加结尾标记没有新增保护 |
| 8 | 不再设置 `netdev_budget_usecs`（[T13][T13]） | 17 项受管 sysctl 不含该项（[D8][D8]） | 不适用。上游内核 [`c180188ec022`][N2] 已把下限设为 2 jiffies（HZ=250 时为 8000 µs），因此旧值 4000 会被拒绝。这也支持只为有证据的参数扩展受管集合。上游列出的稳定分支回移版本号未核实 |
| 9 | 安装器改为临时文件、`bash -n` 和原子改名（[T14][T14]） | 固定 Release tag，校验 installer 内置的清单摘要，再逐项校验资产（[D12][D12]） | 已覆盖且更强。上游仍下载可变的 `main`，agent 模式不校验摘要；`update` 拿不到清单时会退回版本号校验（[T15][T15]）；默认遥测仍开启（[T16][T16]）。均不采用 |
| 10 | 多出口或策略路由时，按测速目标运行 `ip route get` 选择网卡（[T17][T17]） | 用 `ip -j route get` 解析端点出口并固定路由，每次尝试前复核；HTB 要求出口等于已确认接口（[D13][D13]、[D14][D14]） | 已覆盖 |
| 11 | 后台统计子进程继承锁 fd，导致同一次运行再次加锁时被自己挡住（[T18][T18]、[T16][T16]） | 每次调用只加一次锁；iperf3 子进程同步等待，并按进程组回收；Python 子进程默认不继承 fd（[D15][D15]、[D16][D16]） | 已覆盖。父进程被强杀后，残留的 iperf3 会持有锁直到超时，这能阻止流量重叠，属于保守行为 |
| 12 | 把 HTB 守卫下沉到 `qdisc_save` 这一共同入口；拒绝替换不是 tcpfit 下发的 HTB（[T19][T19]） | HTB 事务预检只接受可完整恢复的单一根 fq，存在 class/filter、mq、clsact 或 ingress 时拒绝（[D17][D17]） | 已覆盖且更严格 |
| 13 | 输入 `08` 等前导零时，bash 算术按八进制解析出错（[T20][T20]） | 用户数值统一使用 `10#` 归一化（[D18][D18]、[D19][D19]、[D20][D20]） | 已覆盖 |
| 14 | 用 `/sys/class/net/<if>/type == 512` 判断 PPP 设备；钩子按 `$1` 接口过滤默认路由（[T10][T10]） | 本项目没有 PPP 支持；2026-09-11 已登记为条件候选 | **补充 U1。** 内核 UAPI 确认 `ARPHRD_PPP` 为 512（[N3][N3]）。“目录存在不等于该接口由 pppd 管理”也应纳入该候选的判据 |
| 15 | `networkctl status \| grep -q` 在 pipefail 下因 SIGPIPE 误判（[T10][T10]） | `\| grep -qx` 和 `\| head -n1` 只用于 jq 的单值或短输出（[D21][D21]） | 低风险，无需修改（推断，置信度中高）。jq 的短输出在退出前一次写完，读端提前退出时写端没有剩余写入；模板中已有 SIGPIPE 注释，说明此前已注意到这一问题 |
| 16 | 部分 locale 下 mawk 输出逗号小数点（[T1][T1]） | 唯一带小数的 awk 输出只用于显示 | 不适用。上游关于 mawk 行为的说法未核实 |

## 4. 候选的进入条件与最小验证

### N1：高速率多流聚合对照

- 价值：单流在高速率下的上升或负载不足，可能来自单连接窗口、CPU 或对端，不一定是出口聚合瓶颈。加入同端点、同时窗的多流对照，可以区分“只限制单连接”和“聚合也受限”。
- 进入条件：用户把 ≥1 Gbps 的测量纳入目标；或者真实报告中较高档位反复出现 `UNDERDRIVEN`，或只有单流出现上升。
- 必须保留的约束：每条流都计入逐次预留；记录接收端能力；“多流干净”只能写成“未观察到聚合瓶颈”，不能写成“没有 policer”；不自动给出整形值。
- 最小验证：合成样本覆盖单流上升而多流干净、两者都上升、多流负载不足三种情况；只有在用户另行授权预算时，才做一次同端点的公网对照。

### N2：networkd 重启或链路重建后 fq 是否保持

- 当前依据：内核文档说明 `default_qdisc` 作用于新建 qdisc，多队列物理设备的 mq 叶子也会使用它（[N4][N4]）。fq 服务是开机执行一次的 oneshot，用于修正开机期间的状态（[D22][D22]）。平台生命周期覆盖两次真实重启，但没有覆盖 networkd 重启和链路重建（[平台说明](platform-support.md)）。
- 推断：没有 `[QDisc]` 配置时，systemd-networkd 重启不应改动 qdisc；设备重建时会按 `default_qdisc=fq` 创建 qdisc。以上未经运行验证，置信度中。
- 重新评估条件：verify 在网络服务重启、DHCP 续租或接口重建后报告非 fq；或者 Ubuntu 24.04 等使用 networkd 的平台需要更高的持久性支持等级。
- 最小验证：在现有平台虚拟机生命周期中，apply 后执行 `systemctl restart systemd-networkd`，然后检查 qdisc；另做一次接口 down/up 并复查。这需要单独立项，不修改产品。

### U1 / U2：补充既有候选

- U1（PPP/PPPoE）：判断 PPP 接口时用设备类型，不用名称或目录；钩子只处理触发它的那个接口；`/etc/ppp/ip-up.d` 存在只说明安装了 ppp，不说明接口由 pppd 管理。其他重新评估条件保持 [2026-09-11 原文](tcpfit-v0.5.8-research-2026-09-11.md#结论与重新评估条件)。
- U2（持久 HTB）：任何自动建议或应用流程，都必须把“取消”、“不完整”和“未发现上升”分成不同终态；负载低于已有整形值时，不得删除或覆盖已有配置。当前测量不自动应用配置，所以这条只约束未来设计。

## 5. 重新评估条件与剩余缺口

以下任一情况出现时，应重新判断“无需修改”：tcpfit 后续提交涉及 fq/mq 恢复、预算上界或证据完整性的新失败模式；本项目开始支持 ≥1 Gbps 测量或 PPP 拓扑；运行证据显示 fq 在网络服务事件后丢失。

未验证：上游 Release 中所有现场数字和测试结果；mawk 的 locale 行为；`netdev_budget_usecs` 的稳定分支回移版本；systemd-networkd 重启对 qdisc 的实际影响；本项目在高速单流下的表现。本轮没有运行任何第三方或产品脚本，因此证据最高只到源码实现和一手文档层级。

## 6. 已检查来源

源码链接固定到对应提交；在线文档检查日期为 2026-10-05。

[R1]: https://github.com/Kylin010/tcpfit/releases/tag/v0.5.9
[C1]: https://github.com/Kylin010/tcpfit/commit/a8ad4280e876bca066970ff97458003df30c7eae
[T1]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L802-L816
[T2]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3080-L3141
[T3]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3237-L3243
[T4]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2797
[T5]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2821
[T6]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L4374-L4393
[T7]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2958-L2996
[T8]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3014-L3033
[T9]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3265-L3278
[T10]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2085-L2327
[T11]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L465-L508
[T12]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1068-L1108
[T13]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1746-L1850
[T14]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/install.sh#L40-L64
[T15]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3471-L3485
[T16]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1022-L1050
[T17]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L539-L566
[T18]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L103-L114
[T19]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2463-L2560
[T20]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L441-L446
[D1]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/dvt-measure.py#L111-L131
[D2]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/dvt-measure.py#L383-L409
[D3]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/dvt-measure.py#L147
[D4]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/dvt-probe.sh#L103
[D5]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/debian-vps-tuning.sh#L816
[D6]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/dvt-measure.py#L754
[D7]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/dvt-measure.py#L262-L322
[D8]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/tools/profile-template.sh.in#L1126-L1142
[D9]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/tools/profile-template.sh.in#L1089-L1100
[D10]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/tools/profile-template.sh.in#L400-L404
[D11]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/tools/profile-template.sh.in#L1369-L1374
[D12]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/install.sh#L114-L123
[D13]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/dvt-measure.py#L200-L203
[D14]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/dvt-measure.py#L575-L577
[D15]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/tools/profile-template.sh.in#L170-L175
[D16]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/tools/measurement_phase.sh.in#L37-L59
[D17]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/dvt_htb_transaction.py#L190-L203
[D18]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/tools/profile-template.sh.in#L192-L254
[D19]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/dvt-probe.sh#L76-L83
[D20]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/dvt-traffic-budget.sh#L43-L46
[D21]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/tools/profile-template.sh.in#L398
[D22]: https://github.com/alieismy/debian-vps-tuning/blob/1c5e922c2fce916d5217bf6c238d6cd50a8c51b0/tools/profile-template.sh.in#L1334-L1365
[N1]: https://github.com/systemd/systemd/blob/main/man/systemd.network.xml
[N2]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=c180188ec02281126045414e90d08422a80f75b4
[N3]: https://github.com/torvalds/linux/blob/master/include/uapi/linux/if_arp.h
[N4]: https://docs.kernel.org/admin-guide/sysctl/net.html

- 上游：[v0.5.9 Release][R1]；[38fbf5a 提交](https://github.com/Kylin010/tcpfit/commit/38fbf5af30daf87735f2ffbc5e0905033ee2b86e)；源码锚点 T1–T20；早期 initcwnd 实测提交 [a8ad428][C1]。
- 本项目：源码锚点 D1–D22，固定到 `1c5e922`。
- 一手技术资料：[systemd.network 手册源文件][N1]（`[DHCPv4]` 中的 `InitialCongestionWindow=` 标注 v255，`[Route]` 中的同名项标注 v237）；[内核提交 c180188ec022][N2]；[if_arp.h][N3]；[内核 net sysctl 文档][N4]。

<a id="2026-10-31-reassessment"></a>
## 7. 2026-10-31 复核：当前工作区的吸收价值

性质：`rd-feasibility` 可行性判断，`rd-research` 提供技术证据；处于候选筛选阶段，未批准实现、联网试验或生产采用。本节补充当前结论，不改写前文历史状态。

### 7.1 结论与重新核实的基线

**可以选择性吸收，但当前默认保持运行代码，没有证据要求立即新增功能。** 若实际存在报告理解问题，可从现有证据派生扫描覆盖摘要；若出现单流欠驱动或明确的高速测量需求，可复用适用平台的 benchmark 做单流/多流对照，两项之间没有先后依赖。N2 网络事件验证继续保留触发条件，不扩大为当前必需门禁。源码机制判断置信度高；候选的潜在价值判断置信度中，实际易用性与业务性能收益尚未验证。本节已按[本轮自检](#2026-10-31-research-selfcheck)收窄执行条件、停止条件和方案比较。

- **上游未变化。** 本轮通过 GitHub 连接器查询默认分支、提交、Release、完整树及 Issue，并在临时目录检出固定源码。`main` 仍为 `38fbf5af30daf87735f2ffbc5e0905033ee2b86e`，最新 Release 为 2026-10-01（UTC）发布的 `v0.5.9`；主脚本 4484 行。`tcpfit.sh`、`install.sh` 的 SHA-256 与上文及仓库清单一致。没有把旧特性重新算作新增能力。[固定源码树](https://github.com/Kylin010/tcpfit/tree/38fbf5af30daf87735f2ffbc5e0905033ee2b86e)、[Release][R1]
- **本仓库基线已变化。** 对照的是 `master` / `46f0c4ee3eb243cbcc8e0cac54b3ca34175a931a` 加当前未提交修复，而不是前文的 `1c5e922`。此前本地修复与 2026-10-31 的 R1/R2/R4 保持原范围；这些本地运行修复及其原生验收不纳入本次独立解释工具发布。本节中“已有”表示已检查源码存在机制，不等于所有运行门禁已通过。
- **复核范围。** 重读 README、许可证、安装器、fleet 编排及示例，按流程检查主脚本的测量、扫描、调参、归档、临时/持久恢复、更新和向导；对照当前测量、解释器、benchmark、预算与 profile。未运行上游脚本、安装器、SSH、iperf3 或任何调优操作。
- **成熟度限制。** 固定树共 9 个文件，没有公开测试套件或 CI 配置，`results/` 只有 `.gitkeep`；Release 的回归、模拟和实机结果属于维护者报告，本轮无法从该树复现。README 明确多机编排未在真实环境验证，不能把 Release 的非预发行标志理解为适合本项目生产接管。[README](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/README.md#L94-L111)

### 7.2 哪些内容仍有增量价值

| 内容 | 本轮核实与新增价值 | 建议及进入条件 |
|---|---|---|
| N1：单流与多流对照 | tcpfit 在单流可疑时补 8 流，并在 verify 中顺序跑 1/4 流；能提示单流限制与聚合表现不同。DVT 的独立 `measure` 与 `probe` 固定单流，但底层 benchmark **已支持 1–4 流**，并在显式强制限速时将总 cap 等分到每流。缺口是受控配对流程与解释，不是全仓缺少多流能力 | 仅在相应症状或测量需求成立时优先核查。平台适用、预算与证据条件满足后，复用现有 benchmark 做同端点、同方向、同总 cap 的 1/4 流交替重复对照；必须显式启用强制 cap，不能直接复制 8 流不限速，也不需要先新增入口。若现有报告已足以解释问题，则不改代码 |
| 扫描覆盖范围摘要 | tcpfit 明确区分请求上界、有效覆盖和不完整扫描。DVT 已保存 `plan`、`samples`、`eligible`、`tested_rates`、`stop_reason`，分析器会阻断不完整证据；解释器还区分高档未覆盖与证据不完整。新增价值只在减少读报告的理解成本 | 适合作为下次文档/解释工具改动的小项：派生展示“计划范围、有效档位、缺失档位、停止原因”。中间有缺口时，不能只用最高有效档暗示连续覆盖；不增加另一份权威状态、不改变判据或产生整形值 |
| N2：网络事件后的 fq 保持性 | tcpfit 的 initcwnd 持久化问题说明“重启通过”与“网络管理器重启、链路事件通过”是不同证据。它不能直接证明 DVT 的 fq 有缺陷 | 仅在 fq 经过网络事件后发生漂移，或新平台明确要求更高持久性覆盖时进入隔离客体验证。接口 down/up 不等于接口销毁重建，应按实际事件分别验证；本轮不安装 PPP/networkd hooks |
| 故障经验与无效结果的表达 | 原子写入、非交互拒绝、弱样本不覆盖旧配置、临时 qdisc 恢复、能力探测均有借鉴价值；DVT 已有相应控制或更窄的契约 | 作为未来具体缺陷的反例线索；先映射已有测试，仅在覆盖缺口影响本项目时增加定向用例。不新增通用框架或宽泛矩阵 |

上游依据：[单流/8 流分支](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2928-L2996)、[verify 配对调用](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3350-L3362)、[覆盖检查][T9]。本仓库依据：[测量计划与分析](../dvt-measure.py)、[离线解释器](../tools/explain_measurement.py)、[benchmark 实现](../tools/profile-template.sh.in)、[probe](../dvt-probe.sh)。关键定位分别为 `dvt-measure.py:117–131,283–322,722–730`、`tools/explain_measurement.py:71–91,106–132`、`tools/profile-template.sh.in:2982–2985,3021–3026,3129–3131`。

N1 需要保留的反证：多流改善可能来自连接窗口、CPU、服务端并行能力、不同路径或时间波动；不能直接确诊单一根因，也不能排除按流限速。ESnet 文档说明 `-b` 对每条并行流分别生效，且较新 iperf3 的每流线程可改变 CPU 限制下的表现。因此应记录两端版本及资源状态，并确保总 cap 没有随着流数扩大；同 cap 达标也不代表测出了更高容量。[iperf3 官方说明](https://software.es.net/iperf/invoking.html)

### 7.3 不宜直接吸收的部分

1. **“重传比例 → policer → 自动整形”的推断链。** `loss_pct` 用重传数除以吞吐、指定时长及固定 MSS 1448 推算的包数，不是实际丢包概率；README 的低重传即没有限速器、高重传即存在限速器，及部分代码输出中的强因果判断，都超出该观测的辨识能力。即使确有重传，也不能定位丢弃发生在服务商限速器。单流/多流、近端控制、补采等可以增加线索，不能完成排他性诊断。DVT 应保留 `retransmits/GiB`、原始 JSON、有效窗口、资源/路径检查和 `policer_identified=false`；其经验阈值本身也不因此成为可靠的因果判据。[README](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/README.md#L127-L139)、[计算与阈值](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2660-L2675)、[现有校准设计](knee-calibration-design.md)
2. **全量参数集合、固定余量与 initcwnd=32。** 源码默认 RTT 为 150 ms，可通过 `--rtt` 覆盖；它不是全部输入均来自实测。基础调优 heredoc 实际有 31 项 sysctl 赋值，README 写 30；33 项快照清单额外保留历史 `netdev_budget_usecs` 和可选 `vm.swappiness`，这两个数量不能混用。`tcp_adv_win_scale=1` 仍在配置中，而内核文档标为 Linux 6.6 起废弃。以上支持逐参数核实，不支持把更多参数或 `2×BDP+2MiB` 公式视为本项目性能更优的证据。保持现有 17 项、资源上限和代表路径约束；上游的角色默认缓冲、固定 margin、burst 公式亦需独立收益证据。[RTT 与输入](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1695-L1725)、[参数正文](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1753-L1802)、[快照集合](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L834-L868)、[内核文档](https://docs.kernel.org/networking/ip-sysctl.html#tcp-variables)
3. **估算后确认替代预算账本。** v0.5.9 的精扫上限和大流量确认有实际工程意义，但确认不等于累计硬预算；部分不限速基线已在确认前运行，重试与补采也需要预算。DVT 已对各次尝试预留并在余额不足时停止，应继续完善既有机制，而非改用 50 GB 确认线。预算单位仍是 payload，不能承诺它等于服务商账单流量或网络层绝对上限。[流量估算与确认][T2]、[本仓库预算说明](automatic-measurement.md)
4. **恢复、安装、遥测与多机编排实现。** tcpfit 临时 qdisc 快照主要保存 root kind 和 mq 首个叶 kind，不保留完整参数拓扑；不能代替本仓库受限拓扑、所有权和恢复等价检查。归档恢复还同时管理 sysctl、路由窗口及持久服务，明显扩大当前受管面。独立安装器下载可变 `main`，更新的清单不可用时降级为版本字符串检查，遥测默认开启；这些选择与本项目固定资产和本地证据边界不一致。fleet 的非 dry-run agent 操作先推送文件，因此 `detect/status` 也不能直接拿来作为零写入的批量检查入口。保留其思路参考，不直接复用实现。[临时 qdisc 保存/恢复](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2463-L2531)、[安装器](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/install.sh)、[更新校验](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3471-L3487)、[遥测](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1022-L1054)、[fleet 操作入口](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/orchestrator/fleet.py#L247-L260)

MIT 许可证允许在保留其要求的版权和许可声明条件下复用代码；本轮没有复制上游代码进入产品。许可不是主要障碍，维护、验证和恢复契约适配才是主要成本。没有足够证据量化工期、流量节约或性能提升。[固定 LICENSE](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/LICENSE)

证据对称性：固定目标 RTT 本身不是缺陷。上游说明它在避免 anycast、ICMP 失败及单一路径低 RTT 导致缓冲过小之间作了取舍；本仓库默认目标 RTT 也固定为 200 ms。上述数值与资源系数都属于工程策略，不能仅凭源码或较窄的参数集合证明最优。上游归一化重传仍可提供启发式筛选线索；本报告否定的是准确丢包率和排他性因果归因，不断言其方法在所有场景都无效。[上游 RTT 取舍](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L628-L653)、[本仓库模板](../tools/profile-template.sh.in)

### 7.4 候选路线、最小下一步与停止条件

| 路线 | 收益与成本 | 判断 |
|---|---|---|
| A：保持当前能力，仅保留研究结论 | 无新增运行风险；复杂报告继续需要人工解释 | 当前没有新运行症状时完全可接受，不构成遗漏 |
| B：按需求选择解释呈现或配对测量 | 复用已有数据和 benchmark，新增范围较小；配对仍需预算、版本记录与干扰控制 | 条件候选；两项可独立推进，没有统一排序。先确认具体问题，实际收益成立后再决定是否产品化 |
| C：引入 tcpfit 核心或整套运行方式 | 获得自动调参、归档、多种持久化；与 DVT 同机并管相同状态时才产生第二配置所有者。受控替换需要评估迁移、恢复与验证成本；隔离使用不产生同机所有权冲突 | 当前不推荐整体替换；尚无足够需求与收益证据支持其成本。不能以并管风险否定隔离研究或纯函数、经验的选择性复用 |

若后续批准 B，覆盖摘要可先用已有完整/不完整报告离线评估；N1 则按其触发条件独立决定是否试验。复用 benchmark 只适用于匹配的 profile 操作系统、架构和依赖；直接 benchmark 不要求先 apply 成为 VERIFIED（`tools/profile-template.sh.in:275–285,2962–2967,3071–3084,3303–3304`），不能为做研究先改系统配置。配对必须显式设置 `BENCHMARK_RATE_CAP_MBPS` 与 `BENCHMARK_ENFORCE_RATE_CAP=1`：只填 cap 默认用于估算，不会限速。还需使用合法共享账本、分别预留各次调用、保留持久原始证据，并固定字面 IP、端口、协议族、方向、时长、omit 和总 cap；核对实际连接及出口路径一致。benchmark 的 PASS 只证明采集与哈希链完整，比较还必须检查各方向的有效测量窗口，见[既有 benchmark 契约](advanced-measurement.md#研究专用-benchmark)。旧 benchmark 按默认路由发现接口，不能假定它已有独立 `measure` 的实际端点路由复核能力（`tools/profile-template.sh.in:2952,3021–3026,3040,3067,3096–3105,3131`）。

离线报告分析不依赖迁移锁或旧 TcpQuality 的原生验收。实际试验仅要求所选版本、测量路径及环境相关的必要门禁和授权；若用未提交候选，必须核清相关预算、超时与证据路径的验证状态，不能用历史通过记录替代。R1/R2/R4 自身的验收要求保持，但不统一绑定到所有研究活动，也不因本节自动启动公网试验。稳定可复现的差异若能改变诊断决策，才值得把配对调度纳入独立测量工具；单次“跑得更快”不够。

停止或维持现状的条件：没有实际使用需求；现有报告已足够；预算、恢复或数据完整性不满足；无法控制资源/路径变化，或差异不能跨交替样本复现。若单流与多流都未达到约定的有效负载，结果不足以判断该 cap 附近的行为，不应继续扩流量来强求结论；若单流欠驱动、四流在同总 cap 下稳定达标，这正是可记录的配对差异，不能因此一概判为失败。后者仍不确认根因或更高容量。任何不充分结果均不得自动调大 cap、增加并发、修改 sysctl 或应用永久 HTB。

### 7.5 自检与证据边界

- N1/N2 为既有条件候选，覆盖摘要为此前已提出的可选展示改进；没有新增产品要求，也没有把公共端点选择、独立测量、细扫、原子写入重复包装成新功能。
- 修正了容易误读的范围：“独立测量固定单流”不等于“全仓不支持多流”；独立测量的实际路由复核能力不能直接算作旧 benchmark 已有能力；源码中有控制不等于当前未提交候选已完成 Linux 原生验收；接口 down/up 不等于设备重建。
- README 的参数数量偏差是次要文档问题，不据此认定整套工具无效。上游对无效样本、拒绝大流量、保护旧整形和失败退出确有修复，不能只列风险而忽略这些进展。
- [Issue #13](https://github.com/Kylin010/tcpfit/issues/13) 的无安装/无写入 dry-run 请求与 [Issue #12](https://github.com/Kylin010/tcpfit/issues/12) 的 swap 提示报告仍作为用户需求/缺陷线索，未做运行复现。现有 preflight、plan-only 也不能被夸成完整的逐项变更预览；当前没有为此新增功能的依据。
- 未验证上游实机收益、全量恢复效果、公开节点当前容量、N1 配对收益或 N2 事件持久性。本轮交付仅更新本研究与项目备忘；源码摘要、范围复核和文档检查证据保留在 `.tmp/local/tcpfit-study-20261031/`，不属于安装或发布资产。

<a id="2026-10-31-research-selfcheck"></a>
### 7.6 2026-10-31 研究结论与吸收建议自检

评审对象为本节上一轮文本及聊天结论，使用 `rd-review` 研究模式，兼查可行性决策质量。当前 HEAD、上游提交/Release 与前轮一致；正式文件以自检开始时的 144 文件摘要为基线。以下是研究建议的问题，不是新增的产品缺陷。研究编写者已于本轮 2026-10-31 完成有边界修正并回到源码复核。

| 编号/级别 | 原位置与评审轴 | 问题、证据与影响 | 修正与分级理由 |
|---|---|---|---|
| TS-1 / Minor | §7.2 N1、§7.4 配对方案；证据/可执行性 | “同总 cap”未写清实际启用条件，且未限定 benchmark 的平台适用性。模板默认 `BENCHMARK_ENFORCE_RATE_CAP=0`，仅填 cap 不发送 bitrate 参数；它也受 profile OS/架构检查约束。原文已有强制 cap 原则，但进入试验前还需明确入口条件 | 补充 cap 与 enforce 同时设置、适用平台、账本、持久证据及有效测量窗口；保留其无需预先 apply/VERIFIED 的事实。当前只是研究建议，未提供错误执行命令、也未实施为缺陷，故为 Minor；不要求修改已有实现 |
| TS-2 / Minor | §7.4 停止条件；内在论证 | “配对后仍欠驱动”未区分单流与多流。单流欠驱动而四流达标恰是 N1 要观察的结果，原措辞可能误拒有效对照；也可合理理解为整组仍欠驱动 | 消除歧义，区分两者均欠驱动与单流欠驱动/多流达标；只记录同 cap 下的差异，不确诊根因。未实现为错误判据，且相邻段已有因果限制，故为 Minor |
| TS-3 / Minor | §7.1、§7.4 下一步顺序；范围/可行性 | 先完成当前修复原生验证、先摘要再 N1 的统一顺序缺少必然依赖。离线报告无需迁移或 TcpQuality 原生门禁；benchmark 入口也不调用这两条路径 | 移除统一先后关系，只核对被选测量路径的适用门禁；默认保持代码，按真实需求各自触发。当前没有执行或新增门禁落地，故为 Minor；不豁免原修复自身验收 |
| TS-4 / Minor | §7.4 路线 C；比较公平性 | “同时引入第二配置所有者”把同机并管的风险泛化为整体采用的必然后果。隔离使用和受控替换并不必然并管 | 分开说明同机并管冲突与替换的迁移/恢复成本，并保留隔离研究、纯函数与经验复用路线。原结论还有独立成本依据，故为 Minor，不推翻当前不整体替换的判断 |

补充反证而非新增问题：默认 RTT=150、31/30 项数量差异、废弃参数及未公开测试，均不能单独证明 tcpfit 无效；本仓库默认 RTT=200、经验阈值和恢复实现也不能仅凭源码证明最优或生产可靠。已在 §7.3 补充对称说明。没有发现必须立即新增功能、拓展参数、引入 PPP/持久 HTB、重构测量框架或扩大测试矩阵的遗漏。

**自检结论：上述修正后，通过作为候选筛选的研究输入。** 当前默认保持运行代码；覆盖摘要、N1 和 N2 分别保留其需求触发条件，没有统一实施排序或新增强制门禁。未作上游/本仓库运行与性能验收，也不构成实施或生产采用批准。证据、修正前文本和最终范围核对保留在 `.tmp/local/tcpfit-selfcheck-20261031/`。
