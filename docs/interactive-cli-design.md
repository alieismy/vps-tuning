# dvt 交互式运行界面：详细设计

日期：2026-10-12（Asia/Singapore）。状态：**已批准实现**。用户于 2026-10-12 批准 D1–D3，D5 按评估结论不保留（§13）；实现由 [PR #39](https://github.com/alieismy/vps-tuning/pull/39) 合入，并随 [v0.2.0-rc.3 Pre-release](releases/v0.2.0-rc.3.md) 发布（2026-10-13）。本文规定总控 `debian-vps-tuning.sh`（安装后为 `dvt`）交互表现层的界面和行为契约。

输入与授权：

- 用户于 2026-10-12 要求参考 tcpfit 运行界面截图，并结合 [tcpfit](https://github.com/Kylin010/tcpfit) 源码，重新设计本仓库的 CLI 运行界面。本文由 `rd-design` 产出。
- 设计时 [AGENTS.md](../AGENTS.md) 的当前阶段为发布后文档收尾，并规定“需要改变运行代码或已发布制品时进入新的版本决策”。用户的版本决策是并入 `v0.2.0-rc.3`，同时让迁移器接受 `0.2.0-rc.2` 来源（D1）。此后 `AGENTS.md` 经用户批准更新为“v0.2.0-rc.3 交互界面版本交付”阶段；提交、CI、合并和发布按用户在会话中的明确授权执行。
- 项目没有为界面改版批准过 PRD。§3 的需求由用户请求和现有行为契约推导，随 D1 一并获批。

控制性交付物是本设计。实现、测试更新和终端渲染验收是独立交付物，各自的验证状态见 §11。

2026-10-13 修订：用户批准实现评审中的版本冲突引导修正，并在验证通过后发布 [v0.2.0-rc.4](releases/v0.2.0-rc.4.md)。修正已由 [PR #41](https://github.com/alieismy/vps-tuning/pull/41) 合入并发布；8 项 Linux PTY 回归通过，证据见[rc.4 验证记录](validation.md#rc4-release-validation)。§4.2 补充异版状态行为；§11 的 rc.3 记录保留历史效力，新增验证单列。版本解耦、视觉机制扩展及存量主机迁移不属于本次改动。

## 1. 结论与范围

**推荐方案：采用 tcpfit 的表现结构，即单屏框式主页、分组双语菜单、底部主机事实行，以及先集中提问、再一次确认；在此基础上做三项调整：耗时列改为副作用标签，底部状态拆成“受管记录”和“运行值”两行，本项目现有的安全契约全部保留。** 置信度为中高。结构上的收益有两方面依据：tcpfit 已公开的界面实践，以及本项目现有菜单可以直接观察到的缺陷（§2.2）。终端中的实际渲染尚未验证（§11）。

本次改动只涉及总控的表现层，包括主页、二级页、提问与输入、执行计划、确认页、结果页和无终端提示。以下内容保持不变：CLI 语法、action 集合、退出码，profile 及配套脚本的输出，JSON 和证据格式，预算、事务、所有权和迁移门禁。

不采纳 tcpfit 的以下做法：匿名运行计数遥测、框内推广链接、只凭文件是否存在判定 `Tuned`、固定文本形式的耗时估计、主操作默认 y、菜单自动选点/扫描/整形，以及每次回到菜单都清屏。

实施前提（§10.3）：当前版本契约把总控、profile 和受管状态的版本绑定在一起。即使只改界面，也会产生新版本；已受管主机要在新界面下执行受管动作，必须先走跨版本迁移。因此建议把本设计并入下一个功能版本，不单独发布。

## 2. 输入证据与现状问题

### 2.1 tcpfit 参考

2026-10-12 克隆仓库并用 `git ls-remote` 核对：`HEAD` 和 `v0.5.9` 均解引用为 `38fbf5af30daf87735f2ffbc5e0905033ee2b86e`，与 [v0.5.9 研究](tcpfit-v0.5.9-research-2026-10-05.md)的固定基线相同。本轮只阅读源码，没有运行。截图中的主页为 v0.5.9。

| 模式 | 上游位置 | 本设计处理 |
|---|---|---|
| 框式主页：标题行右对齐版本号，分隔线分组，“中文名 / 英文名 / 耗时”三列 | [T1][T1] `_row`/`_item`/`banner` | 采纳结构；第三列改为副作用标签 |
| 按 UTF-8 前导字节计算显示宽度，CJK 记 2 列，不依赖 mawk 的多字节支持 | [T2][T2] `_dispw`/`kv` | 采纳“与 locale 无关的字节级计宽”，修正字符分类（见下） |
| 框外 Machine / Network / Runs 三行 | [T1][T1] | 采纳主机行和网络行；拒绝 Runs 行 |
| 无终端时输出 `ssh -t` 和子命令示例后退出 | [T3][T3] `menu_loop` 开头 | 采纳 |
| 先集中提问，再显示一页“确认”，执行期间不再打断 | [T4][T4] `wizard` | 采纳确认页；本项目确认保持默认 N |
| 输入无效时只警告并重新显示菜单 | [T3][T3] | 采纳，并限定重试次数 |
| 一键调优跑完后退出，不回菜单，因为 `clear` 发出的 `\033[3J` 会清掉回滚缓冲 | [T3][T3] 注释 | 采纳“不清屏”和“动作执行后退出” |
| 打开菜单时在后台请求 `tcpfit.spacevps.cc`，默认开启，用于显示运行次数 | [T5][T5] | 拒绝：与本项目“未经授权不联网”的边界冲突，上一轮研究也已判定不采用 |
| 框内显示推广频道和测评链接 | [T1][T1] | 拒绝 |
| `Tuned`/`Stock` 只看 `$SYSCTL_FILE` 是否存在 | [T1][T1] | 拒绝：文件存在既不证明配置生效，也不等于受管状态 |
| “~10 min”和“约 10 分钟”是固定文本，不随主机或带宽变化 | [T1][T1]、[T4][T4] | 拒绝：改为副作用标签；只在计划工具实际算出估计值时显示 |
| 主操作“开始调优？”默认 y | [T6][T6] `confirm` 注释 | 拒绝：写入和流量确认保持默认 N |

计宽问题：上游 `_dispw` 只把 U+2500–U+257F 记为 1 列，其余 3 字节 UTF-8 序列一律记 2 列。把原函数原样复制到 Git Bash 中实测，`1–10000` 得 8，`→` 得 2，`…` 得 2。它调用 `od -An -tu1` 时没有加 `-v`，`od` 会把连续相同的 16 字节行折叠为 `*`：32 个和 64 个相同 ASCII 字符都测得 17 列。本设计的字节级计宽因此固定使用 `od -An -v -tu1`。按 Python `unicodedata`（UCD 15.1.0）查询，`–`、`→`、`…`、`·`、全部框线字符的 East Asian Width 都是 Ambiguous。按 [UAX #11][U2]，无法可靠判断上下文时，Ambiguous 字符应默认按窄字符处理。可见 tcpfit 的计宽混用了两种假设：框线字符按窄处理，其他 Ambiguous 字符按宽处理。另外，它的边框把双线角 `╔╗╚╝` 和单线 `─│` 混用（[T1][T1] `_top`/`_bot`），截图中四角与边线没有接合。本设计改为单一的窄字符假设，并限制框内可用的字符集（§6.2）。

### 2.2 本项目现状（`b48608e`，总控 0.2.0-rc.2）

| # | 问题 | 证据 | 证据层级 |
|---|---|---|---|
| P1 | 菜单 12 项平铺，没有分组，也不提示副作用；`measure`、`htb-sweep`、`report`、`migrate`、`recover` 不在菜单中 | [D1][D1] | 源码 |
| P2 | 选择操作前看不到系统、档位和受管状态，这些信息在选择之后才打印 | [D3][D3] `main` | 源码 |
| P3 | 菜单 7 `probe` 先询问 host 并打印计划，随后因为缺少 `--ledger`/`--window-id` 退出；菜单 8 `benchmark` 在没有预先设置 `BENCHMARK_HOST` 时，要等用户确认后才失败 | [D4][D4]、[D5][D5] | 源码推断，未运行 |
| P4 | 一次无效输入就以退出码 2 结束，必须重新启动 | [D1][D1] | 源码 |
| P5 | 非终端环境只输出“非交互环境必须明确指定 action。”，不给出替代命令 | [D3][D3] | 源码 |
| P6 | 菜单路径中 `apply`、`reconfigure`、`benchmark` 都有确认，`rollback` 却直接执行；profile 的 `rollback` 也没有交互确认 | [D3][D3]、[D6][D6] | 源码 |
| P7 | 没有颜色和层级；64 位 SHA-256、档位、端口和计划在同一层级平铺 | [D2][D2] | 源码 |

## 3. 需求与验收（推导，待批准）

| ID | 需求 | 验收 |
|---|---|---|
| UI-01 | 无 action 进入交互模式时，主页在同一屏内同时显示版本、分组菜单、每项的副作用、主机事实和受管记录 | 在 80×24 终端中，主页与提示行总高度不超过 24 行（§4.1 为 16 行框加 6 行框外内容） |
| UI-02 | 每个菜单项都标明副作用：只读、写入、重启、联网、流量或子菜单 | 标签与 §4.1 映射表一致；颜色只作辅助，去掉颜色后语义不丢失 |
| UI-03 | 菜单只直接分派能在菜单内收集齐输入的 action；需要额外参数的 action 列为命令参考，不在途中失败 | P3 的两条路径不再从主菜单分派；静态测试覆盖每个键的映射 |
| UI-04 | 写入、流量和回滚确认默认 N；不新增跳过确认的开关 | 菜单路径的 `rollback` 增加确认；空回车和 EOF 都视为否 |
| UI-05 | 无效输入重新提示，最多 3 次；第 3 次仍无效时，以原退出码 2 和原文案退出 | 测试覆盖：一次无效后接有效输入；连续 3 次无效 |
| UI-06 | 主页采集主机事实时不联网，不写文件，不要求 root，不使用 `die` | 非 root 环境和不支持的平台都能显示主页，并说明哪些项可用 |
| UI-07 | 显式 action 在非 TTY 环境下的输出与退出码逐字节不变 | 用现行输出作 golden 比对 |
| UI-08 | 支持 `NO_COLOR`、`DVT_ASCII=1`、`TERM=dumb/linux` 和窄终端降级 | §6 的四种模式都有渲染测试 |
| UI-09 | 不清屏，不移动光标，不使用备用屏幕 | 静态检查：渲染代码只使用 SGR 颜色序列 |
| UI-10 | 不新增运行依赖或发布资产 | 只使用现有的 bash、coreutils、awk、procps、iproute2 和 jq；安装清单的文件集合不变 |

## 4. 界面设计

下列示意图由脚本按“Ambiguous 字符记 1 列”生成，并已核对每个框行的显示宽度都等于 66 列。示意图中的主机值是示例。

### 4.1 主页

```text
┌─ dvt  Debian VPS Tuning ───────────────────────── v0.2.0-rc.3 ─┐
├─ 配置 Configure ───────────────────────────────────────────────┤
│  1. 安全引导   Guided: preflight, then confirm      预检+确认  │
│  2. 只读预检   Preflight only                            只读  │
│  3. 应用配置   Apply persistent tuning              写入 重启  │
│  4. 修改带宽   Reconfigure provider port speed           写入  │
├─ 检查 Inspect ─────────────────────────────────────────────────┤
│  5. 验证配置   Verify managed configuration              只读  │
│  6. 查看状态   Status and recorded state                 只读  │
│  7. 能力诊断   Diagnose (no profile needed)              只读  │
├─ 维护 Maintain ────────────────────────────────────────────────┤
│  8. 检查升级   Update check and handoff plan        只读 联网  │
│  9. 回滚       Rollback managed changes                  写入  │
│  a. 高级与测量 Advanced and measurement                子菜单  │
│  0. 退出       Exit                                            │
└────────────────────────────────────────────────────────────────┘
  主机     Debian GNU/Linux 13 (trixie) · x86_64 · 1 vCPU · 961 MiB
  档位     debian13-1c1g（1C1GB）
  受管记录 VERIFIED · 0.2.0-rc.3 · 200 Mbps · 更新 2026-10-11T03:12:09Z
  运行值   6.12.48+deb13-amd64 · cc=bbr · default_qdisc=fq · eth0 root=fq

请选择 / Select [0-9,a] [6]:
```

布局规则：

- 框的内宽固定为 64 列，加上左右边框共 66 列。分组标题嵌在分隔线中，不额外占行。条目格式依次为：2 空格、键、`. `、补齐到 10 列的中文名、补齐到 35 列的英文名、右对齐到 10 列的标签、2 空格。
- 框内不放任何动态值，只有版本号例外，而版本号是总控内的 ASCII 常量。主机事实一律放在框外，避免系统名、内核串等外部字符串破坏右边框。
- 保留双语标签有两个理由：已有英文 README 读者；VNC/救援控制台（`TERM=linux`）通常无法显示 CJK，此时英文列仍然可读。后一点是推断，置信度中高，需要在 §11 的终端矩阵中确认。

标签词表（不新增其他词）：

| 标签 | 含义 | 颜色 |
|---|---|---|
| 只读 | 不改系统配置，不产生测试流量 | 绿 |
| 预检+确认 | 先执行只读 preflight，用户确认后才写入 | 绿 |
| 写入 | 修改受管配置或系统状态 | 黄 |
| 重启 | 需要重启才能完成全部验证 | 黄 |
| 联网 | 访问 GitHub Release，不产生测试流量 | 青 |
| 流量 | 产生按预算计量的测试流量 | 品红 |
| 子菜单 | 进入下一级页面，由该页逐项标注 | 默认 |

条目与分派：

| 键 | action | 菜单内收集的输入 | 需要 root | 菜单确认 |
|---|---|---|---|---|
| 1 | `guided` | 端口带宽 | 是 | preflight 之后显示确认页 [y/N]（现有） |
| 2 | `preflight` | 端口带宽 | 是 | 无（只读） |
| 3 | `apply` | 端口带宽；已有状态时沿用（现有规则） | 是 | 确认页 [y/N]（现有） |
| 4 | `reconfigure` | 端口带宽 | 是 | 确认页 [y/N]（现有） |
| 5 | `verify` | — | 是 | 无 |
| 6 | `status` | — | 是 | 无 |
| 7 | `diagnose` | — | 否；需要 python3 | 无 |
| 8 | `update` | — | 是 | 无（只读、联网） |
| 9 | `rollback` | — | 是 | **新增**确认页 [y/N]（§4.4） |
| a | 二级页 | — | — | — |
| 0 | 退出 | — | — | — |

### 4.2 底部事实行与默认项

| 行 | 来源 | 显示校验 | 不可用时显示 |
|---|---|---|---|
| 主机 | 现有 `detect_profile_from` 读取的 `PRETTY_NAME`、`uname -m`、`nproc`、`MemTotal` | 系统名去除控制字符，超长时截断并加 `...`；其余字段按现有正则校验 | `未知` |
| 档位 | `detect_profile_from` 的返回码与输出 | 档位 ID 必须属于 `profile_metadata` 的枚举 | 不支持的原因。文案由 `detect_environment` 的返回码映射提供，两处共用同一个函数，不各写一份 |
| 受管记录 | `state.json` 的 `.state`、`.script_version`、`.network.port_speed_mbps`、`.timestamps.last_update` | 状态值属于已知集合；版本号、端口和时间分别按 semver、整数和 ISO-8601 校验 | `无（UNMANAGED）`、`需 root 读取`、`需 jq 解析` 或 `无法解析，请运行 dvt status` |
| 运行值 | `uname -r`；从 `/proc/sys` 读取拥塞控制和 `default_qdisc`；默认路由接口（先取 IPv4 默认路由，没有时取 IPv6）的根 qdisc kind，取自 `tc qdisc show` 的 root 行。字段与 profile 的 `tc -j … \| jq` 写法（[D11][D11]）相同，但不依赖 jq，以便非 root 主页也能显示 | 接口名匹配 `^[A-Za-z0-9._@-]{1,15}$`，kind 匹配 `^[a-z_]{1,16}$` | 对应字段显示 `不可用` |

“受管记录”表示上次写入 `state.json` 时的状态，“运行值”表示当前读数。两者都不等于本次 `verify` 的结论，界面上也不把它们合并成“已调优”或“健康”这类词。

受管记录的状态值决定附加提示和默认项。默认项必须是首个效果为只读的动作：

| 情形 | 附加提示（框外 `[!]` 行） | 默认键 |
|---|---|---|
| 无状态 | — | 1 |
| `APPLIED` | 重启后运行验证 | 5 |
| `VERIFIED` | — | 6 |
| `DEGRADED`、`ROLLBACK_PENDING`、`RECONFIGURING`、`APPLYING`、`PREPARED`、`SWAP_RETAINED`、无法解析 | 普通 verify/rollback/apply 可能拒绝执行；先查看状态，再按 [使用说明](usage.md) 处理 | 6 |
| 非 root | 当前用户不是 root，只有 7 可用；a 可查看命令参考 | 7 |
| 平台不支持 | 档位行显示不支持的原因；只有 7 可用，a 可查看命令参考 | 7 |
| 入口与已读取的受管版本不一致（rc.4 修正） | 提示版本不一致；1–6、9 和高级页 HTB 不可用，受管操作使用来源版本入口；8 只读联网检查仍可明确选择 | 7 |

当前状态下不可用的条目照常显示，但标签替换为 `不可用`。选中时说明原因并重新提示，不进入 `need_root` 或 `detect_environment` 的 `die` 路径。

优先级为权限/平台、版本不一致、状态默认项。版本不一致时不把 `VERIFIED` 记录着为绿色；入口版本在标题、受管版本在记录行显示。默认 7 只触发本地诊断，避免空回车自动联网。版本字段不可读取时沿用既有降级路径，不推断版本兼容；所有真实 action 仍执行原有状态与所有权检查。

### 4.3 二级页与命令参考

```text
┌─ 高级与测量 Advanced ──────────────────────────── v0.2.0-rc.3 ─┐
│  1. HTB 实验   HTB trial: Debian 13 / 200 Mbps         子菜单  │
│  0. 返回       Back to main menu                               │
└────────────────────────────────────────────────────────────────┘
  命令参考：以下操作需要参数，请在命令行运行。
  此处只列主要参数；完整参数见 dvt --help 与 docs/usage.md。
  只读      dvt measure --rate-cap N --plan-only
  流量      dvt measure --rate-cap N --ledger PATH --window-id ID ...
  写入 流量 dvt htb-sweep --interface IF --lower N --upper N ...
  只读      dvt report --input-dir PATH
  流量      dvt probe --host HOST --ledger PATH --window-id ID
  流量      BENCHMARK_HOST=HOST dvt benchmark
  写入 重启 dvt migrate prepare --checkpoint /absolute/new/path
  写入      dvt recover
  只读      dvt diagnose --managed
```

- 选 1 时分派现有的 `htb` 包装器，进入它自带的阶段菜单（[D12][D12]），不改变它的门禁。非 root 或平台不支持时该项标为 `不可用`。
- 原设计中的“2. 测量预览”不保留（D5）：`--plan-only` 的输出是原始 JSON，菜单又无法收集真实测量所需的 ledger、window ID 和输出目录，保留它只增加代码和测试。该入口改为命令参考的第一行。
- 命令参考只展示命令，不执行。标签放在行首，使最长一行不超过 80 列；只列主要参数，完整参数和边界以 `--help` 和对应文档为准，避免两处内容漂移。

### 4.4 提问、确认与执行计划

端口带宽提问（替换现有的 `choose_port_interactively` 文本，选项和取值不变）：

```text
▸ 服务商端口带宽（用于推导 socket 缓冲上限，不产生流量）
    1. 100 Mbps    2. 200 Mbps（默认）    3. 500 Mbps
    4. 1000 Mbps   5. 自定义 1-10000
请选择 [2]:
```

确认页由两部分组成：一组 kv 行，加上原有的确认问句。kv 行只列总控自己掌握的事实，写入范围以 profile 输出为准，总控不另写一份写入清单：

```text
── 确认写入 ─────────────────────────────────────────────
  操作       apply（写入持久配置）
  档位       debian13-1c1g  Debian 13 / 1 vCPU / 1 GiB
  端口带宽   200 Mbps
  脚本       debian13-1c1g-vps-tuning.sh（来源：local）
  SHA-256    <完整 64 位十六进制>
  写入范围   以上方 preflight 输出为准；若其报告可迁移的厂商 fq/bbr 基线，
             apply 会先完整备份 /etc/sysctl.conf 再迁移对应定义
  完成条件   apply 成功后重启，重新登录后运行 dvt verify
preflight 已通过。是否执行 apply？[y/N]:
```

上例是 `guided` 在 preflight 之后的确认页。菜单 3 直接 apply 时没有先运行 preflight，因此“写入范围”一行改为“由 profile 在执行时判定并输出；只读查看请改用菜单 1 或 2”，问句沿用现有的“apply 会写入系统配置。是否继续？[y/N]”。菜单 4 的确认页只列两行：操作 `reconfigure（修改受管端口带宽）`，以及端口带宽“旧值 Mbps → 新值 Mbps”；问句沿用现有的重配置问句。

菜单路径中 `rollback` 新增的确认页，其文案依据 [使用说明](usage.md) 中关于普通 rollback 和带宽重配置的规则：

```text
── 确认回滚 ─────────────────────────────────────────────
  操作       rollback（撤销本项目受管配置）
  注意       普通 rollback 保留已创建的 swap；只改端口带宽请用 4. 修改带宽
是否执行 rollback？[y/N]:
```

执行计划：TTY 模式下，`print_environment_summary` 和 `print_execution_plan` 的内容改用分组 kv 呈现，字段不得少于现有输出（[D2][D2]）。非 TTY 模式保留现有文本（UI-07）。

### 4.5 结果页与下一步

结果页只在菜单分派的动作结束后、且处于 TTY 样式模式时显示。CLI 直接调用时不追加结果页，退出码就是结果。动作分派前的门禁失败（如 `need_root`、环境检测、状态读取）不显示结果页，只保留原有的 `[x]` 行和退出码。

```text
── 结果 ─────────────────────────────────────────────────
  apply      成功（退出码 0）
  下一步     若上方显示“应用完成”，重启主机，重新登录后运行 dvt verify
```

`apply` 和 `guided` 的“下一步”带有前置条件“若上方显示‘应用完成’”。原因是 profile 可能在没有写入的情况下以 0 退出，总控不解析 profile 输出，无法单独确认写入已经发生。

确认页拒绝（含确认处 EOF）时，结果页不显示“成功”，而是：

```text
── 结果 ─────────────────────────────────────────────────
  apply      未执行（确认时已取消）
  下一步     没有写入；需要时重新运行 dvt
```

“下一步”文案只复述已有文档或该动作自身输出中的指引，不新增操作建议：

| 动作与结果 | 下一步 | 依据 |
|---|---|---|
| `guided` 已 apply、`apply` 成功 | 若上方显示“应用完成”，重启主机，重新登录后运行 `dvt verify` | [使用说明](usage.md) §持久配置与验证 |
| `guided`、`apply`、`reconfigure`、`rollback` 确认时拒绝 | 显示“未执行（确认时已取消）”；下一步为“没有写入；需要时重新运行 dvt” | 现有“已停止；没有执行 …。” |
| `preflight` 成功 | 确认写入范围后运行 `dvt apply --port N`，或在菜单中选 3 | 同上 |
| `reconfigure` 成功 | 运行 `dvt status` 查看新的端口带宽记录 | 指针，不作新判断 |
| `update` 成功 | 按上方计划和 [迁移指南](migration.md) 执行；`update` 本身没有改动受管配置 | `usage()` 中关于 update 只读的说明 |
| 其他动作成功 | 不显示下一步 | — |
| 任意失败 | 保存上方完整输出，并按其中 `[x]` 行处理；不要用重复 apply 或手工编辑 `state.json` 代替恢复流程 | [使用说明](usage.md) 重配置一节 |

退出码含义只对总控和 profile 动作解释：2 表示用法或输入错误，3 表示环境不支持，4 表示状态或所有权冲突，5 表示验证失败，6 表示回滚不完整，10 表示下载失败，11 表示完整性校验失败，130/143 表示中断或终止（[D10][D10]）。配套脚本 `probe`、`htb`、`migrate` 和测量工具对多种失败都返回 2，因此只显示数值，不作解释。

### 4.6 无终端提示

第一行保留现有文案，其后的行是新增的指引；全部写入 stderr，退出码仍为 2：

```text
[x] 非交互环境必须明确指定 action。
    远程执行请分配终端：ssh -t <host> dvt
    自动化请直接指定 action，例如：dvt preflight --port 200；dvt verify
    全部 action：dvt --help
```

## 5. 交互流程与状态

```text
入口 ─ 有 action ──────────────────────────────→ 现有 main 流程（不变）
  └─ 无 action ─ 非 TTY ─→ §4.6 提示，exit 2
                └─ TTY ──→ 采集主页事实（不致命）→ 主页
                            ├─ 0 / EOF ─→ exit 0（未执行任何操作）
                            ├─ a ──────→ 二级页 ─ 0 → 主页（重绘，不清屏）
                            ├─ 无效 ───→ 重新提示（≤3 次，之后 exit 2）
                            └─ 有效键 ─→ ACTION、ACTION_FROM_MENU=1
                                          → 现有 main 流程 → 结果页 → exit rc
```

- 交互是一次性的：一个动作执行完就退出，不回到主页。菜单内部只允许在主页和二级页之间往返，此时还没有执行任何动作。理由见 §12。
- 进入现有 `main` 流程之后，`need_root`、`detect_environment`、`read_existing_state`、`select_port_speed`、`resolve_profile_script` 和 `dispatch_action` 的顺序与门禁保持不变。主页采集的事实只用于显示，不能替代这些步骤自己的检测结果。
- 结果页由 `EXIT` trap（`on_exit`）渲染，`dispatch_action` 不捕获退出码。`main` 在调用 `dispatch_action`（以及独立测量的 `python3` 分派）之前设置 `RESULT_PENDING="$ACTION_FROM_MENU"`；`on_exit` 读取 `$?`，在 `RESULT_PENDING=1` 时渲染结果页，然后执行原有 `cleanup`，进程以原退出码退出。不采用 `if run_profile …; then …; else rc=$?; fi` 的原因：bash 在 `if`、`||`、`&&` 条件上下文中会对整个被调函数关闭 `errexit`，`run_update` 一类多步函数在中间步骤失败后会继续执行，并可能以 0 返回。trap 方案让现有 `errexit` 下的退出码语义保持完全不变。
- 并发：主页只读。两个 `dvt` 同时进入受管动作时，仍由 profile 现有的锁串行执行；总控不新增锁。

## 6. 渲染契约

### 6.1 模式判定

| 条件 | 结果 |
|---|---|
| `[ -t 0 ] && [ -t 1 ]` | 交互可用；判定与现有 `is_interactive_terminal` 相同 |
| stdout 是 TTY | 样式模式（`UI_STYLED=1`）：分组 summary/plan、kv 确认页和结果页。stdout 不是 TTY 时保留现有文本（UI-07） |
| stdout 是 TTY，`NO_COLOR` 未设置或为空，`TERM` 不为空也不是 `dumb` | stdout 使用颜色；stderr 按 `-t 2` 单独判断。按 [NO_COLOR 约定][U1]，只要该变量非空就禁用颜色 |
| `DVT_ASCII` 非空，或 `TERM` 为 `linux`、`dumb` 或空 | 框线改用 `+ - \|`，`▸` 改为 `>`，`──` 规则线改为 `--` |
| 终端列数 < 66，或 `TERM` 为 `linux`、`dumb` 或空 | 使用开放布局：不画左右边框；列数 < 62 时省略英文列 |

列数优先用 `stty size` 从控制终端读取；读取失败时按 80 列处理。不依赖 `tput`。

### 6.2 字符集与计宽

框内行只允许出现以下字符：ASCII 可打印字符（U+0020–U+007E）、CJK 统一表意文字（U+4E00–U+9FFF）、CJK 符号和标点（U+3000–U+303F）、全角形式（U+FF01–U+FF60），以及八个单线框线字符 `─│┌┐└┘├┤`。`·`、`–`、`—`、`…`、`→` 等其他 Ambiguous 字符，以及 emoji、制表符和控制字符，都禁止进入框内。框外文本不需要逐列对齐，不受此限。

计宽函数按字节判断，不依赖 locale 或 awk 的多字节支持：

- 0x20–0x7E 记 1 列。
- `E2 94 xx` 记 1 列（框线字符）。
- `E3 80 xx`、`E4 B8 80`–`E9 BF BF`、`EF BC 81`–`EF BD A0` 记 2 列。
- 其他任何序列都视为违反契约，由测试拦截，不在运行时猜测宽度。

统一按窄字符处理 Ambiguous 字符（[UAX #11][U2]）。终端把 Ambiguous 字符设为双宽时，框线会错位，这时用 `DVT_ASCII=1` 规避。该环境变量需要写入使用说明。

### 6.3 颜色

只使用 SGR 序列，即 `ESC [ … m`。可用的语义色包括：粗体（标题、键号）、绿、黄、青、品红、红（失败、`DEGRADED` 一类状态、`[x]`）和暗色（分隔线、默认值提示）。颜色只作辅助，所有语义都有对应的文字。外部字符串必须先通过 §4.2 的校验，才能放进带颜色的片段。

## 7. 内部接口

全部实现为 `debian-vps-tuning.sh` 内的函数，不新增文件，安装清单的文件集合不变。

| 函数 | 输入 | 输出与不变量 | 失败行为 |
|---|---|---|---|
| `ui_init` | 环境变量与终端 | 设置 `UI_STYLED`、`UI_COLOR_OUT`、`UI_COLOR_ERR`、`UI_ASCII`、`UI_COLS`、`UI_LAYOUT`、`UI_EN`；整个进程内只调用一次 | 无失败；无法判断时取最保守的模式 |
| `ui_width STR` | 一行框内文本 | 按 §6.2 严格计宽，输出显示列数；供测试校验契约 | 出现禁止字符时返回非零 |
| `ui_measure VAR STR` | 变量名、已知合法的文本 | 运行时计宽：在 `LC_ALL=C` 下按字节计数，不派生子进程；只用于已经过白名单校验或由总控自身生成的文本 | — |
| `ui_rule`、`ui_item`、`ui_kv` | 标签、文本、标签名 | 只写 stdout；框行宽度恒为 66 | — |
| `home_facts_collect` | 无 | 设置 `HOME_*` 变量；不联网、不写入、不调用 `die`，单个字段失败时显示占位 | 不会导致整体失败 |
| `render_home`、`render_advanced` | `HOME_*` | 渲染 §4.1 和 §4.3 | — |
| `read_choice PROMPT REGEX DEFAULT` | 提示、允许输入的正则、默认值 | 从 stdin 读取；空输入取默认值，结果写入 `UI_CHOICE`；不回显输入原文。返回 0 表示有效，1 表示 EOF，2 表示无效 | 不计次；由调用方计数，第 3 次无效时以退出码 2 结束 |
| `confirm_answer PROMPT` | 问句 | 返回 0 表示确认，1 表示拒绝；只有 `y`、`Y`、`yes`、`YES` 算确认（沿用现有规则） | EOF 视为拒绝 |
| `confirm_write_page guided\|apply` 及 `dispatch_action` 内的确认页 | 总控已掌握的事实 | 只在 `UI_STYLED=1` 时渲染 kv 确认页；问句仍由 `confirm_answer` 读取 | — |
| `render_result RC` | 退出码；`ACTION`、`DISPATCH_NOTE` | 由 `on_exit` 在 `RESULT_PENDING=1` 时调用，只在 `UI_STYLED=1` 时输出 | 渲染失败不改变退出码 |

现有的 `choose_action_interactively` 和 `choose_port_interactively` 保留函数名和全局变量契约（`ACTION`、`ACTION_FROM_MENU`、`PORT_SPEED_MBPS_SELECTED`），方便测试继续调用。

## 8. 安全与输入校验

- 信任边界：`/etc/os-release`、`state.json`、`uname`、`sysctl`、`ip` 和 `tc` 的输出，都是进入渲染层的外部数据。只有通过 §4.2 的白名单校验后才能显示，否则显示占位。这样可以避免终端转义序列注入和边框错位。
- 主页不联网，不发遥测，不写文件，不创建目录。非 root 用户读取不到 `0700` 状态目录时，显示 `需 root 读取`，不尝试提权。
- 确认契约：写入、流量和回滚确认一律默认 N。没有 `--yes` 一类绕过菜单确认的入口，`DVT_ASCII`、`NO_COLOR` 只影响呈现。读取输入前不清空 tty 缓冲：tcpfit 的注释表明，清空会吞掉通过管道传入的合法输入（[T7][T7]），而默认 N 已经足以让误按的回车无害。
- 菜单项的可用性提示只影响显示；需要 root、平台不支持等真正的拒绝，仍由现有门禁执行。

## 9. 错误处理

| 情形 | 行为 | 退出码 |
|---|---|---|
| 菜单或端口带宽输入无效 | 显示 `[!]` 和允许的范围，重新提示；不回显输入原文 | 第 3 次仍无效时为 2 |
| 菜单或端口带宽提问处读到 EOF，或在主页选择 0 | 输出“未执行任何操作” | 0 |
| 确认处读到 EOF | 视为拒绝，输出现有的“已停止；没有…”文案；菜单路径的结果页显示“未执行（确认时已取消）” | 0 |
| 主页事实采集失败 | 对应字段显示占位，主页照常渲染 | — |
| 选中当前不可用的条目 | 说明原因并重新提示 | — |
| 动作失败 | 保留子进程原有的 stderr 输出；菜单路径显示结果页 | 原值 |
| SIGINT、SIGTERM | 沿用现有 trap | 130、143 |

与 `b48608e` 相比，EOF 处理有两处变化：旧版主菜单和端口带宽提问的 `read` 在 `errexit` 下读到 EOF 会以退出码 1 结束；旧版菜单路径的 apply 和 reconfigure 确认同样以 1 结束，只有 `guided` 的确认（在 `if` 条件中调用）已按拒绝处理并返回 0。本版统一为“EOF 等于不执行”，退出码 0。旧版端口带宽输入无效时立即以 2 结束，本版改为最多 3 次重新提示。

## 10. 兼容性与变更范围

### 10.1 保持不变

- CLI 语法、action 集合，以及 `--port`、`--target`、`--help`、`--version`。
- 全部退出码的定义；动作本身的退出码（交互提问处读到 EOF 的例外见 §10.2）；显式 action 在非 TTY 下的 stdout 和 stderr 文本。
- profile、配套脚本和测量工具的输出与证据格式；`install.sh` 安装完成后打开菜单的行为。

### 10.2 有意改变

| 变化 | 影响 |
|---|---|
| 菜单键位重排，默认项随状态变化 | 需要改写 `tests/controller-check.sh` 中的菜单断言（[D9][D9]）。README 和使用说明不引用菜单编号（已检索 `README.md`、`README.en-US.md`、`docs/usage.md`、`docs/migration.md`、`docs/platform-support.md`），因此不会产生文档编号漂移 |
| `probe`、`benchmark` 不再从主菜单分派 | 已预设 `BENCHMARK_HOST` 的菜单用户要改用 CLI；CLI 行为不变 |
| 菜单路径的 `rollback` 增加确认 | 菜单用户多一次确认；CLI 不变 |
| 无效输入改为重新提示 | 改善交互；连续 3 次无效时仍以退出码 2 退出 |
| 菜单、端口带宽和确认处读到 EOF 一律以 0 退出（旧版菜单路径为 1） | 依赖旧退出码 1 的外部包装需调整。在交互终端中不带 `--port` 运行 CLI `guided`、`preflight`、`apply` 时也会进入端口带宽提问，同样受影响；非交互 CLI 不经过这些提问（§9） |
| 菜单分派的动作结束后追加结果页 | 只在 stdout 为 TTY 时出现；退出码不变 |
| 新增 `DVT_ASCII`，支持 `NO_COLOR` | 需要更新 `usage()` 和 [使用说明](usage.md) |

### 10.3 版本耦合

总控要求 profile 的 `SCRIPT_VERSION` 与自身版本一致（[D7][D7]）。profile 拒绝其他版本写入的受管状态：`status`/`verify` 经过的状态校验会以退出码 4 停止并指向 `update`（[D8][D8]），`apply` 要求先 rollback（[D13][D13]）。修改总控还会改变 `SHA256SUMS` 和 `install.sh` 内置的摘要。

由此推断（置信度高）：只改界面的版本也必须重新生成全部 profile 并发布新的 Release。已受管主机想在新界面下执行 `status`、`apply` 等受管动作，必须先完成跨版本迁移，包括 prepare、rollback、两次重启门禁、apply 和 verify。仅为界面承担这项迁移成本不划算，所以建议把本设计并入下一个功能版本。用户的决定是并入 `v0.2.0-rc.3`，并让该版本的只读 update-preflight 和迁移器接受 `0.2.0-rc.2` 来源，`0.1.0-rc.1`–`rc.19` 来源与 TCP 基线恢复路径保留（D1）。

另一种做法是把总控界面版本与 profile 版本解耦。这属于架构变更，不在本设计范围内。

## 11. 验证设计

| 层级 | 方法 | 通过判据 |
|---|---|---|
| 静态 | 在现有 `tests/controller-check.sh` 中增加用例：每个键的映射；默认项随状态变化；无效输入重提示及第 3 次退出；EOF；`NO_COLOR` 下输出不含 ESC；ASCII 与开放布局；所有框行的 `ui_width` 等于 66；框内字符集白名单 | Windows Git Bash 与 Linux CI 均通过 |
| 兼容 | 显式 action 在非 TTY 下的 summary/plan 输出与本版 golden 逐字节一致 | 无差异 |
| 规范 | 固定版本 ShellCheck（现有 CI） | 通过 |
| 渲染 | 人工终端矩阵：Windows Terminal、macOS Terminal 或 iTerm2、PuTTY 或 Xshell 中至少一种、一种移动 SSH 客户端、一种 VNC/救援控制台；每种分别检查 Ambiguous 设为窄和设为宽的情况 | 窄设置下边框对齐；宽设置下 `DVT_ASCII=1` 能对齐；截图存入验收记录 |
| 运行 | 获得授权后，在一台测试 VPS 上完成菜单路径的 guided、verify 和 rollback | 退出码和状态转换与 CLI 路径一致 |

静态测试只能证明字符串宽度契约成立，不能证明实际终端的渲染效果。在拿到渲染层级的证据之前，不得声称“各终端对齐”。

实现状态（2026-10-13，随 `v0.2.0-rc.3` 发布）：

| 层级 | 状态 |
|---|---|
| 静态 | 已实现于 `tests/controller-check.sh`，并在 `tests/static-check.sh` 中增加 SGR-only 检查与 rc.2 状态接受/拒绝用例；Windows Git Bash 与 Linux CI 均通过（[验证说明](validation.md#rc3-release-validation)） |
| 兼容 | 非 TTY summary/plan golden 已纳入静态用例并通过 |
| 规范 | ShellCheck 0.11.0 在 CI 中首轮报告三项发现，修复后通过 |
| 渲染 | 未执行 |
| 运行 | `tests/installer-check.sh`、`tests/rc18-check.sh` 在 Linux CI 以 root 通过；七组隔离客体生命周期通过（只走 CLI，不覆盖菜单路径）。真实 VPS 上的菜单路径未授权、未执行 |

rc.4 补充验证：`tests/controller-check.sh` 覆盖异版默认项、受管菜单拒绝与显式 update；`tests/test_update_preflight.py` 覆盖 rc.2/rc.3 只读兼容和普通动作拒绝；`tests/test_interactive_menu.py` 使用真实 Linux controlling PTY 执行总控 `main`，只在系统执行边界使用测试替身。Windows 明确跳过 PTY，Linux 实跑结果见[验证说明](validation.md#rc4-release-validation)。PTY 验证不替代人工终端矩阵、真实 profile 写入或真实 VPS 菜单验收。

## 12. 被否决的备选

| 备选 | 否决理由 |
|---|---|
| 照搬 tcpfit 的循环菜单（动作执行完回到主页） | 动作改变状态后需要重新采集和重绘；回主页时清屏会冲掉结果（tcpfit 自己为此改为一键调优后退出）；循环中还需要处理残留按键（tcpfit 为此加了 `drain_tty`）。一次性退出最简单，也与现有测试和自动化习惯一致 |
| 无边框的纯列表 | 对计宽错误最稳健，但与用户给出的参考界面差距大。本设计保留它作为降级布局 |
| 引入 `dialog`/`whiptail` 等 TUI | 新增依赖，最小化镜像可能没有；还会接管终端和回滚缓冲，不符合 UI-09 和 UI-10 |
| 改用 Python 渲染 | 受管路径目前不依赖 Python（只有 diagnose 和测量依赖）；为界面新增依赖不符合 UI-10 |
| 全面 i18n 框架 | 超出范围；双语只用于主页的静态标签 |

## 13. 未决事项

| ID | 事项 | 依赖 | 验证动作 | 负责人 / 状态 |
|---|---|---|---|---|
| D1 | 是否批准实现，并入哪个版本 | §10.3 的迁移成本 | 用户决策 | 用户 / 已决定（2026-10-12）：批准，并入 `v0.2.0-rc.3` |
| D2 | 是否采用双语标签（推荐采用） | 无 | 渲染矩阵中确认 VNC 控制台的可读性 | 用户 / 已决定（2026-10-12）：采用；VNC 可读性待渲染矩阵确认 |
| D3 | 是否采用随状态变化的默认项（推荐采用） | 无 | 静态测试 | 用户 / 已决定（2026-10-12）：采用；静态用例已实现 |
| D4 | 是否把 profile 和配套脚本的 `[+] [!] [x]` 前缀统一着色 | 需要改模板、重新生成全部 profile | 延后。重新纳入条件：用户要求统一全部输出 | 未分配 |
| D5 | 二级页是否保留“测量预览” | 无 | 按用户授权由设计方评估 | 已决定（2026-10-12）：不保留，见 §4.3 |
| D6 | rc.3 接受哪些迁移来源 | D1 | 静态用例覆盖接受与拒绝 | 用户 / 已决定（2026-10-12）：`0.2.0-rc.2` 与 `0.1.0-rc.1`–`rc.19`，保留 TCP 基线恢复路径，门禁不放宽 |
| D7 | `0.2.0-rc.2` 的 Ubuntu 24.04 主机，以及端口带宽不在迁移器 100–1000 Mbps 范围内的主机，无法用 rc.3 迁移器迁移 | 迁移器的 profile-id 与端口范围契约 | 若要支持，需要单独的迁移设计和 root 测试 | 未分配 / 已知限制 |
| D8 | rc.2 版恢复工具生成的 TCP 基线归档只被 rc.2 迁移器接受 | 恢复归档的版本绑定 | 这类主机须先完成到 rc.2 的迁移，再迁移到 rc.3 | 未分配 / 已知限制 |

## 14. 来源

源码链接固定到对应提交；在线规范的检查日期为 2026-10-12。

[T1]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3746-L3798
[T2]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L81-L96
[T3]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L4374-L4461
[T4]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3804-L4080
[T5]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1018-L1066
[T6]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3724-L3744
[T7]: https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3708-L3722
[D1]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/debian-vps-tuning.sh#L285-L353
[D2]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/debian-vps-tuning.sh#L695-L737
[D3]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/debian-vps-tuning.sh#L812-L910
[D4]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/dvt-probe.sh#L163-L198
[D5]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/tools/profile-template.sh.in#L2915-L2936
[D6]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/tools/profile-template.sh.in#L3267-L3270
[D7]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/debian-vps-tuning.sh#L443-L447
[D8]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/tools/profile-template.sh.in#L395-L409
[D9]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/tests/controller-check.sh#L214-L240
[D10]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/tools/profile-template.sh.in#L92-L96
[D11]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/tools/profile-template.sh.in#L1354
[D12]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/dvt-htb.sh#L218-L244
[D13]: https://github.com/alieismy/debian-vps-tuning/blob/b48608ec4048e4cb74bd9276e02d1a44a22850ce/tools/profile-template.sh.in#L2614-L2615
[U1]: https://no-color.org/
[U2]: https://www.unicode.org/reports/tr11/

- tcpfit：[v0.5.9 Release](https://github.com/Kylin010/tcpfit/releases/tag/v0.5.9)；源码锚点 T1–T7；用户提供的 v0.5.9 运行界面截图（本地文件，未纳入仓库）。
- 本项目：源码锚点 D1–D13，固定到 `b48608e`。
- 规范：[NO_COLOR][U1]（“present and not an empty string” 时禁用颜色）；[UAX #11][U2]（Unicode 18.0.0，Revision 46：无法可靠判断上下文时，Ambiguous 字符默认按窄字符处理）；字符宽度分类由 Python `unicodedata`（UCD 15.1.0）本地查询。
