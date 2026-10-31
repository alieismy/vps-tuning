# VPS Tuning

简体中文 · [English](README.en-US.md) · [v0.2.0-rc.4 预发行版](https://github.com/alieismy/vps-tuning/releases/tag/v0.2.0-rc.4) · [已发布 rc.3](https://github.com/alieismy/vps-tuning/releases/tag/v0.2.0-rc.3)

**v0.2.0-rc.4 预发行版。** 修正 `dvt` 菜单在入口版本与受管版本不一致时的引导：默认选择本地能力诊断，受管动作显示不可用，检查升级须显式选择；迁移器另接受 `0.2.0-rc.3` 来源。调优内容不变，范围和证据见[发布说明](docs/releases/v0.2.0-rc.4.md)。已受管主机要在新版本下执行受管动作，须先完成跨版本迁移；预检通过不证明原始 TCP 快照完整，迁移仍须通过 `migrate prepare`。不建议稳定 rc.2 主机仅为交互界面迁移。

为 Linux VPS 提供主机网络诊断、有预算的公共 iperf3 自动测量，以及可验证、可回滚的 BBR + fq 配置。测量无需先应用调优或自建对端；临时 HTB 速率阶梯实验用于观察发送速率与重传的关系。

当前为 **Pre-release**，rc.4 固定资产已完成公开下载回验。持久配置支持 Debian 12/13、Ubuntu 24.04 LTS 的 x86_64/ARM64 主机；独立诊断和测量按实际 Linux 能力检查。已有功能与恢复证据不等于可靠 policer（流量监管）识别或代理业务性能收益。

仓库原名 `debian-vps-tuning`，2026-10-10 改为现名，旧链接会自动跳转到本仓库。`dvt` 命令、发布资产文件名、安装路径和受管状态路径均保持不变。

本版运行资产保留已验证的旧仓库常量，安装器和总控通过 GitHub 重定向访问新仓库；不要在同一账户下重新创建旧名仓库，以免使这些重定向失效。

[功能与边界](#功能与边界) · [支持范围](#支持范围与前置条件) · [快速开始](#快速开始) · [常用操作](#常用操作) · [升级与回滚](#升级与回滚) · [文档](#文档导航) · [帮助](#帮助贡献与安全报告)

## 功能与边界

| 我想做什么 | 入口 | 影响与条件 |
|---|---|---|
| 查看主机能力与网络状态 | `dvt diagnose` | 无需先 apply；无主动测速流量、不改系统配置；输出能力快照 |
| 自动选点并测量出向 TCP | `dvt measure` | 无需先 apply；显式 cap 和共享预算；保持 sysctl/qdisc，保存本地证据 |
| 测试临时整形区间 | `dvt htb-sweep` | 只接受可完整恢复的单根 fq；临时限制整个接口的出向流量，包括 SSH；结束核对恢复 |
| 管理主机网络配置 | `dvt preflight` → `dvt apply` | 持久管理 BBR + fq、TCP 缓冲、队列参数、可选 swap、journald 和 NOFILE；支持验证与回滚 |
| 检查采集结果 | `dvt report` | 核验独立测量报告摘要，不自动应用候选速率 |
| 离线解释重传与候选证据 | [`explain_measurement.py`](docs/measurement-explanation.md) | 在完整源码目录运行，无需安装到 VPS；保留原分类，不生成限速决定 |

项目不安装或改写代理业务，不配置防火墙、路由、DNS、NAT 或 TProxy。`verify` 和旧增量诊断 `diagnose --managed` 会只读解析可访问的 Xray 生成配置，报告 TFO/keepalive 指定字段；不会改写配置或输出其中的凭据。持久 HTB 未启用。

## 支持范围与前置条件

| 能力 | 前置条件 |
|---|---|
| 持久配置 | Debian 12/13 或 Ubuntu 24.04 LTS，`x86_64`/`aarch64`，原生 systemd；至少 1 个逻辑 CPU、384 MiB RAM；实际可用的 BBR/fq、常规默认路由和可恢复 qdisc |
| 独立诊断 | Linux、Python 3.9+ 和可用的系统观察命令；无需 root，不可读取项显示 unavailable |
| 独立测量 | Python 3.9+、Bash、iperf3、iproute2、jq、awk、GNU coreutils、util-linux；实际执行需要 root 和共享预算账本；不按发行版或 CPU/RAM 档位拒绝 |
| 临时 HTB | 满足测量依赖，另需 HTB/fq、显式接口及完整恢复能力；mq、clsact、ingress、额外 class/filter 或未知 fq 参数会被拒绝 |

程序不自动安装依赖。完整准备步骤见[操作指南](docs/usage.md#执行前准备)，限速测试建议使用 iperf3 3.18 或包含等效修复的版本。

原 Debian 资源档保留兼容策略，其他受支持组合采用 adaptive profile。持久配置的 `--port` 接受 **1–10000 Mbps**，应填写服务商套餐上限；它不是虚拟网卡速率，也不创建限速器。测量的 `--rate-cap` 是独立的发送目标和预算依据。参数范围不代表相应吞吐已验收，详见[平台与资源策略](docs/platform-support.md)。

## 快速开始

### 安装前先选择路径

- **全新主机：** 按下方固定摘要安装，再选择只诊断/测量或持久配置。
- **已有 DVT 受管状态：** 先读[迁移指南](docs/migration.md)。安装新入口不迁移状态，不要用新版 apply 覆盖旧状态。若旧 `tcp_rmem/tcp_wmem` 原值不足三个字段，停在只读检查，保留状态和原版资产，不执行 rollback/reboot。
- **准备修改配置：** 先备份基线并确认服务商控制台/救援入口可用。已有厂商 BBR/fq 时可先 preflight，再决定是否接管；不必仅因已经有 BBR/fq 就重复调优。

<a id="联网安装与验证"></a>

### 安装

在 root shell 中执行（`id -u` 应为 `0`）。以下命令完整下载固定 `v0.2.0-rc.4` 安装器，验证 SHA-256 后运行；`--no-launch` 只安装，不执行调优或测速。

```bash
(
  set -Eeuo pipefail
  dvt_i="$(mktemp)"
  trap 'rm -f -- "$dvt_i"' EXIT
  curl --fail --show-error --silent --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 120 \
    -o "$dvt_i" \
    https://github.com/alieismy/vps-tuning/releases/download/v0.2.0-rc.4/install.sh
  printf '%s  %s\n' \
    '06c8b235ce0538d6e5247b3b50fa568e6c71f9ee9f28b4cc999f031b5e9978ec' \
    "$dvt_i" | sha256sum -c -
  bash "$dvt_i" --no-launch
)
```

只有命令成功退出后才继续。安装器会校验固定 manifest 和全部运行资产，提供 `/usr/local/bin/dvt`；内容不符时拒绝覆盖。下载不会回退到可变分支、`latest` 或第三方镜像，不采用未经校验的 `curl | bash`。

```bash
dvt --version
```

### 路径 A：只诊断或独立测量

以下命令不需要先 apply。安装完成后，先看能力快照和无流量计划：

```bash
dvt diagnose
dvt measure --rate-cap 20 --plan-only
```

确认测试窗口、预算与公共服务使用条件后，下面的**示例会产生出向 TCP 流量**。在 root shell 执行；证据目录必须尚不存在，账本窗口不能通过删除或换 ID 绕过历史消费：

```bash
install -d -m 0700 /root/dvt-traffic
dvt measure --rate-cap 20 --family 4 --budget-mib 600 \
  --ledger /root/dvt-traffic/window.json --window-id path-check-01 \
  --output-dir /root/dvt-measure-01
```

工具显示计划并请求确认，自动从公共目录有限选点；公共服务会看到 VPS 来源地址，节点也可能繁忙或不可达。600 MiB 是示例 application payload 预算，不包括协议、重传和服务商计费差异。完整结果、失败结算及依赖说明见[自动测量指南](docs/automatic-measurement.md)。完成后查看报告：

```bash
dvt report --input-dir /root/dvt-measure-01
```

`INSUFFICIENT_EVIDENCE` 是允许的结果；退出码 0 只表示报告采集完成。测试不经过 VLESS/REALITY 客户端，不能据此承诺业务提速。临时整形另见 [htb-sweep 指南](docs/temporary-htb.md)，执行前必须理解整个接口限速及恢复条件。

需要查看扫描覆盖缺口、绝对重传次数、字节量和候选证据限制时，可使用[离线解释工具 0.1.1](https://github.com/alieismy/vps-tuning/releases/tag/measurement-explanation-v0.1.1)。它是独立的源码 Pre-release；下载校验及 Windows/Linux 命令见[工具发布说明](docs/releases/measurement-explanation-v0.1.1.md)，无需升级 VPS 或运行安装器，不改变主机已安装的主程序版本。

### 路径 B：应用持久配置

以下适用于全新、无旧受管状态的主机。先把 `200` 换成服务商套餐上限，运行只读预检：

```bash
dvt preflight --port 200
```

预检通过并确认写入范围后执行：

```bash
dvt apply --port 200
```

成功后按提示重启：

```bash
reboot
```

重新登录后验证。无需再次填写带宽，也不会重新 apply：

```bash
dvt verify
dvt status
```

每步失败都停止，保存完整输出。安装并启动 3X-UI 后还需严格验证，检查服务活动及 systemd、主进程和直接 Xray 子进程的 NOFILE；重启后重复验证：

```bash
env REQUIRE_PROXY_SERVICE=1 PROXY_SERVICE_UNITS='x-ui.service' dvt verify
```

其他服务、预检阻断、swap 与 qdisc 恢复说明见[操作指南](docs/usage.md)。

## 默认低流量验收路径

持久配置的安装与迁移默认完成固定资产校验、preflight、apply、重启后 verify、适用的严格代理服务验证，以及少量真实客户端业务冒烟。日常检查使用 status/verify，故障首先使用无主动流量的 diagnose；日常检查不要求重新 apply。

`measure`、`htb-sweep`、旧 `probe`、benchmark、TcpQuality 和 HTB 研究均不是每台 VPS 的默认必做项。主动测量须有明确问题和预算；benchmark、TcpQuality、旧 HTB reference/sweep/A/B/A 研究还要求独立高额度测试机。详细分层见[验证说明](docs/validation.md#默认验收路径与研究边界)。

## 常用操作

| 操作 | 命令或文档 |
|---|---|
| 交互菜单 | `dvt`；安全引导先 preflight，明确确认后才 apply；异版状态默认本地诊断，升级检查须显式选择 |
| 当前入口版本 / 受管状态 | `dvt --version` 查看入口版本；`dvt status` 要求入口与受管状态版本一致。版本不一致时，按[迁移指南](docs/migration.md)只读盘点受管状态 |
| 当前配置验证 | `dvt verify` |
| 旧 profile 增量与代理诊断 | `dvt diagnose --managed`；`DIAG_*` 变量只作用于该路径 |
| 同版本、同 profile 仅改变套餐带宽 | `dvt reconfigure --port 500`；要求有效 `VERIFIED` 状态 |
| 只读升级检查 | `dvt update`；不自动升级或重启，跨发布线须显式 `--target` |
| 中断的带宽重配置恢复 | `dvt recover`；按事务状态处理，不作为任意损坏状态的修复器 |
| 参数、手动下载、离线 bundle、独立 profile | [操作指南](docs/usage.md) |
| 显式对端 probe、benchmark、TcpQuality、旧 HTB | [高级测量](docs/advanced-measurement.md) |

## 升级与回滚

**更新文件入口、迁移 managed state 和业务验收是不同步骤。** 跨版本由**旧版固定 Release**按自身状态核验和恢复，再按 checkpoint 完成两次人工重启及目标版本 apply/verify。当前操作及历史版本附录见[迁移指南](docs/migration.md)。

只有恢复条件完整、入口版本与状态相符时才执行 `dvt rollback`。普通回滚默认保留项目创建的 swap；确需清理时，先确认内存余量，再按[回滚说明](docs/usage.md#回滚)显式 purge。失败保留 state、checkpoint、备份和 ledger；不手工删状态、猜原值或用新版覆盖旧状态。

仅修改套餐带宽使用 `reconfigure --port`。参数错误在写入前被拒绝时无需回滚；其他参数变更再按对应恢复流程处理。

## 验证状态与已知限制

- 截至 2026-10-11，五台 Debian 13 VPS 已完成 rc.2 迁移和入口安装，均为 `COMPLETE / VERIFIED`、严格 x-ui 验证零警告；面板、真实代理业务及重连由用户逐台确认通过。四台采用新恢复基线、一台采用同部署历史证据，详见[五台验收记录](docs/validation.md#rc2-fleet-acceptance)。这不证明量化性能收益或长期稳定性；五台仍为 rc.2，rc.3/rc.4 尚未在这些主机上迁移或验证。
- 七组隔离客体生命周期覆盖 Debian 12/13、Ubuntu 24.04 的 x86_64/ARM64 adaptive，以及 Debian 13 x86_64 legacy；包括真实客体重启、幂等、重配置与恢复。ARM64 使用 ARM runner 上的 QEMU/TCG，不能替代特定云厂商硬件验收。
- 公共 IPv4 自动测量、临时 HTB 正常与信号中断恢复有有限 VPS 证据。完整低速扫描曾获得 15 个样本、11 个有效，整轮仍为 `INSUFFICIENT_EVIDENCE`，尚未证明可靠 policer 拐点或代理收益。
- 主要业务验证场景为原生 systemd 的 3X-UI/Xray/VLESS + REALITY + TCP；已记录基线为 3X-UI v3.4.2、Xray-core v26.6.27，其他版本需单独验证。Docker、策略路由、TProxy、网关和复杂 qdisc 的持久配置不在当前支持范围。
- 1–10000 Mbps 是参数范围；更广泛公网平台、IPv6、高速、特定大资源硬件及业务性能仍有未验收项。

固定提交、历史失败和详细边界见[平台矩阵](docs/platform-support.md)、[运行证据](docs/validation.md)和[当前发布说明](docs/releases/v0.2.0-rc.4.md)。

## 文档导航

| 主题 | 文档 |
|---|---|
| 安装、日常操作、诊断、参数和回滚 | [操作指南](docs/usage.md) |
| 升级、旧状态、历史恢复 | [迁移指南](docs/migration.md) |
| 自动选点、预算、结果解读 | [独立测量](docs/automatic-measurement.md) |
| 离线解释重传次数、暴露量及候选限制 | [解释工具](docs/measurement-explanation.md) · [独立工具发布](docs/releases/measurement-explanation-v0.1.1.md) |
| 临时 HTB 与完整恢复 | [临时实验](docs/temporary-htb.md) |
| 平台、资源、自适应缓冲 | [支持矩阵](docs/platform-support.md) |
| 高级显式测量与研究入口 | [高级测量](docs/advanced-measurement.md) |
| 设计与验证证据 | [设计范围](docs/design-scope.md) · [验证说明](docs/validation.md) |
| 固定 profile 的离线校准 | [实测校准](docs/measured-calibration.md)；不测速、不应用，暂不接受 adaptive |
| 版本变化 | [发布记录](docs/releases/) |

## 帮助、贡献与安全报告

普通使用问题、缺陷和改进建议请通过 [GitHub Issues](https://github.com/alieismy/vps-tuning/issues) 提交，提供脚本版本、系统/架构、复现步骤、退出码及脱敏日志。不要上传真实地址、凭据、订阅链接、完整代理配置或可反查报告；详见[脱敏说明](docs/usage.md#日志脱敏与安全报告)。安全问题使用 [SECURITY.md](SECURITY.md) 指定的私密报告入口。

欢迎提交有复现依据的修复和文档改进。修改 profile 时编辑 `tools/profile-template.sh.in` 与对应声明，使用生成器同步，勿单改生成文件。贡献者在 Linux 环境运行 [`bash tests/static-check.sh`](tests/static-check.sh)，实验工具变更还需相应[实验静态检查](experiments/htb-aggregate/tests/static-check.sh)；适用的 root 生命周期与平台检查见[验证说明](docs/validation.md)。

## 许可证

[MIT License](LICENSE)

<details>
<summary>旧版章节链接</summary>

- <a id="1-联网安装"></a>[1. 联网安装](README.md#安装)
- <a id="2-重启后联网验证"></a>[2. 重启后联网验证](docs/usage.md#入口不可用时的联网验证)
- <a id="3-安装-3x-ui-后严格联网验证"></a>[3. 安装 3X-UI 后严格联网验证](docs/usage.md#入口不可用时的严格代理验证)
- <a id="4-从早期-rc-版本执行只读升级检查历史-rc17-示例"></a>[4. 从早期 rc 版本执行只读升级检查（历史 rc.17 示例）](docs/migration.md#早期-rc-的历史-rc17-升级检查)
- <a id="5-联网执行注意事项"></a>[5. 联网执行注意事项](docs/usage.md#执行前准备)
- <a id="厂商已预装-bbrfq-时的处理"></a>[厂商已预装 BBR/fq 时的处理](docs/usage.md#厂商已预装-bbrfq-时的处理)
- <a id="真实环境验证基线"></a>[真实环境验证基线](docs/validation.md#真实环境验证基线截至-2026-08-07)
- <a id="1c2g--200-mbps-性能观察案例"></a>[1C2G / 200 Mbps 性能观察案例](docs/validation.md#1c2g--200-mbps-性能观察案例)
- <a id="本地使用与命令行模式"></a>[本地使用与命令行模式](docs/usage.md#本地使用与命令行模式)
- <a id="适用场景"></a>[适用场景](README.md#支持范围与前置条件)
- <a id="debian-1213-选型"></a>[Debian 12/13 选型](docs/usage.md#历史系统选型说明2026-08-04)
- <a id="按-vps-资源档选择"></a>[按 VPS 资源档选择](docs/usage.md#按-vps-资源档选择)
- <a id="虚拟化类型比发行版名称更接近内核事实"></a>[虚拟化类型比发行版名称更接近内核事实](docs/usage.md#虚拟化类型比发行版名称更接近内核事实)
- <a id="脚本选择"></a>[脚本选择](docs/usage.md#脚本选择)
- <a id="脚本会修改什么"></a>[脚本会修改什么](docs/usage.md#脚本会修改什么)
- <a id="tcp-fast-open-与-xray-的边界"></a>[TCP Fast Open 与 Xray 的边界](docs/usage.md#tcp-fast-open-与-xray-的边界)
- <a id="脚本不会修改什么"></a>[脚本不会修改什么](docs/usage.md#脚本不会修改什么)
- <a id="vps-初始化"></a>[VPS 初始化](docs/usage.md#vps-初始化)
- <a id="ufw-注意事项"></a>[UFW 注意事项](docs/usage.md#ufw-注意事项)
- <a id="下载与校验"></a>[下载与校验](docs/usage.md#下载与校验)
- <a id="使用方法"></a>[使用方法](docs/usage.md#持久配置与验证)
- <a id="1-只读预检"></a>[1. 只读预检](docs/usage.md#1-只读预检)
- <a id="2-应用"></a>[2. 应用](docs/usage.md#2-应用)
- <a id="3-重启后验证"></a>[3. 重启后验证](docs/usage.md#3-重启后验证)
- <a id="4-安装-3x-ui-后验证"></a>[4. 安装 3X-UI 后验证](docs/usage.md#4-安装-3x-ui-后验证)
- <a id="5-只读诊断"></a>[5. 只读诊断](docs/usage.md#诊断与故障定位)
- <a id="6-症状触发advisory-only-的-dvt-probe"></a>[6. 症状触发、Advisory-only 的 `dvt probe`](docs/advanced-measurement.md#显式对端的-dvt-probe)
- <a id="6a-研究专用的高级显式-iperf3-benchmark"></a>[6A. 研究专用的高级显式 iperf3 benchmark](docs/advanced-measurement.md#研究专用-benchmark)
- <a id="7-研究专用的固定-tcpquality-证据采集"></a>[7. 研究专用的固定 TcpQuality 证据采集](docs/advanced-measurement.md#固定-tcpquality-证据采集)
- <a id="8-研究专用的-htb-候选速率发现与-aba"></a>[8. 研究专用的 HTB 候选速率发现与 A/B/A](docs/advanced-measurement.md#历史-htb-reference-与-aba)
- <a id="110000-mbps-配置输入"></a>[1–10000 Mbps 配置输入](docs/usage.md#110000-mbps-配置输入)
- <a id="参数"></a>[参数](docs/usage.md#参数)
- <a id="状态与重复执行"></a>[状态与重复执行](docs/usage.md#状态与重复执行)
- <a id="从-rc16-升级到-rc19"></a>[从 rc.16 升级到 rc.19](docs/migration.md#从-rc16-升级到-rc19)
- <a id="总控已是-rc19但状态仍是-rc16"></a>[总控已是 rc.19，但状态仍是 rc.16](docs/migration.md#总控已是-rc19但状态仍是-rc16)
- <a id="从-rc15-升级到-rc16"></a>[从 rc.15 升级到 rc.16](docs/migration.md#从-rc15-升级到-rc16)
- <a id="从-rc14-升级到-rc15"></a>[从 rc.14 升级到 rc.15](docs/migration.md#从-rc14-升级到-rc15)
- <a id="从-rc13-升级到-rc14"></a>[从 rc.13 升级到 rc.14](docs/migration.md#从-rc13-升级到-rc14)
- <a id="从-rc12-升级到-rc13"></a>[从 rc.12 升级到 rc.13](docs/migration.md#从-rc12-升级到-rc13)
- <a id="从-rc11-升级到-rc12"></a>[从 rc.11 升级到 rc.12](docs/migration.md#从-rc11-升级到-rc12)
- <a id="从-rc10-升级到-rc11"></a>[从 rc.10 升级到 rc.11](docs/migration.md#从-rc10-升级到-rc11)
- <a id="从-rc8rc9-或旧-v5v6-升级到-rc10"></a>[从 rc.8/rc.9 或旧 v5/v6 升级到 rc.10](docs/migration.md#从-rc8rc9-或旧-v5v6-升级到-rc10)
- <a id="rc2-空状态恢复"></a>[rc.2 空状态恢复](docs/migration.md#rc2-空状态恢复)
- <a id="回滚"></a>[回滚](docs/usage.md#回滚)
- <a id="qdisc-边界"></a>[qdisc 边界](docs/usage.md#qdisc-边界)
- <a id="docker-边界"></a>[Docker 边界](docs/usage.md#docker-边界)
- <a id="验证与已知限制"></a>[验证与已知限制](README.md#验证状态与已知限制)
- <a id="安全问题"></a>[安全问题](docs/usage.md#日志脱敏与安全报告)

</details>
