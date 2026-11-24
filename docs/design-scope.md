# 设计范围

> 版本边界：本文件下述固定资源档为已发布 rc.19 的兼容设计。0.2.0-rc.1 的新增平台/自适应策略与验收状态由[跨平台支持](platform-support.md)补充；原事务、所有权和恢复不变量仍适用。

## 目标

为 Debian 12/13 amd64 小型 VPS 提供性能优先、稳定性受约束且可验证、可回滚的主机网络配置。资源范围严格限定为 1C512MB、1C1GB、1C2GB 和 2C2GB。主要验收负载是原生 systemd 部署的 3X-UI v3.4.2、Xray-core v26.6.27、VLESS + REALITY + TCP，默认 200 Mbps、目标 RTT 200 ms、通常 3–5 人且最多 10 人并发。

## 信任边界

脚本信任：

- root 所有且权限受控的项目状态目录；
- `/etc/os-release`、`/proc`、`sysctl`、`ip`、`tc`、systemd 和内核返回的本机状态；
- 用户明确传入且通过白名单和范围校验的环境变量。

脚本不信任：

- 同名但没有管理标记、状态记录和匹配哈希的文件；
- 自定义 swap 路径；
- 复杂或不可重建的 qdisc；
- 其他调优脚本写入的 sysctl；
- 代理面板数据库、生成的 JSON 和用户凭据。

## 配置归属

唯一命名空间为 `proxy-vps`。状态文件是脚本所有权、资源档位、原始 qdisc、swap 和 managed file 哈希的唯一事实来源。状态文件使用 JSON，不通过 `source` 或 `eval` 解释。

sysctl 配置归属按规范路径去重：项目自己的 `/etc/sysctl.d/90-proxy-vps.conf` 及指向它的符号链接不构成冲突，外部文件及其别名只报告一次。唯一例外是 root 所有的普通 `/etc/sysctl.conf` 中各自唯一且值严格为 `fq`/`bbr` 的厂商基线：`preflight` 只读报告可迁移，`apply` 在状态事务内完整备份并转移所有权，`rollback` 恢复原文件。其他外部文件即使写入相同值，仍属于第二配置所有者；`preflight`/`apply` 阻断，已安装状态的 `verify` 返回失败，`diagnose` 只读报告。操作者可停在通过的 `preflight` 并保留厂商配置，但不得在未接管时把项目描述为已安装或已验证。

## 总控入口与分发边界

`debian-vps-tuning.sh` 是选择器和调用器，不是另一份调优实现。它只允许 Debian 12/13、amd64 下的四个资源档：1C + 384–767 MiB、1C + 768–1535 MiB、1C + 1536–3072 MiB、2C + 1536–3072 MiB。底层共有六个操作系统/内存 profile；1C2GB 和 2C2GB 共用兼容 ID `debian12-1c2g`/`debian13-1c2g`，不建立重复实现或迁移已有状态。2C512MB、2C1GB、3 vCPU 以上及边界外内存拒绝执行。存在可解析状态时，检测档位必须与 `.profile.id` 一致，否则阻断。

`experiments/htb-aggregate` 中的参考筛查和候选速率扫描是独立、研究专用的实验面，不进入六份 profile 的持久配置，也不属于业务 VPS、版本迁移或发布默认门禁。只有需要验证聚合出口整形机制、使用独立高额度测试机且已批准完整流量预算时才进入。总控菜单只通过 `dvt-htb.sh` 暴露受限包装层：只读 preflight、10 秒自动恢复 smoke、status/stop，以及需要显式 endpoint、证据目录和阶段确认的 reference/sweep；不存在持久化 HTB 安装动作。计划生成器只输出 JSON；runner 必须由 root 使用同一固定 Release 中已校验的 profile、HTB v0.4.0 工具和 analyzer，且只对 200 Mbps 的 rc.17 schema 4 `VERIFIED` Debian 13 1C1G/1C2G 基线执行上传测试。candidate sweep 还必须校验 reference 的 `COMPLETED`、`SHA256SUMS`、`REVIEW_REQUIRED` 和有效窗口，并要求 `--ack-reference-reviewed`，才能生成候选计划。所有阶段都复用 HTB start/ACTIVE/stop/恢复契约，只改变 class rate/ceil，不创建持久化 qdisc。benchmark phase summary 使用 schema 3 并分别保存 HTB root/FQ leaf totals；分析器只形成描述性 shortlist，旧摘要、缺失 HTB→FQ 叶子、任一 root/leaf drop/requeue 或测量窗口异常都输出 `REVIEW_BLOCKED` 且不排名，不自动授权生产速率或持久化整形。

总控入口支持交互安全引导和显式 action。带宽为 `guided`、`preflight`、`apply` 选择，并可通过 `reconfigure --port` 修改，默认 200 Mbps，范围是 1–10000 的任意整数；`apply` 的选择优先级是 `--port`、`PORT_SPEED_MBPS`、已安装状态值、交互选择/默认值，因而无显式值的重复 `apply` 复用已安装带宽；`verify`、`status`、`diagnose`、`probe`、`benchmark`、`htb`、`update`、`rollback` 不通过 `--port` 重写现有状态。安全引导先运行 preflight，只有交互终端再次明确确认才调用 apply。`diagnose` 只读取本机状态并做 1–60 秒增量采样，覆盖 TCP、softnet、整机 CPU、接口/ethtool、qdisc、policy rules 和代理进程资源，不生成流量或输出进程命令行；只有检测到自定义 IPv4/IPv6 rule 时才展开对应地址族的全部路由表。`benchmark` 不修改系统配置，但只有用户显式给出 `BENCHMARK_HOST` 且已安装 iperf3 时才产生直连 TCP 测试流量；它允许固定预热、IPv4/IPv6、方向和 run ID，并按方向分离内核计数，仍不代表代理业务测试。每个方向在 `setsid` 隔离的进程组中由 GNU `timeout` 管理，默认硬上限为有效时间、omit 和 15 秒连接/清理余量之和；超时或父进程信号会 TERM→KILL 并回收该组，持久证据仍保留 `INCOMPLETE`。分方向摘要校验 sender/receiver 的实际窗口、bytes/seconds/bitrate 算术和跨端字节关系；采集完整仍可能因窗口异常而不可用于分析。测试前的 payload 流量估算只接受显式 `BENCHMARK_RATE_CAP_MBPS` 或合法管理状态中的端口上限，不使用 profile 默认值猜测；rc.5 候选要求启用 `BENCHMARK_ENFORCE_RATE_CAP=1`（默认值），并将解析出的 cap 实际传入 `iperf3 --bitrate`。由于 iperf3 对并行流逐流应用该值，强制模式把总 cap 等分为每流整数 bps，并把 scope 与每流值写入元数据。

`dvt probe` 是 advisory-only 编排层：必须显式指定用户控制或获授权的 endpoint，使用 100–1000 Mbps 显式 cap 或 `VERIFIED` 状态中的端口上限，固定单流并强制 `BENCHMARK_ENFORCE_RATE_CAP=1`，在流量预算门禁内重复 2–5 个样本。每个样本复用 profile 的原始 JSON、窗口验证、精确 bytes、重传/GiB、事务终态和 SHA-256；顶层只聚合中位数并输出 `REVIEW_REQUIRED`/`REVIEW_BLOCKED`。它不把测试吞吐反写为服务商端口值，不变更 qdisc/sysctl，不授权永久 HTB，也不宣称测得 3X-UI/Xray/客户端业务路径。普通菜单仍不提供 rc.2 专用 `recover`。

`install.sh` 是固定 Release 的 bootstrap。外层命令必须先以文档固定 SHA-256 校验 installer；installer 再以内置固定摘要校验 `SHA256SUMS`，并逐项验证全部运行资产后安装到版本化 root-owned 目录，通过原子 `current` 符号链接和 `/usr/local/bin/dvt` 提供短命令。安装不等于 apply，不自动修改系统网络或运行 probe。installer 不在自身清单中以避免自引用循环，其摘要由 Release 说明和 README 固定；已存在版本目录内容不一致时拒绝覆盖。

本地模式要求总控脚本、目标 profile 和 `SHA256SUMS` 位于同一目录、来自同一 Release，并在调用前核对唯一清单条目。不同版本必须使用不同目录；总控与同目录清单不匹配时明确提示可能混用 Release，并保持完整性失败，不自动转入远程模式。远程模式只允许 HTTPS，从总控脚本内固定的 GitHub Release tag 下载 `SHA256SUMS` 和目标 profile；HTTP 错误、重定向协议降级、超时、空文件、重复清单条目或哈希不匹配均阻断。下载失败不得回退到可变分支、latest、第三方镜像或另一个 profile。

总控脚本不直接写 sysctl、systemd、qdisc、swap、journald 或状态文件，不捕获后伪造底层成功，不改变底层退出码。`update` 也是只读检查：校验当前 profile 和目标 Release 后，只调用当前 profile 的 `verify` 以及目标总控的 `UPDATE_PREFLIGHT=1 preflight`，复用状态中的端口带宽并输出人工迁移材料；它不得调用 rollback、purge、apply 或 reboot。跨版本“清旧装新”必须由旧版固定 Release 根据旧状态执行受管 rollback/purge，完成恢复检查和重启后再运行最新版；新版不得作为旧状态的通用卸载器。状态不可恢复而 VPS 可重建时，可在已验证业务备份和控制台后选择干净重装。目标 profile 的 update-preflight 只允许完整且归属校验通过的 `VERIFIED/APPLIED` 状态，未完成或保留 swap 的状态继续阻断。自动发现只在同一 `major.minor` 发布线内选择；rc 通道允许更高 rc 或稳定版，稳定通道排除 prerelease，跨线或主动选择 prerelease 必须显式 `--target`。SHA-256 证明下载内容与同一发布清单一致，不单独证明发布者身份；Release tag、资产不可变性、GitHub API 返回和发布来源仍属于用户信任边界。

重复 `apply` 的无写入幂等只适用于状态 `script_version` 与当前脚本一致且端口、RTT、缓冲完全相同的 `VERIFIED` 状态。旧版本状态必须由对应版本的 profile 核验和恢复，新脚本不是通用旧状态卸载器；跨版本 apply 必须先通过来源恢复与迁移门禁。历史 TCP 原值缺失的停止条件见[旧状态与迁移](platform-support.md#旧状态与迁移)。

## CPU 调优边界

CPU 数只参与资源档位选择和底层预检，不改变 BBR、fq、TCP 缓冲、backlog、swap 或 journald 参数。首发版本不配置 RPS/RFS/XPS、IRQ affinity、CPU affinity、busy polling 或 `GOMAXPROCS`；这些行为依赖虚拟网卡队列、软中断分布和实测瓶颈，不由 2 vCPU 这一条件单独触发。`diagnose` 可以只读输出 CPU user/system/softirq/steal 增量、队列数量、RPS/XPS mask 和与接口匹配的中断证据，但不得写入对应 sysfs/procfs 控制项；单个非零计数不构成根因结论。

## 资源参数边界

自动 socket 上限先按 `端口带宽 × 目标 RTT` 计算 BDP，再按 512M/1G/2G profile 分别乘以 `1/1`、`5/4`、`3/2`，向上选择 16/32/64 MiB，并限制为相同资源档的 16/32/64 MiB 上限。默认 200 ms 下，100/200/500/1000 Mbps 分别得到：512M 为 16/16/16/16 MiB（1000 Mbps 截断警告），1G 为 16/16/16/32 MiB，2G 为 16/16/32/64 MiB。显式 `BUF_MAX` 不得越过对应 profile 上限；自动目标因资源内存预算被截断时必须报告实际分数系数。该上限允许 Linux TCP 自动调优按连接增长，不是预分配或每连接固定占用。

## 应用 socket 选项边界

`net.ipv4.tcp_fastopen=3` 只启用 Linux TFO 客户端和服务端基础能力，不等于每个 listener 都启用了 `TCP_FASTOPEN`。Xray 生成配置没有 `streamSettings.sockopt.tcpFastOpen` 字段时，脚本只能报告“未显式配置”，不得推断实际 listener 已启用或已禁用。脚本不修改 3X-UI 数据库或生成的 `/usr/local/x-ui/bin/config.json`；用户只能通过受支持的面板配置入口调整并重新验证。

主机 `tcp_keepalive_time/intvl/probes` 只约束启用了 `SO_KEEPALIVE` 且未被应用覆盖的 socket。Xray 入站默认 Keep-Alive 行为和出站应用默认值属于应用配置边界，不能由主机 sysctl 的验证结果替代。`verify`/`diagnose` 只读取已知 Xray 生成文件中 `tcpFastOpen`、`tcpKeepAliveIdle` 和 `tcpKeepAliveInterval` 的值，不输出其他代理配置或凭据。

journald 的 `SystemMaxUse`/`RuntimeMaxUse`/`SystemKeepFree` 分别为：512M 档 `64M/16M/256M`，1G 档 `128M/32M/512M`，2G 档 `128M/64M/1G`。swap 默认均为 1 GiB；512M/1G 上限 2 GiB，2G 上限 4 GiB；创建后必须分别保留至少 256/512/1024 MiB 可用磁盘。所有档位保持 `vm.swappiness=20`。

## 事务状态

正常路径：

```text
UNMANAGED → PREPARED → APPLYING → APPLIED → VERIFIED
```

`PREPARED` 只表示原始状态已提交；在首个系统写入前必须进入 `APPLYING`。失败路径保留 `DEGRADED` 状态。回滚失败时不得删除诊断状态或所有权证据；只有项目文件不存在、swap 未被脚本接管、qdisc 与快照语义一致且原始 sysctl 已恢复时，才能把残留事务判定为已经恢复并清理状态。普通回滚保留脚本创建的 swap；显式 purge 才能在 `swapoff` 成功后删除。

状态持久化不依赖 `set -e` 或 jq 1.6 对空输入的退出码。每次创建或转换先写同目录临时文件；只有生产命令成功、文件非空、输入恰好为一个 JSON 对象且完整 schema 校验通过，才以原子 rename 替换目标。`state_set_phase`、managed file 哈希和 swap 所有权不得自行实现另一套写入路径。

早期 rc.2 空状态不包含原始 sysctl，因此不能按普通 rollback 推断或重建。显式 `recover` 只允许在用户确认该状态产生于首次系统写入前，且项目文件、脚本 swap、fstab、fq helper 均不存在、当前 qdisc 与快照一致时，将整个状态目录改名隔离；不自动删除证据，也不处理一般损坏状态。

## qdisc 边界

只支持：

- 根 `fq`；
- 根 `fq_codel`；
- 仅含默认参数且没有附加层次的常规根 `pfifo_fast`；
- 根 `noqueue`，只警告；
- 根 `mq` 且叶子为 `fq`/`fq_codel`。

其他拓扑在第一次系统写入前阻断。IPv4 和 IPv6 默认路由网卡分别发现并去重；策略路由表不属于该发现范围。`diagnose` 和 benchmark 会只读显示 policy rules，并在发现自定义规则时保存对应地址族的全部路由表和警告，但该证据不会把复杂策略路由提升为受支持的 apply 拓扑。

已有根 `fq` 和 `mq` 下已有 `fq` 叶子视为不需要修改，应用和回滚均保留其现有参数。只有已保存完整可恢复参数的 `fq_codel` 根/叶子或常规根 `pfifo_fast` 会被切换并在回滚时重建。HTB、TBF、CAKE、自定义 `pfifo_fast` 或其他未知层次继续阻断。

qdisc 状态以 `tc -j` 数值为准，但恢复命令按 `tc` 输入语法生成：`limit` 使用纯数据包数量，`memory_limit` 使用原始字节数，不复用文本显示后缀。语义比较忽略运行时 `refcnt` 和 JSON 字段顺序；`target`、`interval`、`ce_threshold` 仅允许 ±1 微秒量化差异。原快照 `handle 0:` 代表未指定，允许内核为受支持的 classless qdisc 自动分配 handle；显式非零 handle、kind、parent、root 及其他 options 仍严格比较。rollback 恢复命令完成后必须再次读取并比较实际 qdisc，只有通过后置验证才允许删除状态和快照。

## swap 文件系统边界

自动 swap 文件只允许在 `ext2`、`ext3`、`ext4` 和 `xfs` 根文件系统上创建。Btrfs、ZFS、overlay、NFS、FUSE 以及未验证类型会跳过自动创建，不影响 sysctl、qdisc 和 journald 的应用。XFS 仍需由目标 VPS 验证 `fallocate → swapon` 路径；失败时脚本使用 `dd` 重试并纳入事务回滚。

## 3X-UI 边界

脚本预先托管 `/etc/systemd/system/x-ui.service.d/90-proxy-vps.conf`，设置 `LimitNOFILE=65536`，因此先调优、后安装 3X-UI 是正常路径。未安装时 verify 报告待安装但不警告；安装后严格验证 systemd 配置、主进程和直接子进程的运行时限制。脚本不主动重启代理服务；若 apply 时 `x-ui.service` 已在运行，非严格验证只警告旧运行时限制，用户重启服务或主机后再执行严格验证。脚本不安装、升级 3X-UI，只读解析默认路径的 Xray 生成 JSON 并输出指定 TFO/keepalive 字段，活动配置来源仍需核验。数据库和凭据不纳入诊断输出。

## 防火墙边界

UFW 只读。脚本不推断 SSH、面板、订阅和 VLESS 入站端口，也不启用 forwarding、NAT 或 TProxy。
