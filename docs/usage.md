# 安装、持久配置与日常操作

适用版本：`v0.2.0-rc.4` 预发行版，固定资产已完成公开下载回验。本页承接 [README](../README.md) 的详细操作；独立公共测量见 [自动测量指南](automatic-measurement.md)，旧测量接口见 [高级测量](advanced-measurement.md)。系统名称、资源、架构与实际能力要求见 [平台支持](platform-support.md)。

## 执行前准备

安装器和持久配置命令在 VPS 的 root shell 中执行，`id -u` 应输出 `0`。独立 `diagnose` 可普通权限运行；`measure` 的实际执行需要 root 所有的预算账本。首次修改主机前保存基线，确认控制台/救援入口、备份和维护窗口。已有受管状态先读 [迁移指南](migration.md)，不能用新版本覆盖旧状态。

安装器需要 Bash、curl、CA 证书、awk 和 GNU coreutils 等标准工具；持久配置还需要 systemd、iproute2、procps、kmod、util-linux 和 jq。程序会检查实际命令与内核能力，不自动安装依赖。Debian/Ubuntu 最小镜像可在检查 APT 计划后安装：

```bash
apt update
apt install ca-certificates curl jq iproute2 procps kmod util-linux
```

若要使用独立 `diagnose`、`measure` 或 `htb-sweep`，还需 Python 3.9+；主动测量另需 iperf3 等 [依赖](automatic-measurement.md#能做什么)。限速测试建议 iperf3 3.18 或包含等效修复的版本，APT 提供的版本未必满足此建议。不要把编辑器、UFW、系统全量升级或包清理当作所有功能的必需步骤。

## 安装与文件布局

首次安装使用 [首页的固定版本与摘要](../README.md#安装)。安装器先核对内置固定的 `SHA256SUMS` 摘要，再核对全部运行资产，安装到 `/usr/local/lib/debian-vps-tuning/0.2.0-rc.4`，原子更新 `current`，创建 `/usr/local/bin/dvt`。已有同版本目录只有在全部文件重新校验通过时才复用，内容不一致时拒绝覆盖。

`--no-launch` 只安装；省略该参数且有交互终端时，安装完成后打开 `dvt` 菜单。安装本身不执行 apply、测速或 managed state 迁移。下载不回退到 `main`、`master`、`latest`、HTTP 或第三方镜像。

## 持久配置与验证

以下为全新、无旧受管状态的主机示例，200 应替换为服务商套餐带宽上限。每步成功后才进入下一步。

```bash
dvt preflight --port 200
```

预检通过并确认写入范围后：

```bash
dvt apply --port 200
```

应用成功后按提示重启，在重新登录后验证：

```bash
reboot
```

```bash
dvt verify
dvt status
```

`verify` 不重新 apply，也无需重填状态中保存的带宽。保存完整输出并检查退出码。交互用户也可运行 `dvt`，选择安全引导；引导先 preflight，再询问是否 apply，非交互环境必须显式指定 action。

### 厂商已预装 BBR/fq 时的处理

BBR + 根 `fq` 是本项目的目标状态，不代表必须覆盖厂商配置。运行时值也不能证明持久化来源
和配置所有权。首次安装前先运行 `preflight`，然后按其结果处理：

| 基线 | 默认处理 |
|---|---|
| 没有外部冲突 | 由项目写入并成为唯一所有者 |
| `/etc/sysctl.conf` 中各有一条、值严格为 `bbr`/`fq`、root 所有的普通文件 | 可由项目事务化备份并接管；也可停在 `preflight`，保持厂商配置 |
| `/etc/sysctl.d/*.conf`、重复定义、符号链接、非 root 文件、值不同或未知组合调优 | `preflight` 阻断；不得自动合并或覆盖 |
| 已存在其他项目版本的受管状态 | 按跨版本迁移处理，不按厂商基线处理 |

如果只需要 BBR/fq，且厂商已经单一、可靠地持久化，可以不安装本项目。只有需要项目管理
buffer、swap、journald、NOFILE、状态验证和回滚时，才应接管所有权。不得让厂商文件和项目
文件长期共同定义同一 sysctl key；厂商品牌不构成 profile 维度。

### 预检、独立 profile 与代理服务验证

以下独立脚本示例从完整且已校验的同版本 bundle 根目录执行；文件名须匹配目标系统与资源。安装后的日常操作优先使用 `dvt`。

#### 1. 只读预检

```bash
env PORT_SPEED_MBPS=200 \
  bash ./debian13-1c1g-vps-tuning.sh preflight
```

`preflight` 不写配置、不加载模块、不创建 swap、不停止服务。遇到以下情况会阻断：

- 操作系统、架构、CPU 或内存档位不匹配；
- 缺少必要命令；
- BBR/fq 不可用；
- 没有常规默认路由；
- 同名管理文件的所有权不明；
- `/etc/sysctl.conf` 或 `/etc/sysctl.d` 存在不能安全迁移的重复键；仅 `/etc/sysctl.conf` 中唯一且值严格为 `net.core.default_qdisc=fq` 或 `net.ipv4.tcp_congestion_control=bbr` 的厂商基线可进入只读迁移计划；
- qdisc 拓扑复杂到无法可靠恢复；
- 固定 swap 路径已被其他文件占用；
- 磁盘空间不足。

自动 swap 文件仅支持 `ext2`、`ext3`、`ext4` 和 `xfs` 根文件系统。Btrfs、ZFS、overlay、NFS、FUSE 及其他未验证文件系统会触发警告并跳过 swap 创建；其他网络配置仍可继续应用。

#### 2. 应用

```bash
env PORT_SPEED_MBPS=200 \
  bash ./debian13-1c1g-vps-tuning.sh apply
```

如果预检结果为 `PASS_WITH_PROVIDER_SYSCTL_TRANSFER`，`apply` 会在建立事务状态后备份 `/etc/sysctl.conf`，仅注释预检确认的相同值 `fq`/`bbr` 定义，再写入项目管理文件。备份保存在 root-only 状态目录中并纳入 `verify` 与 `rollback`；迁移失败会触发自动回滚。

应用成功后重启：

```bash
reboot
```

如果在安装 3X-UI 前应用调优，脚本会预先创建 `x-ui.service` drop-in。此时 `verify` 将“尚未安装代理服务”视为正常状态，不产生警告。以后安装 3X-UI 时，systemd 会读取该配置。

#### 3. 重启后验证

```bash
bash ./debian13-1c1g-vps-tuning.sh verify
bash ./debian13-1c1g-vps-tuning.sh status
```

#### 4. 安装 3X-UI 后验证

固定使用 3X-UI v3.4.2 时，应从官方 `v3.4.2` tag/release 获取安装脚本或资产。指向 `master` 的安装入口不能保证得到固定版本。

安装并配置 3X-UI 后：

```bash
env REQUIRE_PROXY_SERVICE=1 \
  PROXY_SERVICE_UNITS='x-ui.service' \
  bash ./debian13-1c1g-vps-tuning.sh verify
```

脚本检查 `x-ui.service` 的 systemd 配置值，以及主进程和直接子进程的 `/proc/<PID>/limits`。严格验证要求配置值与运行时 soft/hard limit 均不低于 65536。

## 诊断与故障定位

`dvt diagnose` 是无需受管 profile 的 Linux 能力快照，输出 `dvt.diagnose/1` JSON；不可读取项显示 unavailable，不产生主动测速流量，不修改配置，也不证明 managed state 已通过验证。

```bash
dvt diagnose
```

需要旧 profile 的增量计数、代理进程与 TFO 检查时使用下面的 managed 入口。它仍按持久 profile 的系统与资源范围检查，并要求 root；已有旧版状态应继续使用对应旧版资产，不能用新入口替代旧版状态核验。

```bash
dvt diagnose --managed
```

`diagnose --managed` 默认采集间隔为 5 秒。它输出 TCP 重传、超时、监听溢出和 TFO 增量；每 CPU softnet 增量；整机 CPU user/system/softirq/steal；接口收发、丢包、错误及可识别的 ethtool 错误计数。输出还包含采样前后的 qdisc 状态、默认路由、RPS/XPS/IRQ，以及代理主进程和直接子进程的 CPU time、RSS、线程数与 FD 数。进程证据不包含命令行参数。

`diagnose --managed` 还会只读检查 `net.ipv4.tcp_window_scaling` 和 `net.ipv4.tcp_moderate_rcvbuf`。任一值不为精确的 `1` 或无法读取时会输出告警；这两个键不属于项目的 17 个受管 sysctl，脚本不会自动写入或持久化它们。该告警表示主机默认值未确认或偏离预期，不会单独导致受管状态的 `verify` 失败。

该操作不产生性能测试流量，也不修改系统。需要观察实际负载时，应在采样窗口内从客户端复现 VLESS + REALITY + TCP 业务：

```bash
env DIAG_INTERVAL_SECONDS=15 \
  dvt diagnose --managed
```

默认不输出连接对端和进程详情。确需采集 `ss -tinp` 时，保存或共享日志前必须脱敏：

```bash
env DIAG_INCLUDE_SOCKET_DETAILS=1 \
  dvt diagnose --managed
```

以上 `DIAG_*` 环境变量仅适用于 managed 增量诊断，不控制默认 Python 快照。需要主动采样时按 [独立测量指南](automatic-measurement.md) 设置预算。

## 状态与重复执行

状态保存在 root-only JSON 中：

```text
/var/lib/proxy-vps-tuning/state.json
```

同一脚本版本和参数下重复执行 `apply` 时，脚本先验证当前配置；验证通过后不再写入。通过总控重复执行 `apply`，且未提供 `--port` 或 `PORT_SPEED_MBPS` 时，脚本复用状态中已安装的端口带宽；显式参数优先。状态版本、profile 或参数不匹配时，普通 `apply` 拒绝覆盖：仅带宽变化使用下述 `reconfigure`，其他参数变化走受管恢复，跨版本走迁移检查，不能把“旧配置仍可验证”当作“新版本已经安装”。

状态更新先由 `jq` 写入同目录临时文件。只有命令退出码、非空检查、单一 JSON 对象和完整结构校验全部通过后，才原子替换 `state.json`。空文件、空白文件、多个 JSON 文档或更新失败均不能覆盖上一个有效状态。

服务商扩容或降配端口后，使用 `dvt reconfigure --port <MBPS>`。重配置只接受与当前脚本版本和 profile 一致的 `VERIFIED` 状态，先执行完整 `verify`，再保留现有 RTT；自动 buffer 按新带宽重算，显式 buffer 保持原值。同值请求只验证不写入。普通 `apply` 的参数不一致门禁没有放宽，不得手工编辑 `state.json` 代替重配置。

重配置把旧 state 和 sysctl 管理文件保存为 root-only 固定备份，先提交 `RECONFIGURING`，再更新候选文件、必要的运行时 buffer、管理哈希并执行完整候选验证。任何失败会尝试恢复旧 sysctl 和旧 `VERIFIED` 状态；恢复失败时状态保留为 `DEGRADED`，`status` 显示事务和失败证据，普通 `verify`/`rollback`/`apply` 均拒绝越过，必须先执行 `dvt recover`。

## 回滚

回滚前确认运行入口与现有状态的版本、profile 一致；跨版本先用 [迁移指南](migration.md)。旧 `tcp_rmem/tcp_wmem` 原值不完整时，停止写入并保留状态，不能猜值、删状态或改用旧回滚器绕过。

默认回滚系统配置，但保留脚本创建的应急 swap：

```bash
dvt rollback
```

如果确认内存充足，并希望同时删除脚本创建的 swap：

```bash
env PURGE_CREATED_SWAP=1 \
  dvt rollback
```

如果普通回滚保留了 swap，重新应用前必须先显式 purge，完成状态清理。`swapoff` 失败时，脚本不会删除 swap、fstab 项或所有权状态。

参数输入错误时先判断是否发生写入。已有 `VERIFIED` 状态且参数不一致时，普通 `apply` 在事务写入前以退出码 4 拒绝；该次拒绝无需 rollback，可按已安装参数重试或运行 `verify`。

同版本、同 profile、有效 `VERIFIED` 状态下，仅变更服务商端口带宽应使用 `dvt reconfigure --port <MBPS>`。其他参数变化才按受管恢复流程执行 `PURGE_CREATED_SWAP=1 rollback`、重启和新参数 `preflight/apply`；跨版本使用迁移 checkpoint。不要为改带宽先执行保留 swap 的普通 rollback。

如果 `apply` 曾迁移 `/etc/sysctl.conf` 中的厂商 `fq`/`bbr` 基线，`rollback` 会在删除项目 sysctl 文件前恢复完整原文件，并显式恢复安装前记录的运行时 sysctl 值。恢复前必须同时验证原始备份和当前迁移后文件的 SHA-256；如果当前文件已被管理员或其他程序修改，脚本拒绝覆盖，将状态保留为 `DEGRADED`。

## 脚本会修改什么

- `/etc/sysctl.d/90-proxy-vps.conf`；
- `/etc/systemd/journald.conf.d/90-proxy-vps.conf`；
- `/usr/local/sbin/proxy-vps-fq`；
- `/etc/systemd/system/proxy-vps-fq.service`；
- `/etc/systemd/system/x-ui.service.d/90-proxy-vps.conf`，预置 `LimitNOFILE=65536`；
- `/var/lib/proxy-vps-tuning/state.json` 和 qdisc 原始状态；
- 在系统没有活动 swap 时，按需创建固定路径 `/swapfile-proxy`；
- 仅为脚本实际创建的 swap 添加一行 `/etc/fstab`。

主要 sysctl 包括：

- `net.core.default_qdisc=fq`；
- `net.ipv4.tcp_congestion_control=bbr`；
- 按带宽和目标 RTT 计算的 TCP socket 缓冲上限；
- `somaxconn`、`tcp_max_syn_backlog` 和 `netdev_max_backlog`；
- TCP Fast Open 内核开关、MTU probing 和 keepalive；
- `vm.swappiness=20`。

完整边界见 [设计范围](design-scope.md)。

### TCP Fast Open 与 Xray 的边界

`net.ipv4.tcp_fastopen=3` 只启用 Linux 客户端和服务端的基础能力。Linux 内核区分全局位图与单个 listener 的 `TCP_FASTOPEN` socket option；Xray 则通过 `streamSettings.sockopt.tcpFastOpen` 控制入站或出站 socket。以下命令没有输出，只表示 3X-UI 生成的 Xray 配置中未显式设置 `tcpFastOpen`，不能据此判断 TFO 的实际启用状态：

```bash
jq '.. | objects | select(has("tcpFastOpen")) | .tcpFastOpen' \
  /usr/local/x-ui/bin/config.json
```

`verify` 和 `diagnose --managed` 只读报告该字段是否存在，不修改代理配置。`/usr/local/x-ui/bin/config.json` 由 3X-UI 生成，面板重建配置时可能覆盖，不能直接编辑。只有当前 3X-UI 版本提供对应的入站/出站 sockopt 或高级配置入口，并已完成客户端兼容性测试时，才可通过面板配置。配置后应复查生成的 JSON 和实际连接。TFO 主要影响握手阶段，不能替代 BBR、fq 或线路质量，也不保证适用于所有中间设备。

主机的 `tcp_keepalive_time/intvl/probes` 只影响已经启用 `SO_KEEPALIVE`、且未被应用覆盖的 socket。Xray 入站 Keep-Alive 默认关闭，设置 `tcpKeepAliveIdle` 或 `tcpKeepAliveInterval` 后才启用；出站使用自身的默认值。主机 sysctl 不能单独证明 Xray 连接采用了这些 keepalive 参数。参见 [Linux IP sysctl](https://docs.kernel.org/networking/ip-sysctl.html) 和 [Xray Sockopt](https://xtls.github.io/en/config/transports/sockopt.html)。

## 脚本不会修改什么

- 不安装、升级或降级 3X-UI、S-UI、sing-box、Xray；
- 不改写 3X-UI 数据库或 Xray JSON；不采集或输出 UUID、REALITY 私钥、证书私钥或面板凭据。`verify` 和 `diagnose --managed` 会只读解析可访问的 Xray 生成配置，仅报告 TFO/keepalive 指定字段；
- 不增加、删除或重排 UFW 规则；
- 不开放 SSH、面板、订阅或代理端口；
- 不重启 `x-ui.service`、`xray.service`、`s-ui.service` 或 `sing-box.service`；若执行 `apply` 时 x-ui 已在运行，普通验证会要求重启服务或主机后再做严格验证；
- 不配置 RPS/RFS/XPS、IRQ affinity、CPU affinity 或 `GOMAXPROCS`；
- 不修改 DNS、路由、策略路由、MTU、IPv6 启停策略；
- 不开启 IP forwarding、NAT 或 TProxy；
- 不修改 `ip_local_port_range`、`tcp_mem`、`fs.file-max` 或 conntrack 上限；
- 不接管 Docker 与 UFW 的数据包处理关系。

## 脚本选择

| 文件 | 操作系统 | CPU 范围 | 内存档位 | swap 默认值/上限 |
|---|---|---:|---:|---:|
| `debian12-1c512m-vps-tuning.sh` | Debian 12 | 1 vCPU | 384–767 MiB | 1024/2048 MiB |
| `debian12-1c1g-vps-tuning.sh` | Debian 12 | 1 vCPU | 768–1535 MiB | 1024/2048 MiB |
| `debian12-1c2g-vps-tuning.sh` | Debian 12 | 1–2 vCPU | 1536–3072 MiB | 1024/4096 MiB |
| `debian13-1c512m-vps-tuning.sh` | Debian 13 | 1 vCPU | 384–767 MiB | 1024/2048 MiB |
| `debian13-1c1g-vps-tuning.sh` | Debian 13 | 1 vCPU | 768–1535 MiB | 1024/2048 MiB |
| `debian13-1c2g-vps-tuning.sh` | Debian 13 | 1–2 vCPU | 1536–3072 MiB | 1024/4096 MiB |
| `debian12-adaptive-vps-tuning.sh` | Debian 12 | ≥1 vCPU | ≥384 MiB | 默认关闭 / 4096 MiB |
| `debian13-adaptive-vps-tuning.sh` | Debian 13 | ≥1 vCPU | ≥384 MiB | 默认关闭 / 4096 MiB |
| `ubuntu2404-adaptive-vps-tuning.sh` | Ubuntu 24.04 | ≥1 vCPU | ≥384 MiB | 默认关闭 / 4096 MiB |

文件名和状态 ID 中的 `1c2g` 是兼容名称。同一 2G profile 同时支持 1C2GB 和 2C2GB，不另建重复的 2C2G 文件；profile ID 保持不变，版本升级仍须通过状态迁移检查。各资源脚本独立校验系统、架构、CPU 和内存，总控选择不能绕过底层预检。其他 Debian CPU/内存组合选择对应 adaptive；Ubuntu 24.04 使用独立 adaptive，仍检查系统、架构和实际能力。

默认端口上限为 200 Mbps，也可显式设置为 1–10000 Mbps。该值应填写 VPS 套餐或服务商规定的上限，不能使用虚拟网卡显示的链路速率。

## 1–10000 Mbps 配置输入

100 Mbps：

```bash
env PORT_SPEED_MBPS=100 \
  bash ./debian12-1c1g-vps-tuning.sh apply
```

200 Mbps：

```bash
env PORT_SPEED_MBPS=200 \
  bash ./debian12-1c2g-vps-tuning.sh apply
```

1000 Mbps：

```bash
env PORT_SPEED_MBPS=1000 \
  bash ./debian13-1c2g-vps-tuning.sh apply
```

可配置 1–10000 范围内的任意整数；参数接受范围不等于吞吐验收。adaptive 缓冲封顶见[平台契约](platform-support.md)。原固定 profile 的策略保持：默认目标 RTT 为 200 ms；512M、1G 和 2G 资源档分别采用 1×、1.25× 和 1.5× BDP，再向上选择 16/32/64 MiB，并受各 profile 的 16/32/64 MiB 上限约束：

| 资源档 | BDP 系数 | 100 Mbps | 200 Mbps | 500 Mbps | 1000 Mbps |
|---|---:|---:|---:|---:|---:|
| 512M | 1× | 16 MiB | 16 MiB | 16 MiB | 16 MiB（截断警告） |
| 1G | 1.25× | 16 MiB | 16 MiB | 16 MiB | 32 MiB |
| 2G | 1.5× | 16 MiB | 16 MiB | 32 MiB | 64 MiB |

在 200 Mbps 下，所有资源档的上限均为 16 MiB。512M 档优先限制内存压力；1G 和 2G 档逐级增加高 BDP 余量。在此表范围内，仅 512M、1000 Mbps、200 ms 的组合触发资源截断警告；更高带宽输入也可能达到各 profile 封顶。

表中数值是自动调优允许的最大 socket 缓冲，不表示每条连接会立即占满。Linux TCP 接收缓冲仍按连接需求自动增长；应用显式调用 `setsockopt(SO_RCVBUF)` 时可能改变该行为。资源截断用于限制内存风险，不表示带宽参数无效。没有持续监控和高 BDP 证据时，不应手工设置 `BUF_MAX`。

## 参数

| 变量 | 默认值 | 范围/说明 |
|---|---:|---|
| `PORT_SPEED_MBPS` | `200` | `1–10000` |
| `BUFFER_TARGET_RTT_MS` | `200` | `20–500` |
| `BUF_MAX` | `auto` | 固定 profile 为 16/32/64 MiB；adaptive 按 RAM 封顶于 16–256 MiB |
| `ENABLE_SWAP` | 固定档 `1`；adaptive `0` | `0` 或 `1` |
| `SWAP_MB` | `1024` | 512M/1G 脚本最高 2048，2G/adaptive 最高 4096 |
| `PURGE_CREATED_SWAP` | `0` | 回滚时是否清理脚本创建的 swap |
| `PROXY_SERVICE_UNITS` | 自动识别 | 空格分隔的 systemd service |
| `REQUIRE_PROXY_SERVICE` | `0` | 为 `1` 时没有目标代理服务即验证失败 |
| `DIAG_INTERVAL_SECONDS` | `5` | `1–60`，仅 `diagnose --managed` 的增量窗口 |
| `DIAG_INCLUDE_SOCKET_DETAILS` | `0` | `diagnose --managed` 中为 `1` 时输出可能包含对端地址的 `ss -tinp` |
| `UPDATE_TAG` | 自动发现 | `update` 的目标 Release；等价命令行参数为 `--target` |

不支持自定义 swap 文件路径；脚本只可能创建 `/swapfile-proxy`。

主动测量的环境变量单独见 [高级测量参数](advanced-measurement.md#参数参考)，不能把旧 benchmark cap 与持久 `--port` 或新版 measure 的 cap 混用。

## qdisc 边界

脚本支持以下 qdisc 拓扑：普通根 `fq`、`fq_codel`、默认参数的常规 `pfifo_fast`、`noqueue`，以及根为 `mq`、叶为 `fq`/`fq_codel` 的常规云网卡。HTB、TBF、CAKE、自定义 `pfifo_fast` 或其他复杂层次会在预检阶段阻断，防止 `tc qdisc replace ... root fq` 破坏既有多队列或流量整形结构。

已有根 `fq` 和 `mq` 下已有的 `fq` 叶子不会被重复替换；回滚也不会以默认 fq 重置其自定义参数。脚本只将能够可靠恢复的 `fq_codel` 根/叶或常规根 `pfifo_fast` 切换为 fq，并在回滚时按预先保存的语义恢复。

`tc` 的显示格式与命令输入格式并不完全相同。例如，状态可显示 `limit 10240p`，恢复命令仍使用 `limit 10240`。脚本通过 `tc -j` 保存数值，并按命令输入语法重建。比较 `target`、`interval` 和 `ce_threshold` 时，只容忍内核或工具回显造成的 ±1 微秒量化差异；其他受支持参数必须一致。

执行 qdisc 恢复命令后，rollback 会重新读取实际状态。只有恢复结果与原始快照语义一致，才删除状态和快照。原快照中的 `handle 0:` 表示未指定，允许内核为 classless qdisc 自动分配运行时 handle；显式非零 handle 会尝试恢复并严格比较。后置验证失败时，状态保留为 `DEGRADED`，回滚不得报告成功。

## Docker 边界

当前版本主要验证原生 systemd 部署。Docker 可能通过自身的 netfilter 规则改变 UFW 过滤路径；使用 `network_mode: host` 还会暴露容器内的全部监听端口。Docker 场景必须单独检查，不属于本脚本的防火墙范围。

## 手动获取与离线运行

以下方法适用于离线、审计或安装入口不可用时的恢复。必须先验证 manifest 的可信固定摘要，不能只依赖与脚本同时下载但未固定的校验文件；当前值见 [发布说明](releases/v0.2.0-rc.4.md)。不同版本不得放在同一目录。

### 下载与校验

准备离线 bundle 时，将固定 `v0.2.0-rc.4` Release 的 26 项上传资产（24 项运行文件、`SHA256SUMS` 和 `install.sh`）下载到一个新建的独立目录，并在该目录内执行以下步骤。每步成功后才继续；不要混入其他版本文件。

先核验清单和安装器本身的固定摘要，之后才能用清单校验运行文件：

```bash
(
  set -Eeuo pipefail
  printf '%s  %s\n' \
    'a704a9323b5bb9d9b0d1efe9c1b63825fef6b72aa29b075f43c151d502a2de4b' \
    SHA256SUMS | sha256sum -c -
  printf '%s  %s\n' \
    '06c8b235ce0538d6e5247b3b50fa568e6c71f9ee9f28b4cc999f031b5e9978ec' \
    install.sh | sha256sum -c -
)
```

**直接下载的 Release 文件是平铺布局，尚不是离线安装器要求的目录结构。** 清单中的五项实验脚本位于 `experiments/htb-aggregate/`；联网安装器会自动创建该结构，离线 `--source-dir` 不会。对平铺下载目录，复制这五项文件到指定位置，再检查全部 24 项运行文件；原下载文件保留：

```bash
(
  set -Eeuo pipefail
  mkdir -p -- experiments/htb-aggregate
  for dvt_asset in \
    experiment-plan.sh \
    htb-aggregate-experiment.sh \
    rate-sweep-plan.sh \
    rate-sweep-run.sh \
    rate-sweep-analyze.sh
  do
    cp -- "$dvt_asset" "experiments/htb-aggregate/$dvt_asset"
  done
  sha256sum -c SHA256SUMS
)
```

如果已有按仓库目录结构组织的完整 bundle，仍先核验上面的两个固定摘要，然后跳过复制步骤，直接检查：

```bash
sha256sum -c SHA256SUMS
```

只有全部校验成功，才可使用下方 `--source-dir` 安装。不要修改清单路径、忽略缺失文件或跳过失败项；向离线主机传输 bundle 时保留目录结构，并在目标上重新核验固定摘要及全部文件。

只下载总控脚本和 `SHA256SUMS` 属于单独的备用联网入口，不是完整离线 bundle。先核验清单的固定摘要，再检查对应条目：

```bash
grep -F '  debian-vps-tuning.sh' SHA256SUMS | sha256sum -c -
less ./debian-vps-tuning.sh
chmod +x ./debian-vps-tuning.sh
```

这是 root 级系统脚本。不得跳过校验并直接使用 `curl | bash`。总控随后还会校验实际调用资源脚本的 SHA-256。

### 本地使用与命令行模式

`debian-vps-tuning.sh` 是总控入口。它读取系统及版本、x86_64/aarch64 架构、逻辑 CPU 和实际内存，从九份 profile 中选择匹配项；原 Debian 档位保留 ID，其他受支持组合采用 adaptive。总控不包含独立的调优逻辑，只负责选择、SHA-256 校验和调用 profile。

以上 profile 选择用于持久配置及 legacy profile 路径；独立 `diagnose`、`measure`、`htb-sweep`、`report` 在该选择前进入 Python 能力路径。

从完整项目目录运行：

```bash
bash ./debian-vps-tuning.sh
```

直接使用命令行模式：

```bash
bash ./debian-vps-tuning.sh preflight --port 200
bash ./debian-vps-tuning.sh apply --port 200
bash ./debian-vps-tuning.sh reconfigure --port 500
bash ./debian-vps-tuning.sh verify
bash ./debian-vps-tuning.sh status
bash ./debian-vps-tuning.sh diagnose
# benchmark 还需要 BENCHMARK_HOST 和共享预算，见 advanced-measurement.md
bash ./debian-vps-tuning.sh benchmark
bash ./debian-vps-tuning.sh update
# 仅在仍有旧版本管理状态时，检查新目标版本
bash ./debian-vps-tuning.sh update --target v0.2.0-rc.4
bash ./debian-vps-tuning.sh rollback
```

上面是可单独选择的命令参考，不是一段从头运行的脚本。独立测量的本地入口为 `bash ./debian-vps-tuning.sh measure --rate-cap 20 --plan-only`；其他参数与安装后的 `dvt` 相同。

自 v0.2.0-rc.3 起，无 action 的交互菜单为单屏分组页面：每项标注只读、写入、重启、联网或流量等副作用，框外显示主机、档位、受管记录和当前运行值；“受管记录”是上次写入的状态，不等于本次 verify 结论。菜单只执行一个动作就退出，结束后显示退出码和下一步。写入和 `rollback` 确认默认 N。非 root 用户只能选能力诊断。需要额外参数的 `measure`、`htb-sweep`、`report`、`probe`、`benchmark`、`migrate` 和 `recover` 列在“高级与测量”页的命令参考中，请在命令行运行。设置非空的 `NO_COLOR` 可关闭颜色；终端把框线字符显示为双宽导致错位时，可用 `DVT_ASCII=1 dvt` 改为 ASCII 框线。设计依据见[交互界面详细设计](interactive-cli-design.md)。

自 rc.4 起，已解析的受管版本与入口版本不一致时，主页明确提示冲突，1–6、9 和 HTB 显示不可用，回车默认执行 7 本地能力诊断；不会因默认选择自动联网。8 检查升级保留为显式选择。状态核验与回滚继续使用来源版本；迁移仍按固定目标和 checkpoint 完成，不建议稳定 rc.2 主机仅为菜单迁移。无可识别版本或状态解析失败不等于已经证明兼容，后端检查仍会拒绝不满足契约的动作。

在没有交互终端的自动化环境中，必须明确指定 action；总控不会进入菜单或自动执行 `apply`。CLI `reconfigure` 必须显式提供 `--port`，不会采用默认值或同名环境变量。`recover` 用于未完成的带宽重配置事务，也保留经 `ALLOW_EMPTY_STATE_RECOVERY=1` 明确确认的 rc.2 空状态隔离分支。

不要使用以下入口：

```text
curl ... | bash
bash <(curl ...)
```

这两种形式会在 root 权限下直接执行下载内容，绕过“完整下载、文件校验、执行”三个独立步骤。

完整 bundle 也可安装为短命令入口；在其根目录执行：

```bash
bash install.sh --source-dir "$PWD" --no-launch
```

### 入口不可用时的联网验证

以下保留固定版本下载总控的备用验证方法。只适用于受管状态已经是 `0.2.0-rc.4`；旧状态必须使用对应旧版或迁移检查。受管状态仍为 `0.2.0-rc.2` 时，改用 rc.2 总控 `https://github.com/alieismy/vps-tuning/releases/download/v0.2.0-rc.2/debian-vps-tuning.sh`，SHA-256 为 `7d8769a8cd09e562b2f074034e7a1a6f71c71bb2fddc1302ebd28fb9794b95bd`，其余命令相同。受管状态为 `0.2.0-rc.3` 时，使用 rc.3 总控 `https://github.com/alieismy/vps-tuning/releases/download/v0.2.0-rc.3/debian-vps-tuning.sh`，SHA-256 为 `2c7b0eba904a8490df0da042e39f525d6bd3cf40bcd06f5c72fe2a1254c421a9`。日常验证优先使用与状态同版本的已安装入口。

重启并重新登录 VPS 后执行。`verify` 只读检查当前状态，不会再次运行 `apply`，也不要求重新输入状态中已保存的端口带宽：

```bash
(
  set -e

  dvt_tmp="$(mktemp -d)"
  trap 'rm -rf -- "$dvt_tmp"' EXIT

  curl --fail --show-error --silent --location \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 15 \
    --max-time 120 \
    -o "$dvt_tmp/debian-vps-tuning.sh" \
    https://github.com/alieismy/vps-tuning/releases/download/v0.2.0-rc.4/debian-vps-tuning.sh

  printf '%s  %s\n' \
    '1e5e7e3065d67aa483b94e2ca7a61cad75611f14c7cf46a36937fb395a428e84' \
    "$dvt_tmp/debian-vps-tuning.sh" | sha256sum -c -

  bash "$dvt_tmp/debian-vps-tuning.sh" verify
)

printf 'verify_after_reboot_exit=%s\n' "$?"
```

只有 `verify_after_reboot_exit=0` 表示验证通过。应保存完整输出，不能只保留最后一行。

### 入口不可用时的严格代理验证

先完成调优和重启验证，再安装 3X-UI。安装并启动 3X-UI 后执行：

```bash
(
  set -e

  dvt_tmp="$(mktemp -d)"
  trap 'rm -rf -- "$dvt_tmp"' EXIT

  curl --fail --show-error --silent --location \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 15 \
    --max-time 120 \
    -o "$dvt_tmp/debian-vps-tuning.sh" \
    https://github.com/alieismy/vps-tuning/releases/download/v0.2.0-rc.4/debian-vps-tuning.sh

  printf '%s  %s\n' \
    '1e5e7e3065d67aa483b94e2ca7a61cad75611f14c7cf46a36937fb395a428e84' \
    "$dvt_tmp/debian-vps-tuning.sh" | sha256sum -c -

  env \
    REQUIRE_PROXY_SERVICE=1 \
    PROXY_SERVICE_UNITS='x-ui.service' \
    bash "$dvt_tmp/debian-vps-tuning.sh" verify
)

printf 'strict_verify_after_3xui_exit=%s\n' "$?"
```

严格验证要求 `x-ui.service` 处于 `active`，并确认 systemd 配置、3X-UI 主进程及其直接 Xray 子进程的 NOFILE soft/hard limit 均不低于 65536。安装 3X-UI 后再次重启并重复严格验证，用于检查开机启动和新进程的限制继承。

## 可选系统准备

以下是独立的系统维护建议，不是运行所有 DVT 功能的必做步骤。先检查服务商镜像和业务兼容性，再决定升级、清理软件或配置防火墙；每项操作都可能影响现有服务。

### VPS 初始化

以下命令要求已经进入 root shell（提示符通常为 `#`，`id -u` 输出 `0`），因此不使用 `sudo`。厂商最小化镜像通常允许直接以 root 登录，也可能未安装 `sudo`。

建议先更新系统并查看升级计划：

```bash
apt update
apt -s full-upgrade
apt full-upgrade -y
```

以下组合同时包含可选运维工具和脚本依赖；仅按需要选择，不要求全部安装：

```bash
apt install -y \
  curl wget ca-certificates gnupg lsb-release unzip \
  vim nano htop ufw jq \
  iproute2 procps kmod util-linux
```

清理自动安装且不再需要的软件包前，先模拟并检查列表：

```bash
apt-get -s autoremove --purge
```

确认无误后再执行：

```bash
apt autoremove --purge -y
```

更新内核后应重启，再运行调优脚本：

```bash
reboot
```

### UFW 注意事项

在远程 VPS 上启用 UFW 前，必须先放行真实 SSH 端口。例如 SSH 使用 22/TCP：

```bash
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw allow 22/tcp comment 'SSH management'
ufw enable
ufw status numbered
```

如果 SSH 不是 22，请替换为真实端口。双栈 VPS 应确认 `/etc/default/ufw` 中为 `IPV6=yes`。

VLESS + REALITY 入站只开放实际使用的 TCP 端口。面板端口最好限制到可信管理 IP，或通过 SSH 本地转发访问。调优脚本只读取 UFW 状态和监听端口，不会替你修改规则。

## 历史系统选型说明（2026-08-04）

本节从旧 README 保留，信息仅核对至 2026-08-04；下述“当前/最新”均指该日期，不代表本文维护日期。当前项目支持范围以 [平台矩阵](platform-support.md) 为准，实施 OS 升级前需重新核对官方资料。Debian 13 是当前 stable，最新点版本为 13.6；Debian 12 是 oldstable，常规 Release、Security 和 Backports 支持已经结束，LTS 持续到 2028-06-30。Debian 13 的常规支持截至 2028-08-09，LTS 截至 2030-06-30。参见 [Debian Releases](https://www.debian.org/releases/) 和 [Bookworm 转入 LTS 公告](https://www.debian.org/News/2026/20260712)。

新建的 1C1G、1C2G 和 2C2G VPS 默认使用 Debian 13 minimal。Debian 12 适用于已有稳定节点、服务商 Debian 13 镜像存在已确认缺陷，或第三方软件明确要求 Debian 12 的情况。不得仅为未经证实的性能收益，对唯一生产节点执行原地大版本升级。

| 维度 | Debian 12 | Debian 13 | 项目判断 |
|---|---|---|---|
| 发布状态 | oldstable，处于 LTS | 当前 stable | 新部署优先 Debian 13 |
| 支持期限 | LTS 至 2028-06-30；少数包可能不在 LTS 覆盖范围 | 常规支持至 2028-08-09，LTS 至 2030-06-30 | 公网长期节点优先更长的常规支持窗口 |
| 典型内核系列 | Linux 6.1 LTS | Linux 6.12 LTS | 13 有更新的内核和虚拟化驱动，但不保证吞吐更高 |
| 用户态基线 | systemd 252、OpenSSH 9.2、OpenSSL 3.0、glibc 2.36 | systemd 257、OpenSSH 10.0、OpenSSL 3.5、glibc 2.41 | 新软件兼容性更有利；旧脚本和闭源 agent 需验证 |
| 迁移风险 | 现有部署成熟，变更较少 | 原地升级需检查网卡名、SSH、`/tmp` 和 sysctl 加载行为 | 关键节点优先新建 Debian 13 并行迁移 |

Debian 13 的适用理由：

- 当前为 stable，常规安全维护和 LTS 生命周期更长；
- Linux 6.12 LTS、systemd 257、OpenSSH 10.0p1 和 OpenSSL 3.5 提供更新的内核、虚拟化和系统组件；
- Debian 官方提供 GenericCloud、NoCloud 和 OpenStack 等云镜像；
- 3X-UI 官方安装脚本按发行版 ID `debian` 选择 APT 和 Debian systemd unit，没有发现 Debian 12-only 的版本判断；
- Xray-core 官方 Linux 构建使用 `CGO_ENABLED=0`，通常不依赖 Debian 12/13 的特定 glibc ABI。

Debian 13 的限制与迁移风险：

- Debian 13 不保证比 Debian 12 占用更少内存，也不保证自动提高 Xray 的吞吐、延迟或并发能力；
- `/tmp` 默认使用按需分配的 tmpfs，最大值可达到内存的 50%；1C1G 节点应限制大型临时文件和日志；
- `systemd-sysctl` 不再读取 `/etc/sysctl.conf`，本地配置应放入 `/etc/sysctl.d/*.conf`；本项目使用该规范路径，但旧调优脚本可能不兼容；
- Debian 12 原地升级到 13 时，部分系统的可预测网卡名可能改变，硬编码接口名的网络、防火墙或 qdisc 配置必须提前检查；
- OpenSSH、OpenSSL、Python 和 systemd 的大版本变化可能影响旧密钥、自动化脚本或服务商闭源 agent；
- 服务商提供“Debian 13”镜像不等于运行内核一定为 6.12，也不证明 cloud-init、IPv6 和网络模板已经通过验证。

相关变化见 [Debian 13 发布公告](https://www.debian.org/News/2025/20250809) 和 [Debian 13 Release Notes：已知问题](https://www.debian.org/releases/stable/release-notes/issues.en.html)。

### 按 VPS 资源档选择

| VPS 配置 | 推荐系统 | 适用判断 | 主要约束 |
|---|---|---|---|
| 1C1G | Debian 13 minimal | 新建节点的默认选择；不安装桌面，仅保留必要服务 | 1 GiB 是 Debian 13 无桌面安装的推荐内存，不代表 3X-UI/Xray 具有固定余量；应监控 RSS、FD、CPU steal、softirq、日志和 `/tmp` |
| 1C2G | Debian 13 | 三档中较均衡，更新和临时任务的内存余量优于 1C1G | 单核仍可能成为加密、软中断或高并发瓶颈 |
| 2C2G | Debian 13 | 更适合多连接、多入站或较高 CPU 负载 | 2 vCPU 不保证吞吐翻倍，也不能仅凭 CPU 数启用 RPS/RFS/XPS 或 IRQ affinity |

Debian 13 官方给出的无桌面 amd64 安装最低内存为 512 MB，推荐内存为 1 GB。服务器实际需求取决于运行服务，不能据此推导“空载固定约 100 MB”或代理容量。参见 [Debian 13 amd64 安装要求](https://www.debian.org/releases/trixie/amd64/ch03s04.en.html)。

### 虚拟化类型比发行版名称更接近内核事实

KVM、VMware、Hyper-V 等完整虚拟机通常运行来宾系统自己的 Debian 内核；LXC、Incus 和部分 OpenVZ 类系统容器则共享宿主机内核。容器内的 `/etc/os-release` 即使显示 Debian 13，也不能证明运行内核为 6.12、BBR 可用，或 qdisc/sysctl 权限完整。选择 profile 前至少检查：

```bash
cat /etc/os-release
uname -r
systemd-detect-virt
systemd-detect-virt --container || true
sysctl -n net.ipv4.tcp_available_congestion_control
sysctl -n net.ipv4.tcp_congestion_control
sysctl -n net.core.default_qdisc
tc -s -d qdisc show
```

生成 profile 分别校验操作系统、CPU、内存、运行内核能力和 qdisc 拓扑。系统选型不能替代目标机 `preflight`。

## 日志脱敏与安全报告

公开文档和 Issue 只能保留复现所需、且不足以定位具体资产的信息，例如操作系统主版本、内核系列、CPU/内存档位、文件系统类型、脱敏后的套餐带宽和验证结论。下列内容不得公开：

- 服务商、机房、区域、订单号和实例 ID；
- 公网/私网 IP、IPv6 前缀、域名、主机名、默认网关和可关联的 DNS 记录；
- SSH、面板、订阅、API、监控和代理端口的真实组合；
- 用户名、密码、UUID、订阅 ID、API Token、Cookie、SSH 私钥、证书私钥、REALITY 私钥和 Short ID；
- 未脱敏的 3X-UI 数据库、Xray JSON、客户端链接、二维码、日志和截图；
- TcpQuality 等第三方报告 URL/ID、精确测试时间、boot ID、可反查 run ID 和授权 iperf3 服务端地址。

`diagnose` 和 `diagnose --managed` 可能输出接口地址、路由和中断信息；`DIAG_INCLUDE_SOCKET_DETAILS=1` 还可能输出连接对端。`benchmark` 元数据包含 boot ID、用户指定的 host 和 run ID；TcpQuality 节点表及 CSV 也可能包含时间和第三方节点地址。共享日志前必须逐项脱敏，不能只替换公网 IPv4。公开 Release 的脚本 SHA-256 和项目下载 URL 用于供应链校验，应予保留，不属于 VPS 隐私数据。

发现安全问题时按 [SECURITY.md](../SECURITY.md) 提交，不要在公开 Issue 中附带完整资产配置。
