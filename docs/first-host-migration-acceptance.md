# 首台 Lightsail VPS 正式候选迁移验收方案

日期：2026-11-26（Asia/Singapore）。状态：用户已授权首台 AWS Lightsail 的 vps-tuning 升级及自身验证；执行范围按下节限定。两次重启已由用户手动执行，DVT升级及技术验证已通过，见[实测记录](validation.md#stable-020-first-host)。客户端业务与正常使用观察未执行，公开发布未授权。

## 本次执行范围（后续用户确认）

用户将本次实机工作收窄为 vps-tuning 升级与验证，并明确接受其既有受管系统配置（含 x-ui 的 LimitNOFILE 片段）及只读服务核验。代理不修改代理配置、数据库、证书或客户端，不主动启停业务服务，不执行应用备份、客户端业务测试或云恢复；DVT 自身的 fq 服务、journald 配置及系统参数操作仍属于原有调优流程。整机重启会中断业务，不能解释为业务零影响。

用户确认迁移前 Lightsail 手动快照已完成，作为本次恢复点；这是用户确认，代理未登录控制台核验或演练恢复。代理只备份和离机校验 DVT 文件与系统恢复证据。下文应用备份、客户端验收和云恢复保留为用户侧/后续完整验收参考，不再要求代理操作这些业务；未执行的业务观察不记为通过，完整发布门禁不因此豁免。

用户在当日只读检查后明确同意继续迁移，接受第一次手动重启由运行中的 `6.12.116` 切换到已经安装、GRUB默认选择的 `6.12.118` 内核。代理不安装内核、不修改引导配置；迁移后异常须同时考虑内核变化。此前“无维护时间”不再作为本次开始授权的阻塞，但12小时中断上限不变：从首次受管配置写入记录计时，最多前6小时用于推进，预留后6小时供用户诊断/恢复与复验；该分配是保守操作预算，不是已实测恢复时限。任何异常立即停止推进，不等待预算耗尽。

本次成功标准为固定0.2.0制品、迁移checkpoint COMPLETE、两次真实重启、入口/state一致、严格verify通过、原有参数及无swap意图保持。Sparkle/FlClash业务及至少30分钟正常使用观察由用户自行完成或另行安排，不由本次技术验证代替。

## 1. 已确认与仍需确认

| 项目 | 当前决定或证据 | 开工前缺口 |
| --- | --- | --- |
| 目标版本 | 用户选择等待正式 `0.2.0` 候选冻结，不先迁到 rc.6 | [冻结提交、资产摘要及自身 CI/迁移证据](releases/v0.2.0.md#验证与冻结)已形成；开工时核对使用同一份制品 |
| 云平台与恢复能力 | 用户确认 Amazon Lightsail；可登录控制台、创建/恢复快照、救援或挂盘修复 | 本次手动快照必须实际完成；确认同区域替代实例的创建权限、可用规格/配额及恢复负责人，不把能力确认写成恢复演练通过 |
| 地址入口 | 用户确认已绑定 Static IP，客户端主要通过 IP 连接 | 在私有执行记录保存区域、实例标识、静态 IP 绑定和云防火墙规则；不公开实际地址 |
| 配置意图 | 保持 `debian13-adaptive`、1000 Mbps、200 ms RTT、自动缓冲及无 swap | 维护当日重新核对 state 与实际系统，发现漂移先评估 |
| 维护与重启 | 用户接受最长12小时中断，两次重启手动执行；当日检查后已明确同意继续本次迁移 | 从首次受管写入记录实际起止；不得将授权延伸为不限时执行 |
| 业务基线 | 用户确认客户端为 Sparkle、FlClash，协议为 VLESS + REALITY；无链式出站、无定时任务、IPv6 未启用。x-ui/Xray 在上次只读盘点时运行 | 用户侧业务验收时记录节点及代表性应用；UDP需求未明确，本次代理不测试客户端业务 |
| 验收责任 | 用户已授权代理执行DVT升级及自身验证；用户手动重启、负责快照及必要云恢复 | 代理无业务操作或云恢复授权；客户端业务验收由用户另行记录 |
| 恢复损失与观察 | 用户接受恢复至迁移前备份/快照时点、丢失其后的流量计数与日志增量；接受必要业务逐项新建连接与重连通过，再正常使用观察至少30分钟，无异常后由用户确认结束 | 实际备份/快照时点、业务结果和观察起止需记录；该接受不豁免配置及业务备份完整性要求 |

后续明确执行授权及范围以本方案顶部为准。代表性常用应用及UDP需求留给用户侧业务验收，不再作为代理进行DVT技术验收的前置输入。冻结摘要已有记录，快照完成为用户确认；不要求用户提供不存在的恢复实测耗时。

## 2. 依据及适用边界

上次只读主机证据：Debian13/x86_64、2 vCPU、约 939 MiB RAM，rc.4/schema4/VERIFIED，`debian13-adaptive`，1000 Mbps/200 ms/auto-clamped，记录缓冲 30769152 bytes，无项目或外部 swap；17 项原值完整；实际 mq 根及两个 fq 子队列，fq 服务正常，x-ui/Xray 运行时 NOFILE 65536。它是历史盘点，不替代维护当日检查。云产品类型以用户确认的 Lightsail 为准，不从 DMI 的 Amazon EC2 字样推断控制台产品。

[候选验证记录](validation.md#2026-11-26-adaptive--无-swap-迁移补证)已补齐 rc.4→rc.6 的 2C/1G adaptive/无 swap 隔离迁移。测试提交 `60f919d` 的平台工作流 11/11 通过，后续文档提交 `4bf193a` 主 CI 通过。rc.6 证据没有直接替代正式目标：后继正式 `0.2.0` 已使用自身版本、摘要和固定来源完成适用工程/隔离验证，见[正式冻结记录](validation.md#stable-020-freeze)。本机后续验收必须使用该记录的同一份字节，仍需下列实机开工条件与授权。

执行契约由[迁移实施契约](stable-migration-design.md)、[首次正式版方案](stable-release-plan.md)和[发布门禁 G1–G6](validation.md#stable-release-gates)控制。本方案只增加首台运维安排，不改变产品支持边界；正常迁移不调整带宽/RTT/swap、代理路由、REALITY Target 或防火墙，不开展公网满速测试。快照恢复分支仅重建原有云防火墙规则及访问入口，不增加新策略。

## 3. 开工条件和固定资产

以下为本次迁移开始前使用的条件记录，不是要求已完成迁移的主机再次执行；新一次迁移仍须重新核对适用条件与授权。

1. 正式 `0.2.0` 候选冻结，版本与安装器、manifest、24 项运行资产一致；本场景及既有必需 CI 通过。冻结后若需改运行字节，停止试点并重新确定唯一候选与验证，禁止同版覆盖修复。
2. 从固定提交导出完整目标 bundle，验证 26 项安装制品；本地和目标端再次核对安装器/清单摘要及 `sha256sum -c SHA256SUMS`。完整 rc.4 来源资产也离线保留，固定来源摘要依据 [migration-sources.json](../tests/migration-sources.json)，不混放不同版本。
3. 冻结目标存放在 root 私有的独立目录，示例 `/root/dvt-0.2.0-candidate`；checkpoint 示例 `/root/dvt-migration-rc4-to-0.2.0`，必须在受管状态目录之外且尚不存在。若已有目录或 active 登记，检查并接续原任务，不删目录换名绕过。
4. 迁移开始前入口为 rc.4；旧版 verify、目标只读预检、17 项原值/TCP 三元组、受管文件和 qdisc 恢复材料均通过。不得提前运行目标安装器切换唯一可用入口。
5. 当日源版本/profile/port/RTT/自动缓冲/swap 与预期一致，无未完成迁移、重配置或旧恢复审批。目标 `prepare` 仍会从固定来源 Release 解析并核验来源 profile，不能声称整个流程不依赖网络；解析失败时不开始来源回滚。
6. 按本次收窄范围，手动快照由用户确认完成；DVT 证据须离机保存并验证。业务备份及云恢复由用户负责，代理不操作；快照完成不等于应用一致性或恢复演练已验证。
7. 本次执行授权、12小时计时及停止条件已明确；客户端业务基线属于用户侧完整验收参考，不作为本次代理DVT操作的前置门禁。维护前记录下一次启动预期使用的内核、SSH/x-ui 的开机启动路径及待重启更新；若重启将顺带生效未评估的系统变更，先明确其影响，不把它混入调优迁移结果。迁移过程中不并行执行系统升级、代理配置修改、其他 DVT 写命令；已知定时任务的避让方式提前确定，不临时停用未知服务。

正式 `0.2.0` 资产已冻结，按[候选制品记录](releases/v0.2.0.md)核对完整 bundle；不能把 rc.6 bundle 改名或仅将 rc.5 文档命令替换版本号后执行。冻结 bundle 可在公开发布前验收，公开 tag/Release 仍另行决定；公开时必须保持已验收字节一致。

## 4. 备份与 Lightsail 恢复条件

### 4.1 三类材料分别保存

| 材料 | 内容与方法 | 放行标准 |
| --- | --- | --- |
| Lightsail 手动实例快照 | 在第一次受管配置写入及 prepare 之前创建，记录实例、区域、完成时刻与快照标识；不只依赖滚动自动快照 | 控制台显示已完成，可选择从此快照创建实例；不是仍在 Snapshotting |
| 代理业务备份 | 按实际 x-ui 版本使用一致性导出/数据库备份，包含必要配置、证书及关联任务状态；核对真实路径与工具 | 可读取、格式/数据库完整性检查通过、摘要正确，有受保护的离机副本；备份格式和恢复方法与当前应用版本匹配，不把运行中数据库的单文件随手复制视为一致备份 |
| DVT 与系统恢复证据 | 保存整个 `/var/lib/proxy-vps-tuning`、实际 rc.4 安装目录/入口指向、受管文件、qdisc 快照、17 项当前值与原值、路由/接口、服务及定时任务清单；prepare 后另存完整 checkpoint | 文件与归档摘要可校验，root 私有，备份在受管目录之外；离机保存的密钥/数据库不得提交 Git 或粘贴聊天 |

Lightsail 实例快照复制系统盘及已附加块盘；操作入口是实例的 **Snapshots → Manual snapshots → Create snapshot**，等待完成后才具备从快照创建实例的基础。它是某一时点的系统副本，业务一致性仍需应用层备份配合。[AWS 官方快照说明](https://docs.aws.amazon.com/lightsail/latest/userguide/lightsail-how-to-create-a-snapshot-of-your-instance.html)

备份顺序固定为：先冻结配置变更并记录 rc.4/应用版本 → 完成应用一致性备份和 DVT 归档、验证离机副本 → 创建并等待手动快照完成 → 核对期间没有配置变化 → 才执行 prepare。分别记录应用备份和快照时点；二者不是同一份原子备份。若取样期间发生配置变化，重新建立一致的备份组，不随意混用不同时点的数据库、证书和 state。

如应用备份方式要求短暂停写或停服务，应先纳入维护授权和中断计时；本方案不预先要求停止整台实例。配置冻结不代表所有运行时数据停止变化；流量计数和日志的增量按用户确认的恢复时点处理。快照恢复后先检查应用数据一致性，必要时按匹配版本的应用恢复方法使用离机备份，再验收业务；不得只因磁盘快照完成就宣称业务备份可恢复。

### 4.2 云恢复主路径

SSH 不可用或受管恢复不能可靠完成时，优先使用迁移前手动快照创建替代 Lightsail 实例：**Snapshots → 对应手动快照的 ⋮ → Create new instance**。为保留现有 Static IP，替代实例必须在同区域并保持原网络类型；规格优先与原实例一致，避免借恢复调整资源。开工前确认创建替代实例的权限、资源配额及可用规格；若原规格不可用，先评估替代规格对 adaptive 参数和恢复验证的影响，不在故障现场直接认定等价。原实例及证据保留，不先删除。官方明确：新实例不会自动继承来源自定义云防火墙规则，必须按保存记录恢复，不能用默认规则直接切换业务。[AWS 从快照创建实例](https://docs.aws.amazon.com/lightsail/latest/userguide/lightsail-how-to-create-instance-from-snapshot.html)

用户确认无定时任务，本次外部任务互斥及历史回退处理记 N/A，不建立额外任务编排。维护当日若发现新增会对外执行操作的任务，先停止推进并补充其互斥及历史回退处理，不直接沿用 N/A；系统自带维护任务仍按开工检查核对，不将用户的业务清单理解为系统不存在任何 timer。

先用替代实例的临时管理入口验证 rc.4 入口/state、受管文件、qdisc/接口、业务数据、服务和必要端口；同规格快照副本仍需检查实际接口、地址绑定及应用依赖，不保证旧状态在新实例上直接通过。依赖原 Static IP 的完整端到端业务验证留到切换之后，切换前只记录已能验证的部分。随后由获授权操作者重新绑定现有 Static IP（不释放或删除该 IP），客户端继续使用原 IP，并重复 SSH 和完整业务验收；若切换后失败，停止放行并按保存的绑定和实例状态决定恢复访问方向，不把新实例启动成功记为业务恢复成功。静态 IP 可重新分配，且只能绑定同区域实例。[AWS 静态 IP 说明](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-static-ip-addresses-in-amazon-lightsail.html)、[区域限制](https://docs.aws.amazon.com/lightsail/latest/userguide/lightsail-create-static-ip.html)

若没有外部任务冲突且原实例获准运行到切换时，用户在替代实例接管后也应确认原实例停止，保留其磁盘与证据；任何重新启动原实例的决定都须重新核对任务互斥和 Static IP 绑定。校验 SSH 主机身份，不因恢复时出现密钥警告而关闭 StrictHostKeyChecking。创建替代资源、切换 IP 和处置原实例都需包含在恢复授权中或由用户手动执行。

系统盘损坏/配置错误需要取证时，Lightsail 官方还提供系统卷快照 → 创建块盘 → 挂到另一实例读取文件的路径；不把 EC2 原盘拆挂操作直接套用到 Lightsail。网页 SSH 不作为 sshd/网络均不可用时的唯一兜底。[AWS 系统盘快照恢复说明](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-snapshots-in-amazon-lightsail.html)

## 5. 分阶段迁移与人工重启

以下命令已对冻结 `0.2.0` CLI 作静态核对，相关迁移链路已通过隔离验证；实机执行仍以开工条件、当日状态和明确授权为前提，不能由文档检查代替实机验收。命令分段操作，不连成自动迁移/重启脚本；以下候选和checkpoint目录已用于本次执行，事务现已COMPLETE；这些命令保留为执行契约和追溯记录，不得在本机重新执行prepare、来源rollback或目标apply。每段在 root shell 中单独执行，以子 shell 的严格错误处理阻止失败后继续本段；任何非零退出码或 phase 不符都停止，不能接着执行下一段。断线后先检查现存进程、状态和日志，不启动第二份并行操作。

| 步骤 | 操作与责任 | 继续条件及停止点 |
| --- | --- | --- |
| A 当日基线与备份 | 代理复核主机、旧版 verify、管理可达性及DVT备份；用户确认快照完成 | 来源健康、备份可用、窗口与权限明确；否则不 prepare |
| B 准备事务 | 在完整目标 bundle 内执行下面的 prepare，显式 disabled swap 和 x-ui.service | PREPARED；核对版本/profile/意图/摘要，离机保留 checkpoint。prepare 会写入文件和活动登记，并非纯只读 |
| C 退出来源配置 | 使用 checkpoint 自带迁移器执行 rollback | 必须到 ROLLED_BACK_REBOOT_REQUIRED，旧 state 已退出；此时 rollback 表示恢复系统原基线，不是降级工具 |
| D 第一次人工重启 | 用户收到阶段摘要后手动执行一次重启 | SSH 重新可达，boot ID 改变，无异常状态文件；记录基本服务状态。此时不运行需要 rc.4 managed state 的 verify |
| E 应用正式目标 | 同一 checkpoint 执行 continue | 命令会先核验全部 17 项重启后基线，再 preflight/apply；只有目标 VERIFIED 和 TARGET_APPLIED_REBOOT_REQUIRED 才请求第二次重启 |
| F 第二次人工重启 | 用户手动执行一次重启 | 新 boot ID、SSH 可达；不通过“重启服务”替代整机重启 |
| G 严格验证 | 再次 continue，执行目标严格 x-ui/Xray 验证和基线/意图核对 | COMPLETE，目标 state 为 0.2.0/VERIFIED；失败停在对应 phase，不能手改状态 |
| H 切换入口与技术验收 | COMPLETE 后才安装同一目标 bundle 的入口；安装成功才调用新 dvt，并执行严格 verify；客户端验收由用户另行完成 | 安装失败时保留已完成的目标状态，核对入口实际指向；只修复或重试同一固定 bundle 的入口安装，不重新迁移。入口/state 均为 0.2.0、摘要一致、严格验证通过才记技术验收通过；业务结果单列 |

准备与状态检查：

```bash
(
  set -Eeuo pipefail
  cd /root/dvt-0.2.0-candidate
  test "$(bash debian-vps-tuning.sh --version)" = 'controller=0.2.0 release=v0.2.0'
  bash debian-vps-tuning.sh migrate prepare \
    --checkpoint /root/dvt-migration-rc4-to-0.2.0 \
    --swap-policy disabled --proxy-unit x-ui.service
  bash /root/dvt-migration-rc4-to-0.2.0/dvt-migrate.sh status \
    --checkpoint /root/dvt-migration-rc4-to-0.2.0 |
    jq -e '.phase=="PREPARED" and .source_version=="0.2.0-rc.4" and
      .target_version=="0.2.0" and .profile_id=="debian13-adaptive" and
      .intent.port==1000 and .intent.rtt==200 and .intent.buffer=="auto" and
      .intent.swap_policy=="disabled" and .intent.proxy_unit=="x-ui.service"'
)
```

本段前仍须完成第 3 节资产摘要校验；版本字符串检查不替代完整性验证。disabled 意图中内部占位的 `swap_mib` 不代表已创建 swap，实际 state 和系统应保持 size=0/无 swap。

退出来源配置：

```bash
(
  set -Eeuo pipefail
  bash /root/dvt-migration-rc4-to-0.2.0/dvt-migrate.sh rollback \
    --checkpoint /root/dvt-migration-rc4-to-0.2.0
  bash /root/dvt-migration-rc4-to-0.2.0/dvt-migrate.sh status \
    --checkpoint /root/dvt-migration-rc4-to-0.2.0 |
    jq -e '.phase=="ROLLED_BACK_REBOOT_REQUIRED"'
)
```

用户在确认 `ROLLED_BACK_REBOOT_REQUIRED` 后手动重启；代理不发送重启命令。重新登录核对 boot ID 后，执行第一遍 continue（包含目标 apply）：

```bash
(
  set -Eeuo pipefail
  bash /root/dvt-migration-rc4-to-0.2.0/dvt-migrate.sh continue \
    --checkpoint /root/dvt-migration-rc4-to-0.2.0
  bash /root/dvt-migration-rc4-to-0.2.0/dvt-migrate.sh status \
    --checkpoint /root/dvt-migration-rc4-to-0.2.0 |
    jq -e '.phase=="TARGET_APPLIED_REBOOT_REQUIRED"'
)
```

只有确认 `TARGET_APPLIED_REBOOT_REQUIRED` 才由用户进行第二次手动重启；不要因看到 APPLIED 就提前重启。重启后执行下段，完成严格验证：

```bash
(
  set -Eeuo pipefail
  bash /root/dvt-migration-rc4-to-0.2.0/dvt-migrate.sh continue \
    --checkpoint /root/dvt-migration-rc4-to-0.2.0
  bash /root/dvt-migration-rc4-to-0.2.0/dvt-migrate.sh status \
    --checkpoint /root/dvt-migration-rc4-to-0.2.0 |
    jq -e '.phase=="COMPLETE" and .target_version=="0.2.0"'
)
```

COMPLETE 后重复 continue 仅返回已结束，不替代新的健康检查。确认 COMPLETE 后切换入口并独立核验：

```bash
(
  set -Eeuo pipefail
  bash /root/dvt-migration-rc4-to-0.2.0/dvt-migrate.sh status \
    --checkpoint /root/dvt-migration-rc4-to-0.2.0 |
    jq -e '.phase=="COMPLETE" and .target_version=="0.2.0"'
  bash /root/dvt-0.2.0-candidate/install.sh \
    --source-dir /root/dvt-0.2.0-candidate --no-launch
  test "$(/usr/local/bin/dvt --version)" = 'controller=0.2.0 release=v0.2.0'
  /usr/local/bin/dvt status
  env REQUIRE_PROXY_SERVICE=1 PROXY_SERVICE_UNITS=x-ui.service /usr/local/bin/dvt verify
)
```

这里沿用已核对的默认安装前缀 `/usr/local`，直接调用该入口，避免 shell 别名或另一安装前缀掩盖切换结果；若正式版本或当日入口布局变化，先修订本段。安装失败可能发生在 current 链接切换之前或之后，应检查实际指向，不能仅凭退出码猜测仍是旧入口，也不能重新 apply 来修复入口。

## 6. 窗口与停止条件

用户给出的12小时是上限，不是预计迁移耗时。本次已授权继续，从首次受管写入开始保守计时，记录实际起止和两次重启时刻；代理不执行业务停写或停服务。实际中断不能仅按SSH恢复推断。

不将快照、每次重启和业务验收强行分配固定分钟数。在私有执行记录填明窗口起止与首次重启后的重连情况；本次最多推进6小时、其余6小时保留给用户恢复与复验，重启后首次SSH检查不可达即停止推进并检查，不自动重启或恢复；这些是保守规划估算，不是已实测承诺，也不要求为估时先演练生产恢复。

最迟中止迁移并转入恢复的时刻 = 窗口结束时刻 − 恢复预算 − 复验预算 − 余量。每次进入下一写入阶段前检查剩余时间；预算不足就停止推进。若发生非零退出、boot ID/基线/状态不符、明确业务故障或 SSH 超过约定阈值仍不可达，立即进入对应诊断/恢复决策，不等待固定的 10/30 分钟。若尚无可接受的恢复预算，则保留为开工条件缺口；即便有估算，也不把 12 小时上限写成保证可达的恢复时限。

每次人工重启前向用户提供：当前 phase、刚完成操作、恢复材料位置、即将发生的连接中断和重连后检查。恢复路径可能需要额外停机/启动，它们不属于正常迁移的两次重启，仍由用户掌控。

## 7. 故障与恢复处置

| 故障位置 | 可执行的恢复方向（未来须获授权） | 禁止的捷径 |
| --- | --- | --- |
| prepare 未完成/材料不完整 | 保留目录、日志、active 登记，核查失败原因；没有有效 PREPARED 不能调用 cancel 假装成功 | 删 checkpoint/active 后换名重来 |
| PREPARED 且未 rollback | 来源 state 未变化时，用固定迁移器 `cancel --checkpoint PATH` 撤销准备；保留证据，继续运行 rc.4 | 把 cancel 用到已退出来源配置之后 |
| ROLLBACK_RUNNING | 核查原值/所有权/队列恢复错误，用同一 checkpoint 的 rollback 接续；不可恢复则进入快照恢复 | 新版脚本强行接管旧状态、忽略非零退出码 |
| ROLLED_BACK_REBOOT_REQUIRED / 第一次重启后 | 确认管理与基线，再用同一 continue 接续；决定放弃时可暂留已核验的系统原基线或恢复快照，但原基线不等于 rc.4 已重新安装 | 把旧 state 复制回去冒充恢复，直接运行旧 dvt apply |
| APPLY_RUNNING | state 缺失时，同一 continue 会重新核验已保存基线后尝试 apply；若残留 APPLIED，先用固定目标 profile 自身 rollback，确认目标 state 已退出、17 项基线可恢复，再评估人工重启和同一 continue；若已是目标 VERIFIED，先核查失败点，不一律回滚 | 修改 state 为 VERIFIED；未恢复完整基线就重试；用来源脚本回滚目标 |
| TARGET_APPLIED_REBOOT_REQUIRED | 只有目标配置已核验才请求第二次人工重启；若决定用目标自身 rollback 退出，转入下述终止路径，不再用此 checkpoint 重新 apply | 跳过 boot ID 检查；以为目标 rollback 会自动回退 checkpoint phase |
| VERIFY_RUNNING | 目标 state 仍完整时，查明并修复获授权的服务/配置原因后，同一 continue 可重验；若已执行目标 rollback 或 state 缺失，转入终止路径 | 删除 state 后继续重验；为得到 COMPLETE 而解除严格服务检查 |
| COMPLETE 后入口安装失败 | 保留目标 state 和 checkpoint，检查安装器退出码及 current/入口实际指向；可从固定目标 profile 只读 verify，修复后重试同一 bundle 的安装 | 调用可能仍为旧版的 dvt 去解释目标 state；重新 prepare 或 apply |
| COMPLETE 后业务失败 | 先保存可达性、服务和客户端证据，判断是否由候选引入；需要退出目标时走下述终止路径或迁移前快照恢复 | 把 checkpoint rollback 当自动降级；以 COMPLETE 的幂等返回代替健康检查 |
| SSH 失联或恢复材料损坏 | 用户控制台诊断；必要时按第 4 节从快照新建、恢复云防火墙、重新绑定 Static IP 并复验 | 仅恢复文件却宣布业务恢复，或删除唯一原实例/快照 |

**目标退出后的接续边界。** 当前迁移器只有 `APPLY_RUNNING` 且目标 state 已可靠退出时，才有同一 checkpoint 重新 apply 的分支。对 `TARGET_APPLIED_REBOOT_REQUIRED`、`VERIFY_RUNNING` 或 `COMPLETE` 执行目标 profile rollback，并不会回退 checkpoint phase：前两者不能据此重新 apply，后者 continue 只返回已结束。此时保留 checkpoint 和活动登记，不手改 phase、不删除 active 另开任务；停止该次迁移，优先从迁移前快照恢复。若选择原机恢复再重新迁移，须先另行核验固定版本的退出/收尾办法，不能把尚未具备的自动收尾能力写成现成操作。此结论依据当前 [迁移器](../dvt-migrate.sh) 的 `continue_stage` 与 `main`，已对冻结 `0.2.0` 复核；后续改版需重新检查。

目标配置 rollback 只恢复其保存的系统基线，不能自动恢复代理数据库、计数或外部任务。若选择重新应用 rc.4，须先确认目标已完全退出、原值已恢复，再用固定 rc.4 完整资产和原意图重建、重启、验证；本次没有验证“正式 0.2.0→rc.4 自动降级”，不将它作为一键应急承诺。优先保证业务恢复，不在正常业务机上故意注入故障验证恢复。

## 8. 验收标准与记录

本节保留完整验收标准；本次代理仅执行DVT、系统参数及只读服务技术检查。面板登录、客户端、应用和正常使用观察由用户另行完成，以下相关条款不授权代理操作业务；缺失结果如实记为未验证。

所有必需业务必须先在 rc.4 上取得正常基线。已有失败项先解决或明确排除，不能迁移后才以“可能本来如此”解释。客户端须固定或核对本次选中的测试节点，结合客户端连接/路由记录或服务端入站证据确认请求经过本机，排除自动回落、负载均衡或直连绕过造成的假通过；只保存必要的脱敏结果。本次以 Sparkle、FlClash 分别连接本机 VLESS + REALITY 节点为必需客户端路径；无链式出站，IPv6 验收记 N/A。代表性常用应用及UDP需求在开工前基线中记录，未确认UDP需求前不宣称UDP验收通过。观察条件按用户本轮确认执行。

| 层级 | 通过标准 | 证据与范围 |
| --- | --- | --- |
| 管理可达性 | 两次重启均从实际使用网络重新建立 SSH；面板能登录并读取预期配置；Static IP 绑定正确 | boot ID、连接时间、用户确认，不公开登录凭据 |
| DVT 一致性 | 正式入口/state/固定资产均为 0.2.0；schema4/VERIFIED、checkpoint COMPLETE、active 登记释放 | 版本、摘要和状态摘录；不得只看入口版本 |
| 参数与恢复 | profile、1000 Mbps、200 ms、auto 意图保持；17 项目标原值与来源及重启后基线一致 | 缓冲字节值与迁移前比较，若变化先核对实际内核/内存及资源感知计算，不静默调整 BUF_MAX 来迎合旧值 |
| 内核与队列 | 目标 verify 通过；BBR/fq、实际出口 mq 与 fq 子队列符合受管契约，fq unit enabled/active/成功退出 | 当前接口/拓扑实际核对；不把文件存在当作启动持久性证明 |
| 无 swap | `swapon` 无活动项，SwapTotal=0，无 `/swapfile-proxy` 文件/符号链接及 fstab swap 项；state created=false/size=0/active=false | 来源、第一次重启后、目标应用后、第二次重启后分别记录 |
| 代理运行 | 严格 verify 通过；x-ui active、实际 Xray 子进程存在、相关运行时 NOFILE soft/hard 均至少 65536 | 状态为严格服务证据，仍须下面的真实客户端业务 |
| 连接与重连 | 每个确认的必需业务路径使用同一客户端与网络，至少一次新建连接和一次断开后重连成功；失败时再有针对性复现 | Sparkle、FlClash 分别验证；服务端运行正常不能替代客户端成功；本次链式路径为 N/A |
| 普通传输与应用 | 每个必需业务完成一次实际请求/交互；选一个已知正常目标完成不超过 10 MiB 的普通下载并核对完整性；有上传需求才增加小文件上传 | 不运行测速站、iperf3 或吞吐上限测试；敏感应用只记录结果 |
| 地址族/UDP | 只验证原来实际使用的 IPv4/IPv6、UDP 类业务；没有使用的项记 N/A 并说明 | 不为凑矩阵临时启用 IPv6 或新协议 |
| 正常使用观察 | 覆盖一段用户确认的实际常用会话和正常并发；无新增 OOM、非计划服务重启、配置漂移或可归因于迁移的业务错误 | 用户已接受：必要业务新建连接及重连通过后，正常使用观察至少30分钟，无异常后由用户确认结束；记录实际起止时刻，有限窗口不证明长期稳定或性能收益 |

建议执行记录字段：冻结提交/资产摘要、备份完成时间与私有引用、开始/结束/中断时刻、各 phase 与退出码、三次 boot ID（迁移前及两次重启后）、17 项基线比较、swap/服务证据、各业务的前后结果、异常归因与处置、用户验收结论。全部证据留在私有归档，公开仓库只保存脱敏结果。

## 9. 完成与保留

只有技术验证、管理可达性、实际业务、约定观察均通过并由用户确认，才记录“本主机正式候选验收通过”；这不自动授予公开发布或其他主机迁移权限。若回退，记录最终实际运行版本和业务恢复情况，不把恢复成功记为迁移成功。

原 rc.4 资产、迁移前手动快照、业务备份和 checkpoint 保留到正式发布及约定观察完成，再由用户决定清理；不自动删除。恢复建立的新资源也由用户确认处置。正式候选冻结已完成，本次按顶部收窄范围执行，具体进度见项目阶段备忘；完整业务验收与公开发布仍未完成。
