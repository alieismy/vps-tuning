# 验证说明

<a id="rc2-mainline-release-validation"></a>

## 0.2.0-rc.2 主线整合及公开发布（2026-10-11）

- 主线补交：[PR #36](https://github.com/alieismy/vps-tuning/pull/36) 合入 `fac9a3c`，两项 [Push CI 38111505607](https://github.com/alieismy/vps-tuning/actions/runs/38111505607) / [PR CI 38111509531](https://github.com/alieismy/vps-tuning/actions/runs/38111509531) 成功。CodeRabbit 对 `4b6709a` 实质评审无 actionable，独立评审无阻断；#34 记录保留。
- rc.2 整合：[PR #37](https://github.com/alieismy/vps-tuning/pull/37)，整合 head `d85c1b4f8828dc1650df3428110511527244e537`，与平台测试 head `764c016b2009ad21aae68ceee8d052f5469e7a72` 文件树一致；[Push CI 38111906793](https://github.com/alieismy/vps-tuning/actions/runs/38111906793) 与 [PR CI 38111910453](https://github.com/alieismy/vps-tuning/actions/runs/38111910453) 结果：两项均成功；常规 132 项测试中 root 集成在非 root 阶段跳过，随后 20 项 root 恢复专项全部通过，安装/迁移、隔离原生 HTB 及 ShellCheck 通过。独立评审已对 `764c016` 完整差异检查，无阻断发现；CodeRabbit rate-limited 不计为实质评审。
- 七组平台生命周期绑定 `764c016b2009ad21aae68ceee8d052f5469e7a72`：[平台 CI 38111714946](https://github.com/alieismy/vps-tuning/actions/runs/38111714946)，结果：七组全部成功；归档复核：七份下载归档均核对大小与 GitHub SHA-256、rc.2 VERIFIED 状态、两次客体 boot ID 变化、17 项 sysctl 及 qdisc 恢复。隔离 VM 证据不代表五台存量生产迁移。
- 平台结果复用：`764c016`、整合 head `d85c1b4` 与发布提交 `6f48443` 的 Git tree 完全相同。主线自动触发的重复矩阵 [38113231525](https://github.com/alieismy/vps-tuning/actions/runs/38113231525) 已主动取消，未计为通过；平台门禁采用上条已完成并核验的七组结果，避免同一文件树重复运行。
- 合并与 tag：主线合并提交 `6f48443e194531fe3692e3bbe0271713a5e40a65`，[合并后 CI 38113231529](https://github.com/alieismy/vps-tuning/actions/runs/38113231529) 结果：success；固定 `v0.2.0-rc.2` tag 解引用该提交，[tag CI 38113244765](https://github.com/alieismy/vps-tuning/actions/runs/38113244765) 结果：success。
- 公开发布：[v0.2.0-rc.2 Pre-release](https://github.com/alieismy/vps-tuning/releases/tag/v0.2.0-rc.2)。公开回验结果：26 项公开下载文件逐字节匹配固定 tag 与 GitHub digest，24 项 manifest 及安装器内置摘要链通过；旧仓库 installer/manifest 地址均经两次 HTTPS 跳转返回 200 且字节一致；源码恢复工具摘要一致；原 14 个 Release、199 项资产及旧 tag 指向未变。24 项清单运行资产、installer 与清单共 26 项；源码恢复工具另行绑定，不计入安装资产。

VPS-02 既有 `COMPLETE / VERIFIED` 和 `PASS_USER_CONFIRMED` 证据见下方 2026-10-09 日期化记录。其他四台仍未迁移；本轮未连接或修改真实 VPS。原始 `PENDING_USER_TEST` 及发布前待办保留为当时状态，由本节后继证据补齐。

本节后继发布文档 PR 的 CI 与评审以该 PR checks 为准，不预报完成，也不替代上述固定运行资产的验证。

## 0.2.0-rc.2 逐台 TCP 基线恢复候选（2026-10-04）

范围见[恢复工具](tcp-baseline-recovery.md)。新增 20 项恢复测试：Windows 上 18 项通过，Linux 权限/flock 与 Linux root 迁移 CLI 集成两项跳过。完整静态套件返回 0，九份 profile 和控制器通过，132 项 Python 中 129 项通过、3 项平台条件跳过；本轮修改的迁移脚本通过 ShellCheck 0.11.0，新增 jq 归档契约与状态来源校验使用实际生成归档执行通过。后续 Linux CI 将运行全部恢复测试，包括两个模式的真实文件事务接迁移 CLI；profile 和 boot ID 仍为 fixture，不能称为真实系统迁移。

三台已有可信主机密钥的真实 VPS 通过新工具的 `inspect`，由 SSH stdin 执行，只读获取状态/部署绑定、运行参数、文件摘要，不在远端保存工具或写状态。新增可连接主机另通过固定 rc.12 来源 `verify_settings()` 与候选 `run_preflight()`，状态、文件、17 项 sysctl、qdisc、swap 和 boot ID 前后一致，其两个部署时间戳与历史候选匹配。另两台分别待主机密钥信任、远端关闭连接；生产基线激活、整机恢复、两个重启和业务验收均未执行。逐台编号、地址和计划保留在私有忽略目录。

实现提交 `3616444921d0bf688ee79e11f5816f0e41ef1485` 的[主 CI 37178357578](https://github.com/alieismy/debian-vps-tuning/actions/runs/37178357578)已成功，日志确认 132 项常规测试中只有 root 集成因普通用户运行跳过，随后 root 专项 20 项全部通过、无跳过；九份 profile、安装/迁移、原生 tc/信号恢复、HTB 静态和 ShellCheck 0.11.0 成功。新增恢复模式的端到端测试执行真实文件读写及迁移 CLI，两个 boot gate、源归档保留、PREPARING 拒绝 rollback、目标原值再次截断拒绝均通过；系统 profile 操作与重启仍是隔离 fixture。

[平台运行 37178357544](https://github.com/alieismy/debian-vps-tuning/actions/runs/37178357544) 的四组 x86_64 成功，四份 artifact 均完成 GitHub digest、目标 VERIFIED、两次真实客体重启及 17 项原 sysctl/qdisc 恢复核验；三组 ARM64 仍在运行。VM 门禁验证常规生命周期，不包含用户五台生产基线恢复；未发布候选与生产验收边界保持。

后续核验（2026-10-05）：该平台运行已整体 `success`，head SHA 仍为 `3616444921d0bf688ee79e11f5816f0e41ef1485`。七份归档均已下载并核对 GitHub digest、目标版本及 VERIFIED 状态、两次客体 boot ID 变化、17 项 sysctl 原值恢复和 qdisc 恢复；三组 ARM64 不再待完成。主 CI 也复核为同一实现提交的 `success`。

本轮实际连接四台 VPS，均通过恢复工具 inspect、固定来源 `verify_settings()` 和候选 `run_preflight()`；状态、受管文件、17 项 sysctl、qdisc、swap 和 boot ID 前后一致。此前待信任的主机现已使用登记的密钥严格校验通过；另一台的连接已恢复，但自动化公钥登录返回 `Permission denied (password)`，未取得状态，不计为通过。具体映射和四份已补齐实机绑定的计划仅存私有目录。未执行基线 activate、旧版 rollback、目标 apply、重启或业务验收；系统/业务恢复点和控制台可用性仍待确认，历史模式的部署连续性确认仍保留为未完成项。

2026-10-09 分工变更：此前待自动化认证的一台改由用户使用密码登录、手工执行测试与升级。已交付固定来源/候选/恢复工具的私有预检包，资产摘要、候选提交字节、归档回读和运行脚本 Bash 语法检查通过；脚本直接执行来源 CLI verify 和候选 CLI preflight，正常锁元数据写入属于其已说明的副作用。尚未收到用户实测输出，成功主机数量保持四台；密码登录本身不作为新的产品阻塞。

同日后续收到 VPS-02 实测材料：指定私有目录与工作区下载副本的九份结果文件逐字节一致，五份预检包文件与原交付一致；来源 verify 和候选 preflight 均零警告通过，x-ui active，前后 inspect 完全相同。五台现均有预检证据，其中其他四台保留 2026-10-05 检查时间，不冒充本日重新验证。用户确认 VPS-02 系统快照已离机保存、控制台/救援入口可用；Agent 未实施备份还原测试。

已为 VPS-02 准备固定提交的私有离线迁移包，核心资产保持原字节，四个手工阶段保留归档完整性、状态绑定和两个重启门禁。38 个归档文件、24 项目标运行资产、摘要链、五份 Bash 编排语法及控制器版本输出核对通过；独立只读复核没有阻断发现。新增编排尚未实机运行，恢复激活、迁移、安装入口、严格代理服务验证及真实客户端业务均仍待用户执行，不能把材料交付计为生产迁移通过。

同日后续迁移实测：VPS-02 已由用户手工执行四阶段流程并回传运行目录。38 个包文件与原交付逐字节一致，24 项目标资产、checkpoint 三项资产及两份恢复归档各 12 项 receipt 摘要核对通过。原始 state 得以保留，激活仅更改两项 TCP 原值及来源字段；replacement 与 `historical_originals_recovered=false` 保持。checkpoint 为 `COMPLETE`，终态为 `0.2.0-rc.2` / schema 4 / `VERIFIED` / `debian13-1c1g` / 100 Mbps，profile SHA-256 为 `d567e5824d25a3c742b5071912a673232985e15f9cc6b97186a7c0579fc7c254`。目标环境为 Debian 13、x86_64、1 vCPU、967 MiB、内核 `6.12.111+deb13-cloud-amd64`。

第一次重启前后 checkpoint boot ID 不同；第二次重启门禁通过由固定脚本的清洁环境调用、无跳阶段的 history 和第 04 阶段完成日志支持，最终 boot ID 未单独归档。第一次重启后采集的 `tcp_rmem=4096 131072 6291456`、`tcp_wmem=4096 16384 4194304` 与目标保存原值完整匹配；这是新卸载恢复基线，目标调优上限仍为 16 MiB。安装入口版本匹配 rc.2，严格 `REQUIRE_PROXY_SERVICE=1 PROXY_SERVICE_UNITS=x-ui.service /usr/local/bin/dvt verify` 零警告通过：x-ui active，配置、主进程及直接子进程 NOFILE soft/hard 均为 65536。该证据支持本次系统迁移与严格服务验证完成；真实客户端业务仍为 `PENDING_USER_TEST`，不证明性能收益、整机还原演练或其他四台迁移完成。Agent 本轮只核验下载材料，未连接或修改 VPS。

同日业务验收补记：用户随后明确确认“VPS-02 面板正常、代理业务正常、重新连接正常”。本机业务状态据此记为 `PASS_USER_CONFIRMED`，与前述已核验的系统迁移、严格服务验证共同闭合本次迁移验收。该项为用户实际测试回报，Agent 未重新连接 VPS 或独立复测客户端。原始运行摘要中的 `PENDING_USER_TEST` 保持原样，另存后续验收记录；不据此宣称量化性能收益、长期稳定性、整机还原演练或其他四台迁移完成。

## 0.2.0-rc.2 旧 schema 4 升级预检修复（2026-10-04，本地候选）

本轮修复与限制见[候选说明](releases/v0.2.0-rc.2.md)。新增 `tests/test_update_preflight.py`，修复前在实际 profile 预检与控制器 `run_update` 调用路径观察到旧 schema 4 拒绝；修复后七个测试方法通过，覆盖五组历史状态、普通模式版本边界、非 preflight 动作拒绝、schema/profile/provider/所有权与阶段门禁、来源 verify 失败停止，以及缺失 TCP 原值时不创建 checkpoint。合成状态逐字节不变；Windows fixture 隔离宿主探测、锁和 root 元数据，不证明目标机生命周期。

最终 `bash tests/static-check.sh` 返回 0，输出 `static checks passed for 9 scripts`；其中 112 项 Python 中 111 项通过，1 项因 Windows 缺少 flock 跳过，控制器检查通过，模板生成无漂移。ShellCheck 0.11.0 按 CI 文件清单检查 29 个脚本及九份提取的 helper，共 38 项全部通过。24 项运行资产摘要、installer 内置 manifest 摘要和候选说明中的安装摘要一致；README 在线命令保留已发布 rc.1 的固定地址和摘要。离线 probe 校准器增加同格式 rc.2 标识兼容，原有结果及证据不变回归通过。

`bash experiments/htb-aggregate/tests/static-check.sh` 返回 0，输出 `HTB aggregate experiment static checks passed`；其中故意注入的失败与恢复断言按预期处理。最终 `git diff --check` 通过。

候选尚未发布；本轮获准进入独立分支 Linux CI，实际结果绑定后续固定提交与运行记录。VM 重启和用户 VPS 生命周期尚未执行；既往 rc.1 CI 不能替代这些门禁。历史单值 TCP 快照仍阻断迁移，本地预检修复不构成原值恢复或生产升级成功。

获授权的两台 VPS 只读验证：固定已发布 rc.1 的原 `state_file_path_is_valid()` 拒绝当前 rc.16/rc.17 状态，候选同函数接受；执行真实 jq、stat 与真实状态文件，不模拟 root 元数据。受管文件全部匹配 state 摘要，配置文件的 17 项 sysctl 与当前内核一致，x-ui active。检查前后 state、受管文件、sysctl 和 boot ID 不变，两项历史 TCP 原值仍均缺项。测试经 SSH stdin 在内存中运行，不安装候选、不执行 DVT 动作或写锁；该结果不等同完整 `update`/`preflight` 或恢复验收。

后继只读测试以 `O_RDONLY` 打开既有锁文件并取得非阻塞共享锁，直接运行固定来源的 `verify_settings()` 与候选 `run_preflight()`；两台均返回 0，源码校验摘要分别匹配来源固定资产。未模拟 OS、资源、所有权、provider、qdisc 或 swap；仅不调用 CLI 的写锁/下载入口。前后核对 state、五项受管文件、原 qdisc/provider 备份、fstab、sysctl.conf、锁文件摘要，以及 17 项内核 sysctl、qdisc、swap、boot ID，全部一致。两台执行入口均仍为 rc.1，受管状态分别为 rc.16/rc.17。

实现提交 `540bbb456242d59ffe0fa24a2393592c0648293d` 的 [Linux 主 CI 37172239683](https://github.com/alieismy/debian-vps-tuning/actions/runs/37172239683) 全部通过：下载日志确认 112 项 Python 无跳过、九份生成 profile、root 安装、rc.16/17/18/19→rc.2 迁移 fixture、预算/进程、隔离原生 tc/iperf3 与 ShellCheck 0.11.0 成功。[平台矩阵 37172239733](https://github.com/alieismy/debian-vps-tuning/actions/runs/37172239733) 的四组 x86_64 已通过并下载归档核对 GitHub digest、rc.2 VERIFIED 状态、两次客体 boot ID 变化、17 项 sysctl 和 qdisc 恢复；三组 ARM64 仍在运行，不计为通过。这些是隔离 CI 客体证据，不是存量 VPS 的恢复或迁移。

后续完成核验：平台运行 `37172239733` 已整体成功，七组 artifact 均核对 GitHub digest、rc.2 VERIFIED、两次真实客体重启、17 项 sysctl 原值和 qdisc 恢复；三组 ARM64 不再处于待完成状态。仅文档提交 `89e7c7524dd114e192eab13c4ace02e069cef145` 的 [主 CI 37172611946](https://github.com/alieismy/debian-vps-tuning/actions/runs/37172611946) 也通过；相对实现提交仅三份文档变化。候选尚未发布，以上不补齐用户旧状态中的历史 TCP 原值。

## 测量证据解释工具（2026-09-30，独立 Pre-release）

当前发布为 [`measurement-explanation-v0.1.0`](releases/measurement-explanation-v0.1.0.md)，固定源码 `1c5e922c2fce916d5217bf6c238d6cd50a8c51b0`。[合并后 CI 36694985355](https://github.com/alieismy/debian-vps-tuning/actions/runs/36694985355) 与 [tag CI 36696765305](https://github.com/alieismy/debian-vps-tuning/actions/runs/36696765305) 均通过，日志确认 105 项 Python 无跳过及完整 Linux 门禁。发布的三个资产已从公开地址下载，与批准制品逐字节一致；解包目录通过 16 项工具测试与四轮 71 样本回读，1244 个源证据文件保持。主程序 Release 的 26 项资产及更新选择保持；这些结果不替代公网业务收益或存量迁移验收。以下保留对应开发提交的验证记录。

`tools/explain_measurement.py` 的接口和边界见[设计说明](measurement-explanation.md)。新增 `tests/test_measurement_explanation.py`，由既有 `unittest discover -s tests -p 'test_*.py'` 自动发现；覆盖合成持续上升/孤立单事件/最高档候选、缺失数据、整数边界、原分类保持、HTB 恢复门禁、源目录不变及篡改拒绝。合成测试不代表公网误报率或可靠拐点验收。

交付核对修正了缺少 `tested_rates` 或汇总遗漏实际较高 sweep 档时误报 `NOT_COVERED` 的问题，此时输出 `INCOMPLETE`；真实最高档候选仍为 `NOT_COVERED`。新增工具 16 项回归通过；本机全套 Python 105 项中 104 项通过，1 项因 Windows 宿主缺少 flock 跳过；生成检查通过。四轮真实归档共 71 个正式样本的派生解释与修正前逐字段一致，1244 个源文件摘要保持：旧候选仍为两个单事件越阈值且高档未确认上升，最新二十秒复验仍无候选。已发布测量运行源码、分类器、24 项固定运行资产未改；Linux CI、发布及新增公网运行不属于上述本地结果。后续状态记录于[项目备忘](project-memo.md)。

[PR #28](https://github.com/alieismy/debian-vps-tuning/pull/28) 的实现提交 `f11b5a59aa53960e818acd8a78d126d9b67252c5` 已通过 [push CI 36692509176](https://github.com/alieismy/debian-vps-tuning/actions/runs/36692509176) 和 [PR CI 36692533017](https://github.com/alieismy/debian-vps-tuning/actions/runs/36692533017)。下载日志确认 Linux 的 105 项 Python 全部通过、无跳过，另有九份 profile、安装/迁移、预算、原生 tc/iperf3 完整/INT/TERM 恢复与 ShellCheck 证据。后续评审修正仅完善缺失字段的中文显示和测试结果表述；最终提交状态以 PR 检查为准。此处 Linux CI 不替代两台存量主机迁移或公网业务收益验收。

评审修正后的功能提交 `7f90a1df6c33b8c6ade3a40ca7dcb8d3847f00a2` 已通过 [push CI 36693340984](https://github.com/alieismy/debian-vps-tuning/actions/runs/36693340984) 与 [PR CI 36693347720](https://github.com/alieismy/debian-vps-tuning/actions/runs/36693347720)，两套日志均确认上述完整门禁成功及 105 项 Python 无跳过。两条评审线程已解决。后继仅追加文档的提交及合并结果分别以 PR head 检查和默认分支 Actions 为准。

## 0.2.0-rc.1 第三阶段跨平台候选（2026-09-29）

生成 profile 扩为九份，纳入 ARM64、Ubuntu 24.04 LTS、内存自适应策略与 1–10000 Mbps 配置参数，契约和逐平台状态见[平台支持矩阵](platform-support.md)。固定 `d38ec3f` 的主 Linux CI [36531809720](https://github.com/alieismy/debian-vps-tuning/actions/runs/36531809720) 已通过；同版本真实 VM 在回滚读回中暴露 TCP buffer 原始向量截断，不能记为平台生命周期通过。

修正由完整向量回归、来源状态拒绝和回滚读回检查约束。`tests/platform-vm.py` 使用官方固定摘要镜像、原生客体 OS/架构、真实 boot ID 变化及系统状态对照；`tests/platform-htb-native.py` 补充 kernel-created fq 0: 与看护恢复。下列较早提交的通过证据均保留固定版本边界，不替代第三阶段最终提交的结果。

固定 `9ea12a6fcc191129cf09645c5c377e2e28cb3a94` 的 [Linux CI 36534049141](https://github.com/alieismy/debian-vps-tuning/actions/runs/36534049141) 和 PR CI 36534055685 全部通过，日志确认 89 项 Python 无跳过，另覆盖 root 安装/预算/迁移、原生 tc/iperf3 和固定 ShellCheck。平台 [36534049122](https://github.com/alieismy/debian-vps-tuning/actions/runs/36534049122) 的四组 x86_64 已通过且下载归档逐项核验：官方镜像摘要、实际 OS/arch、两次 boot ID 变化、17 项 sysctl 原值恢复、qdisc 参数、三类 fq 0: 恢复和 legacy swap。Debian 12/13 ARM64 随后通过并完成归档复核；Ubuntu ARM64 在 cloud-init/APT 索引处理阶段超时，尚未进入项目安装或 apply。整个 run 为 failure，测试准备修正和后继结果见平台支持矩阵。

经既有授权只读核对一台测试 VPS，确认它的 rc.16 来源状态中两项 TCP 原值各只有一个字段；rc.19 总控与旧状态并存，状态摘要前后未变。本轮未对该主机写入、测速或重启，新版迁移须继续阻断此类不完整来源。此事实不影响全新主机的生命周期实现，但阻止宣称该存量主机已经完成升级。

后继 `1b1ee5b` 的六组生命周期也通过并完成归档复核；Ubuntu ARM64 已通过依赖准备、安装、首次 apply 和同值幂等，但在重配置过程中触及 600 秒测试期限。`5b53adc` 仅调整该客体的 QEMU 指针认证模拟算法，全部期限与产品断言保持，详见[平台支持](platform-support.md)。该提交的 [push CI 36540841878](https://github.com/alieismy/debian-vps-tuning/actions/runs/36540841878) 与 [PR CI 36540847005](https://github.com/alieismy/debian-vps-tuning/actions/runs/36540847005) 均通过，日志核验 89 项 Python 无跳过、九份 profile、安装/迁移、原生 tc/iperf3 与 ShellCheck。

最终 [平台复验 36540841895](https://github.com/alieismy/debian-vps-tuning/actions/runs/36540841895) 的七组全部成功；七份归档的大小/GitHub digest、实际 OS/架构、两次 boot ID 变化、17 项原值、qdisc、三类 HTB 恢复和 legacy swap 均独立复核。Ubuntu ARM64 的准备约 5.5 分钟、首次应用阶段约 7 分钟，未放宽原期限或断言。26 项发布文件与 `5b53adc` 及固定运行实现 `9ea12a6` 逐字节一致；后继文档同步沿用这一明确绑定的功能证据，不扩大到公网高速、IPv6、特定云厂商硬件或代理业务收益。


## 0.2.0-rc.1 第二阶段临时 HTB 候选（2026-09-28）

低速短窗口采集修正 `cc821a8` 已通过 [Linux CI 36406911845](https://github.com/alieismy/debian-vps-tuning/actions/runs/36406911845)：80 项 Python 无跳过、6/6 低速 BBR 样本和完整 CLI 24/24 样本有效、原生恢复/信号/预算及安装生命周期通过。随后同机公共路径完整 CLI 正常退出并恢复，15 个正式样本中 11 个有效、无 receiver 背离；因一次窗口超差、三次 softnet 压力及控制漂移，整轮保持 `INSUFFICIENT_EVIDENCE`。原有效性与预算门禁保留，完整证据与剩余边界见[采样修正记录](temporary-htb-sampling-2026-09-28.md)。以下各段保留对应历史提交的证据，不代表当前汇总。

新增 [`htb-sweep`](temporary-htb.md)，此处与下节第一阶段固定提交的证据分开。当前已实现单根 fq 完整恢复事务、独立 watchdog、自动选点/预算复用、粗细扫描及 reference 门禁。离线检查覆盖 fq 单位与未知选项拒绝、所有权/路由、精扫、预算停止、恢复失败及报告门禁；原生入口 `tests/temporary-htb-check.sh` 在两个专有 netns/veth 上验证真实 tc 与 iperf3，不经过公网或 runner 主出口。

实现提交 `6fd5030ce37c4c85abf851bdfa2238f09f7aa59d` 的 [Linux CI 36393226085](https://github.com/alieismy/debian-vps-tuning/actions/runs/36393226085) 全部通过：73 项 Python、0 跳过，主静态/旧 HTB fixture、生成与安装资产一致性、root 安装/预算/迁移生命周期、固定 ShellCheck 0.11.0，以及新增真实 tc/iperf3 原生门禁。Windows 本地同一套 Python 为 72 通过、真实 flock 跳过 1 项；21 项清单资产及 installer 绑定、58 个本地文档链接和六份 profile 零差异已核验。

原生环境为 Ubuntu 24.04 runner，iproute2 6.1.0 与经官方 SHA-256 校验并在 runner 构建的 iperf3 3.18，流量只经过两个专有 netns/veth。完整验证了定制 fq 参数/显式 handle 恢复、变速、并发拒绝、接口 down 后恢复，root/class/leaf 写入失败，外部参数漂移及重复恢复拒绝，owner SIGKILL、忽略 TERM 后的看护期限恢复，以及完整 CLI 和 SIGINT/SIGTERM 后的 fq 恢复、清除活动登记、账本预留归零和无采集进程残留。中断分别要求退出 130/143、保留 `INCOMPLETE` 且没有 `COMPLETED`。

完整 CLI 的 24 个正式样本均观察到 HTB overlimits 增长；21 个有效，3 个因 `RECEIVER_DIVERGENCE` 被排除。隔离 netns 不暴露 `net.core.default_qdisc`，因此前后观察如实保留 `UNAVAILABLE`，其他已观察字段无变化，最终 `INSUFFICIENT_EVIDENCE`、无候选区间。CI 证明调度、真实整形、恢复和拒绝路径，不证明该环境产生了有效拐点建议。先前 iperf3 3.16 的 CPU 压力拒绝及 iproute2 旧文本兼容修正见[项目备忘](project-memo.md)。

2026-09-28，固定 `b172efc` 的[真实单机 HTB 验收](temporary-htb-acceptance-2026-09-28.md)已执行但未通过：完成公共端点选点和 18 次实际 HTB 采集，全部因 receiver 背离被排除；目标 iproute2 6.15.0 的 weights 解析问题导致自动恢复失败。已核对所有权后补救恢复原 fq 全部 14 项参数，受管状态及 17 项 sysctl 等观察一致，预留/进程/活动登记归零，保留不完整报告。账本共计 51.25 MiB；SIGINT/SIGTERM 按停止条件未执行。

修复增加完整恢复参数的无写入语法预检、受影响 weights 解析器的限定兼容、checkpoint 参数重放与校验。目标实际解析器已通过无 `dev` 的完整命令检查，qdisc 前后不变；本地新增六项回归，完整 Python 79 项中 78 通过、Windows flock 跳过 1 项。修复提交 `1986dea4a6cd8f30c3e2213be1577f389e265e7e` 的 [Linux CI 36397718732](https://github.com/alieismy/debian-vps-tuning/actions/runs/36397718732) 全部通过：79 项 Python 无跳过、主静态与旧 HTB 套件、root 安装/预算/迁移生命周期、真实 tc 正常/部分失败/看护/信号恢复及 ShellCheck。该轮原生 24 个样本中 23 个有效；隔离 netns 的配置观察缺口仍使结果为 `INSUFFICIENT_EVIDENCE`，不产生候选建议。

用户再次授权后，固定 `f08fd8c` 的[恢复复验](temporary-htb-retest-2026-09-28.md)通过：不启动 iperf3 的真实 tc 2/3/4 Mbps 正常事务自动恢复，以及公共 IPv4 首个采集窗口内的 SIGINT/SIGTERM，分别退出 130/143。三次均 `RESTORED`、原 `fq 8001:` 及 14 项参数一致，无进程/活动登记/预算预留残留；中断报告正确拒绝。共享窗口累计保守计账约 87.88/128 MiB，前 19 笔记录不变；112 项新证据摘要通过，三份冻结恢复源码与候选一致。

后续采样修正已补齐完整 sweep 的正常 CLI 完成报告和自动恢复，部分样本有效；整轮可靠拐点仍未验收。原 root `0:` 自动恢复分支（复验起点为 `8001:`）、目标机 SIGKILL/期限接管、更多内核/iproute2 组合、IPv6、安装迁移/重启及业务性能仍未验收。不同轮次、事务模块、产品 CLI、CI 和业务证据分别报告；持久 HTB 与平台 apply 范围未扩展。

## 0.2.0-rc.1 自动测量候选（2026-09-28）

本节覆盖未发布的第一阶段候选；以下 rc.19 及更早记录保留历史效力。实现与验收映射见[独立测量契约](automatic-measurement-design.md)。新测量不要求 profile，旧配置策略和生命周期保持原范围。

新增离线检查覆盖固定公共目录/公布端口、ICMP 失败与 mapped IPv6、端点路由、预算启动顺序/不足/失败结算、仅回收自有子进程、重复重传与低负载/首尾控制门禁、证据摘要和总控提前分发。复用原有有效窗口解析、profile 生成及受管生命周期 fixture。

实现提交 `8a59688664883cf55f734bbb5b595220471f5309` 的 [Linux CI](https://github.com/alieismy/debian-vps-tuning/actions/runs/36374065438) 已通过：Python 56 项通过、0 跳过，主静态与 HTB 套件、生成/资产一致性、root 安装生命周期、共享预算及 rc.16/17/18/19 → 0.2.0-rc.1 迁移 fixture、共享 benchmark 进程组超时回收、ShellCheck 0.11.0。安装使用 runner 的临时目录；迁移的 profile/boot ID 为合成值，进程用例使用假 iperf3 与真实 Linux 子进程，不访问公共服务。

2026-09-28，经授权在一台 Debian 13/x86_64 主机完成[单机低流量功能验收](automatic-measurement-acceptance-2026-09-28.md)：自动选择公共 IPv4 端点，1/2 Mbps 的 9 个样本完整有效；报告和预算结算通过；另用 loopback 真实 iperf3 完成 SIGINT/SIGTERM 清理，最终无预留/进程/监听残留，17 项受管 sysctl、qdisc/class 与原状态等观察一致。该运行证据独立于 CI fixture。

更多节点/平台、IPv6、高速区间、公共路径信号中断、真实安装/迁移/重启生命周期和业务效果仍未验收。完整结果与剩余边界记录在[项目备忘](project-memo.md)。发布和后续通用临时 HTB 不因本次有限验收通过而自动启动。

## rc.19 增量验证范围（2026-09-22）

rc.18 于 2026-09-15 发布，tag 指向 `79fc9957fcd9898a39f47f3ca3a348d1727b6b47`；rc.19 是独立 Pre-release。下表原有 rc.18 测试记录保留其历史证据效力，不能证明 rc.19 的目标机运行或业务验收。当前执行器、安装器与受管版本检查使用 rc.19；离线校准器 0.1.1 允许 rc.17/rc.18/rc.19 的同一严格证据契约，HTB 离线分析仍维持 rc.18/rc.19 边界。

2026-09-27，[v0.1.0-rc.19](https://github.com/alieismy/debian-vps-tuning/releases/tag/v0.1.0-rc.19) 已以固定提交 `9e4dd08862dff9707d26e0d50f66e36cfcb93dd6` 发布为 Pre-release；master 与 annotated tag 的 Linux CI 均通过。公开后通过无认证 URL 逐项重新下载并核验 19 个资产及 17 项清单摘要；[项目备忘](project-memo.md)记录发布后结果。该结果不证明目标 VPS 上的 rc.19 安装/迁移、重启恢复、代理业务或性能收益。

2026-09-24 本地 rc.17 兼容增量（当时状态）：先补回归，旧实现 28 个校准器测试出现 1 个 rc.17 接受用例错误；修改后全部 Python 33 项中 32 项通过，真实 flock 因 Windows 缺命令 skip 1 项。新增覆盖三版接受及来源保留/输入不变、rc.16/rc.20 拒绝、rc.17 末样本版本/脚本摘要/boot/状态变更拒绝。截至当日，增量尚未提交或跑新 Linux CI，真实 probe 也尚待采集；后续进展见下一段和[项目备忘](project-memo.md)。

2026-09-27 真实目录核验：用户提供一份 rc.17/iperf3 3.18 的完整三样本 IPv4 上传 probe，顶层与各样本摘要链通过，三次窗口有效且发送端重传为 0；本地校准器 0.1.1 对 67 个文件只读分析、退出 0，前后文件摘要不变。用户确认该端点代表主要 VPS 出向路径后，同一证据的离线决策为 `KEEP_CURRENT_CEILING`（当前及候选均为 16 MiB），不是自动参数应用或业务性能验收。对端临时入口已撤销，被测端共享窗口两笔记录均 `COMMITTED` 且 `reserved_bytes=0`；具体证据与限制见[项目备忘](project-memo.md)。

| 增量 | 验证入口与判据 | 运行边界 |
|---|---|---|
| 离线实测校准 | `tests/test_calibrate_probe.py`：双层摘要链、清单/引用样本集合、方向与 aggregate 计数、raw/meta 时长和预热绑定、重复采样上下文、raw/summary/row 对照、实际窗口容差、方向/时效/RTT 缺失、路径漂移、资源封顶、保留上限与候选输出；CLI 证据矛盾退出 2 且无报告，证据不足退出 0 且候选为 null | 无网络、无配置写入；包含自洽摘要的 SC-01/SC-02 反例，fixture 不证明真实性能或所有 iperf3 版本兼容性 |
| receiver 背离提示 | `tests/test_shell_adoption.py` 与 HTB 独立套件：sender 提高、receiver 降低时有提示；无效窗口或 reference 漂移不判断；shortlist 不变 | 描述性人工复核，不是自动生产选速 |
| swap 管道 | `tests/test_shell_adoption.py`：合法长路径列表、空列表、生产者失败 | Windows Bash 输出 fixture，不是实际 swapon 生命周期 |
| 锁诊断 | `tests/test_shell_adoption.py`：PID/starttime、持锁时间、陈旧/无效内容、竞争者不截断；有 flock 的 Linux 另外运行真实文件锁竞争 | Windows 缺 flock 时明确 skip；Linux 结果须单独记录 |
| 版本与派生资产 | `tools/render_profiles.py --check`、`tests/static-check.sh`、installer/迁移套件、摘要链及 pinned ShellCheck | 本地/CI/目标 VPS 分别报告；rc.18 公开资产不改写 |
| rc.19 迁移来源边界 | `tests/rc18-check.sh`：分别执行 rc.16/rc.17/rc.18→rc.19；核对来源/state hash、prepare 不改 state、rollback 清除旧 state、两次 boot ID 不变时拒绝且保持阶段/状态、最终 COMPLETE/VERIFIED；拒绝 rc.19/rc.20 来源并检查具体版本诊断及无 checkpoint 写入 | rc.17/rc.18 来源已有原发布 CI 证据；新增 rc.16 来源通过 [PR #22 CI](https://github.com/alieismy/debian-vps-tuning/pull/22/checks) 和[合并提交的 master CI](https://github.com/alieismy/debian-vps-tuning/actions/runs/36322058024)。boot ID 为模拟值，不代表真实重启验收 |

新增 Python 用例已并入原静态入口；使用说明见 [实测校准第一阶段](measured-calibration.md)。本轮实际结果与未完成门禁以 [项目备忘](project-memo.md) 的最新记录为准。

2026-09-23 外部审查发现并修复顶层 manifest 与子控制文件布局不匹配的问题；回归直接执行 `dvt-probe.sh` 的文件筛选表达式，并覆盖子控制文件缺失、篡改、清单与标记协同篡改、INCOMPLETE 和总读取上限。修复提交 `36390d2d9e65dcc67322d189c9347c0bbfca49aa` 的 [PR CI 35851155712](https://github.com/alieismy/debian-vps-tuning/actions/runs/35851155712) 全部通过，Python 30 项无跳过；旧 27 项测试通过记录不能替代此次 producer/consumer 契约验证。

2026-09-22，[Linux CI 35717516096](https://github.com/alieismy/debian-vps-tuning/actions/runs/35717516096) 对提交 `53951ec48a72935cab1fec5f4d38aa174bb8a0cc` 全部通过：27 个 Python 测试无跳过（包括真实 flock 竞争）、完整静态/HTB 套件、root installer、两条迁移来源 fixture、预算/benchmark 进程 fixture 和 ShellCheck 0.11.0。该证据不证明真实 probe 输入兼容性、目标 VPS 重启/恢复或性能收益，也不构成发布批准。

## 证据分层

验证结果必须分为：

1. 本地静态检查；
2. 同源模板与六个操作系统/内存变体的一致性；
3. 目标 VPS 运行、重启和回滚；
4. 3X-UI/Xray 与客户端业务连接；
5. 有预算的性能或网络机制研究。

各层不能相互替代。静态检查通过不证明 BBR、qdisc、swap、重启持久性或代理连接成功；
业务连接通过也不证明公网性能改善；研究样本不自动成为每台 VPS 或每个版本的发布门禁。

## 默认验收路径与研究边界

业务 VPS 的默认安装、升级和日常验收只要求 L0–L2/L3 中与该机相关的确定性门禁：固定资产
校验、只读基线、`preflight`、`apply`、重启后 `verify`、严格代理服务验证和少量真实客户端
业务冒烟。无主动流量的 `diagnose` 是症状诊断首选。

`benchmark`、`dvt probe`、TcpQuality、HTB200 reference、candidate sweep、A/B/A 和反向窗口
属于 L4 研究通道，不是跨版本迁移、每台 VPS 或稳定版的默认必做项。只有同时满足以下条件
才重新启用：存在可复现业务症状或明确性能主张；实验会改变真实决策；使用独立高额度测试机
和获授权 endpoint；执行前批准包含协议开销余量的硬流量预算与停止条件。失败不得无条件重试。

### 2026-09-11 当前 Basic 运行证据状态

VMISS Basic 的三次 HTB200 单流 IPv4 reference 已完成并关闭。三次样本约为
187–190 Mbit/s，sender retransmits 和主机级 `TcpRetransSegs` 增量均为 0，HTB root 与
FQ leaf 的 drops/requeues 均为 0，HTB root `overlimits` 为正；schema 3 测量窗口、root/leaf
qdisc totals、资源门禁、摘要链、HTB 停止和根 `fq` 恢复均已在该归档范围内通过。endpoint
closeout 也已完成：listener、`iperf3` 进程、transient unit 和临时 UFW 规则已清理，其他
UFW 规则未变化。该证据只覆盖本次 Basic reference 和 endpoint 生命周期，不覆盖默认 `fq`
对照、A/B/A、Core、真实 VLESS + REALITY + TCP 或持久化行为；因此 C29–C32 的本地 fixture
与受控 Basic 子集可记录为已复核，但目标机通用 L4 门禁仍按逐项矩阵保持未完成。candidate
sweep 已停止，不得把 reference 完成解释为后续流量或默认/持久 HTB 授权。

厂商预装 BBR/fq 时，运行值、持久化来源和配置所有权分别取证。`preflight` 可作为只读审计：
兼容的唯一 `/etc/sysctl.conf` 基线可选择由项目事务化接管，也可停在审计后保持厂商配置；
复杂或重复外部定义必须阻断。跨版本只能由旧版固定资产执行受管 rollback/purge 后重新安装
最新版，或在备份和控制台均已验证时干净重装；不得由新版覆盖旧 state 或手工删除受管资源。

## 总控入口验证矩阵

`debian-vps-tuning.sh` 只负责选择、校验和调用，但它决定最终执行哪一份 root 脚本，因此必须独立验证。控制器通过不代表目标 profile 或 VPS 生命周期通过。

| ID | 场景 | 预期结果 | 当前状态 |
|---|---|---|---|
| C1 | Debian 12/13，1 vCPU，384/512/767 MiB | 选择对应 `1c512m` profile，资源档 `1C512MB` | fixture 通过 |
| C2 | Debian 12/13，1 vCPU，768/1024/1535 MiB | 选择对应 `1c1g` profile，资源档 `1C1GB` | fixture 通过 |
| C3 | Debian 12/13，1 vCPU，1536/2048 MiB | 选择兼容 `1c2g` profile，资源档 `1C2GB` | fixture 通过 |
| C4 | Debian 12/13，2 vCPU，1536/2048 MiB | 选择兼容 `1c2g` profile，资源档 `2C2GB` | fixture 通过 |
| C5 | 非 Debian、非 amd64、超范围内存、2C512、2C1G 或 3C2G | 返回不支持，不调用 profile | fixture 通过 |
| C6 | 交互带宽直接 Enter | 使用 200 Mbps | fixture 通过 |
| C7 | `--port` 和 `PORT_SPEED_MBPS` | 只接受 100–1000，显式参数优先 | fixture 通过 |
| C8 | 清单缺失、重复条目、哈希不匹配 | 返回完整性错误，不调用 profile | fixture 通过 |
| C9 | curl 失败、404、超时或中断 | 返回下载错误，不回退其他来源 | fixture 通过；目标 VPS 的真实下载失败路径未注入 |
| C10 | profile 返回非零 | 控制器返回同一退出码 | fixture 通过 |
| C11 | `guided` | preflight 通过后询问；N/Enter 不 apply | rc.9 Debian 13 1C1G/1000 Mbps 的确认后 apply 路径通过；拒绝路径 fixture 通过 |
| C12 | 菜单 `apply` | 再次确认；N/Enter 不 apply | 目标 VPS 待测 |
| C13 | 无 TTY 且无 action | 返回 usage，不等待输入 | 目标 Linux 待测 |
| C14 | 状态档位与检测档位不一致 | 阻断，不自动换 profile | fixture 通过；目标 VPS 待测 |
| C15 | 固定 rc.18 Release assets | 外层固定 installer 摘要；installer 固定清单摘要；下载清单、总控、六份 profile、预算/迁移/证据/CLI/HTB 资产并逐项通过 SHA-256 | rc.18 已发布并完成当时的 19 个公开资产反向核验；rc.19 须在其独立 Release 发布后另行公开重下载，不能继承 rc.18 结果 |
| C16 | 已安装状态下无 `--port`/环境变量地重复 `apply` | 复用状态中的端口带宽；显式参数仍优先；无效状态值阻断 | fixture 通过；目标 VPS 待测 |
| C17 | `diagnose` | 默认 5 秒前后采样；输出 TCP/softnet、整机 CPU、接口和可识别 ethtool 错误增量；只读显示 TCP 非受管值、qdisc、队列、RPS/XPS/IRQ、Xray sockopt、代理进程资源和 IPv4/IPv6 policy rules；自定义 rule 才展开对应地址族全部路由表并警告常规网卡发现边界；无系统写入、主动流量或进程命令行 | CPU/接口增量、非受管 TCP 值、默认/自定义/不可读 policy rule 与条件路由表 fixture；目标 VPS 待测 |
| C18 | `benchmark` 未提供 host、iperf3、`setsid` 或 GNU `timeout`，无效端口/时长/预热/并行/地址族/run ID/1–300 秒 phase timeout，或输出目录非绝对路径/已经存在 | 明确拒绝；不覆盖旧证据，不安装软件、不改防火墙、不选择公共服务器 | 参数、timeout 和输出目录 fixture；目标 VPS 待测 |
| C19 | 用户授权的 `benchmark` | 仅向指定 iperf3 服务端执行 upload/download/both；每方向独立进程组和硬超时，TERM 后 5 秒升级 KILL；保存原始 JSON、sender/receiver、host-wide 计数、root/leaf qdisc 与 `policy-routing.txt`；校验测量窗口并以 `INCOMPLETE → COMPLETED` 提交哈希链 | schema 3 窗口、异常 JSON/计数器、mq leaf、HTB `parent 1:10`、HTB 缺叶、root 零 drop/leaf 非零 drop、manifest 失败、timeout 返回码、持久元数据和进程组回收 fixture；rc.17 目标机的一条 IPv4 上传路径已形成真实完整证据，见[项目备忘](project-memo.md)；其他方向、端点、版本和业务路径仍待测 |
| C20 | `update` 自动发现/`--target` | 同一 `major.minor` 内，rc 通道可选更高 rc 或稳定版，稳定通道排除 prerelease；显式目标允许跨线或 prerelease；拒绝降级和重复升级 | 版本优先级、稳定/rc 通道、非法版本 fixture 通过；GitHub API 真实查询待测 |
| C21 | `update` 只读升级检查 | 校验当前/目标资产，当前 verify、目标 `UPDATE_PREFLIGHT=1 preflight` 通过后输出固定 URL、哈希、端口和人工迁移顺序；不得调用 rollback/purge/apply/reboot | 调用顺序 fixture 与真实 `check_preflight_state` 状态矩阵通过；目标 VPS 只读 update 待测 |
| C22 | `/etc/sysctl.d` 等外部文件以相同值重复定义受管 key | `preflight`/`apply` 阻断；已安装状态的独立 `verify` 返回非零；`diagnose` 只读报告；项目自身文件及其符号链接不误报 | 同值冲突、受管文件别名和外部别名去重 fixture 通过；目标 VPS 负向注入不在生产机执行 |
| C23 | 旧总控与新版本 `SHA256SUMS`/profile 同目录 | 返回完整性错误，提示可能混用不同 Release 并要求独立目录；不得联网回退或修改系统 | 混合版本目录 fixture 通过；Debian 13 rc.9→rc.10 实测安全拒绝并通过隔离目录恢复 |
| C24 | `diagnose`/`benchmark` 在硬超时、`INT`/`TERM` 或其他异常中断 | 返回非零/对应信号退出码；timeout 在 TERM 已结束命令时通常为 124，需要 `--kill-after` 升级到 KILL 时可为 137；benchmark 回收隔离进程组，临时模式清理本次目录，持久模式保留含 stage/exit code 的 `INCOMPLETE`；只有完整提交才存在 `COMPLETED`；预算未知量按计划上界结算 | manifest 失败终态、timeout 124、TERM→KILL 137、实际进程组回收和 trap 结构 fixture；目标 VPS 真实信号待测 |
| C25 | 固定 TcpQuality 证据工具 | release tag、commit、三个脚本、rootfs manifest、rootfs 大小/哈希及内部 TCP_INFO/eBPF 审计元数据均一致；显式选择本地/公开模式并确认上游临时防火墙计数链；拒绝覆盖；每轮恰好一个 CSV 和 debug archive；提取流级指标来源，`nstat` 标记 `MEASUREMENT_DEGRADED`；节点响应通过 12 列 TSV schema；保存节点/CSV/debug 哈希、漂移、实际 URL、主机状态、原始日志和最终清单；任一关键步骤失败即停止；不调用本项目 apply | pinned/模式/确认/解析器 fixture、节点 schema/漂移和包装层静态门禁通过；完整 rootfs 的计数链创建/清理与中断恢复待目标 VPS 验证 |
| C26 | 厂商 `/etc/sysctl.conf` 唯一且相同值的 `fq`/`bbr` 基线 | `preflight` 零写入并报告 `PASS_WITH_PROVIDER_SYSCTL_TRANSFER`；`apply` 提交 schema 4 状态后完整备份并原子迁移；`verify` 校验原始/迁移后哈希；`rollback` 恢复原文件和安装前运行值；外部修改时拒绝覆盖并保留 `DEGRADED` | 只读分类、迁移/恢复、外部修改拒绝和 schema 3 仅限 update-preflight fixture 通过；Debian 12/13 目标 VPS 生命周期待测 |
| C27 | benchmark 流量预算与 opt-in pacing | 显式 `BENCHMARK_RATE_CAP_MBPS` 优先，否则只使用合法管理状态端口上限；按 `(seconds+omit)×方向数` 预留 payload；成功提交 sender bytes，失败、信号或超时按计划上界保守结算；只有 `BENCHMARK_ENFORCE_RATE_CAP=1` 才传递逐流 `--bitrate` | cap/公式/bitrate/持久元数据和失败保守结算 fixture；计费流量、真实吞吐和实际限速精度不由 fixture 证明 |
| C28 | HTB 实验排程生成器 | 只输出 schema 2 JSON；每次调用必须显式提供安全 `window-id`，且只能生成一个 `aba`（A1/B1/A2）或 `bab`（B2/A3/B3）三阶段窗口；反向窗口必须使用不同 ID、新证据目录和独立 operator invocation；至少 300 秒冷却，候选结论关闭后才可另建低速 A/C/A；不得执行 qdisc、流量或持久化 | `aba`/`bab` 独立窗口、缺少 ID、旧 `--repeat-cycles 2` 拒绝、180 Mbit/s 控制、非法冷却和非法控制速率 fixture 通过；目标机执行仍按独立 SOP 门禁 |
| C29 | HTB v0.4.0 执行器基线绑定 | 只接受 rc.18 schema 4、`VERIFIED`、200 Mbps 的 Debian 13 1C1G/1C2G；允许临时 100–200 Mbit/s，其中 200 仅用于端口额定 reference；活动状态保存实际 profile 和 managed-state SHA-256；profile/state 漂移、旧版本、超过端口或其他端口必须拒绝继续 | 两个允许 profile、100/200 边界及 profile/schema/version/port/hash/201 负向 fixture 通过；Basic 1C1G 的 rc.17 reference 绑定和恢复只作为历史归档，不继承为 rc.18 运行验收；1C2G smoke/A/B/A 仍待执行 |
| C30 | HTB reference/candidate 只读计划 | schema 3；默认 `reference-screen` 只生成 2–5 个 HTB200 样本且拒绝 `--rates`；显式 `candidate-sweep` 必须 ack 并绑定已复核 reference 的 manifest/analysis/completion 摘要，只接受 3–8 个唯一 100–199 Mbit/s 候选，在首尾生成相同 HTB200 reference 并正序/反序扫描；每阶段 `rate_cap_mbit == rate_mbit`，预算按实际 HTB rate/ceil 求和；sender 最低速率暴露比例、CPU idle/steal 和 softnet/interface 零异常要求必须冻结为 plan controls；不读取主机、不执行流量 | 计划与负向 fixture 通过；Basic 三次 HTB200 reference 已执行并关闭，未生成或执行 candidate-sweep；新的 candidate 计划仍需独立授权 |
| C31 | HTB reference/candidate runner | 要求 root 所有且不可被 group/world 写的固定计划、profile、稳定 HTB 工具和分析器；流量前 verify 并冻结 managed 绑定；每阶段执行 preflight→start→ACTIVE→受预算 benchmark→ACTIVE→stop→postflight；失败即停并尝试受管恢复 | mock 生命周期、绑定/hash/socket 隐私和超时进程组 fixture 通过；Basic 三次真实 reference 的 runner、endpoint 收尾和根 `fq` 恢复已在归档中复核；runner 信号中断、其他目标 VPS 和通用 A/B/A 仍待测 |
| C32 | HTB reference/candidate 分析 | 校验 source reference 摘要、session managed binding、每阶段 schema 3、COMPLETED、benchmark manifest/result hash、benchmark profile/script/state 绑定和 schema 3 测量/qdisc 契约；严格拒绝重复、缺失或非数字 CPU/softnet 计数；主吞吐使用 sender Mbit/s，重传使用 sender retransmits/GiB；每个样本必须有正 HTB root `overlimits`、完整 HTB→FQ 叶子、root/leaf drop/requeue 全零、达到冻结速率暴露比例并通过 CPU/softnet/接口门禁；旧摘要、缺字段或任一门禁异常均输出 `REVIEW_BLOCKED` 且 shortlist 为空 | 合成正/负 fixture 通过；Basic 三次样本的 schema 3、窗口、root/leaf 健康、重传和资源门禁已通过并形成 reference 结论；default-fq 对照、跨窗口复验和候选统计仍未完成 |
| C33 | 总控 `reconfigure` 参数与分派 | CLI 必须显式提供 `--port 100..1000`；默认值或 `PORT_SPEED_MBPS` 环境变量不能代替目标参数；菜单选项再次确认；只向选定的同版本 profile 透传目标端口和 `reconfigure` action | 参数、菜单和透传 fixture 待最终门禁；目标 VPS 待测 |
| C34 | profile 带宽重配置语义 | 只接受同一 rc.18/profile 的 `VERIFIED` 状态；先复算旧 buffer 契约并执行完整 verify；同值无写入；自动 buffer 随端口重算，显式 buffer 保留；有效值不变时不执行 `sysctl -p`，有效值变化时只应用项目 sysctl 文件；qdisc/swap/journald/NOFILE 不变 | 无状态、状态不一致、同值、100→200、200→500、500→200、显式 buffer 与候选验证 fixture；目标 VPS 与重启持久性待测 |
| C35 | `RECONFIGURING` 事务与恢复 | 旧 state/sysctl 固定 root-only 备份及 SHA-256 有效后才提交事务；候选状态、网络值、managed hash 和变化分类一致；失败自动按旧 sysctl→完整 verify→旧 state 顺序恢复；恢复失败保留 `DEGRADED`、备份和失败证据；普通 `verify`/`rollback`/`preflight`/`apply` 不得越过，手工 `recover` 只处理合法事务 | 元数据、备份篡改、失败注入、自动恢复、恢复失败和阶段门禁 fixture 待最终门禁；目标 VPS 故障注入待测 |
| C36 | `mq 0:` 叶 qdisc 转换与恢复 | 全 `fq_codel` 时选择无冲突的非零根 handle，重建后重新读取并保持 queue minor 集，再逐叶替换为 `fq`；已经全 `fq` 时无写入；混合自定义 `fq`/`fq_codel` 时在任何写入前拒绝；回滚用当前根 handle 与保存 minor 重建可寻址 parent；仅同一 `mq` 队列的 `:N`、`0:N`、`MAJOR:N` 可语义等价，ingress/clsact 保持独立 | 状态化 fake-`tc` 转换/无操作/拒绝/显式 handle/失败/漂移 fixture 与保存快照恢复 fixture 已通过；OCI A1 实机 `tc` 生命周期、驱动队列变化和重启持久性待测 |

本地检查入口：

```bash
python tools/render_profiles.py --check
bash tests/controller-check.sh
bash tests/static-check.sh
bash experiments/htb-aggregate/tests/static-check.sh
sha256sum -c SHA256SUMS
sudo bash tests/installer-check.sh
sudo bash tests/rc18-check.sh
shellcheck -x \
  debian-vps-tuning.sh \
  debian12-1c512m-vps-tuning.sh \
  debian12-1c1g-vps-tuning.sh \
  debian12-1c2g-vps-tuning.sh \
  debian13-1c512m-vps-tuning.sh \
  debian13-1c1g-vps-tuning.sh \
  debian13-1c2g-vps-tuning.sh \
  tcpquality-evidence.sh \
  dvt-traffic-budget.sh \
  dvt-migrate.sh \
  install.sh \
  dvt-probe.sh \
  dvt-htb.sh \
  experiments/htb-aggregate/htb-aggregate-experiment.sh \
  experiments/htb-aggregate/experiment-plan.sh \
  experiments/htb-aggregate/rate-sweep-plan.sh \
  experiments/htb-aggregate/rate-sweep-run.sh \
  experiments/htb-aggregate/rate-sweep-analyze.sh \
  tests/static-check.sh \
  tests/controller-check.sh \
  tests/installer-check.sh \
  tests/rc18-check.sh \
  experiments/htb-aggregate/tests/static-check.sh
```

当前主程序发布后必须从公开 Release 下载清单内 24 项运行资产、installer 和清单共 26 个资产，在与仓库不同的独立临时目录复核 installer/manifest 固定摘要并对全部 24 个 manifest 条目执行 `sha256sum -c SHA256SUMS`。五个实验脚本按清单相对路径放入 `experiments/htb-aggregate/`；GitHub 上传资产使用 basename 平铺。公开重下载未完成时，不得把远程资产验证标为通过；发布结果以实际 Release 和后续核验记录为准。历史 rc.18/rc.19 的 19 资产、17 清单项数量保留于各自日期化记录。

## 首发目标机矩阵

下表是必须取得证据的目标矩阵，不是已经完成的测试结果。没有真实 VPS 回填证据前，不得把状态改为“通过”。

| ID | 系统 | 资源 | 磁盘/根文件系统 | 端口 | 内核基线 | 定位 | 状态 |
|---|---|---|---:|---:|---|---|---|
| T1 | Debian 12 | 1C1G | 10 GB / XFS | 200 Mbps | `6.1.0-51-cloud-amd64` | 主力/首要门槛 | rc.8 退出、rc.10 apply、重启严格 verify、重复 apply 通过；最终修复哈希待目标机复核 |
| T2 | Debian 12 | 1C2G | 15 GB / XFS | 200 Mbps | `6.1.0-51-cloud-amd64` | 主力/首要门槛 | 旧状态经 rc.8 profile 退出、rc.10 apply、重启严格 verify、重复 apply 通过；最终修复哈希待目标机复核 |
| T3 | Debian 13 | 1C1G | 约 10 GB / ext4 | 200 Mbps | `6.12.100+deb13-cloud-amd64` | 系统兼容 | rc.11 preflight/apply、立即与重启 verify、幂等门禁及历史 TcpQuality S1/S2 通过；后续 HTB campaign 已降为研究专用，不再作为该机升级门禁 |
| T4 | Debian 13 | 1C2G | 15 GB / ext4 | 200 Mbps | `6.12.101+deb13-cloud-amd64` | 系统兼容 | rc.12 profile 哈希绑定的 preflight/apply、立即与重启后 verify、重复 apply 通过；TcpQuality/HTB 双窗口已降为研究专用，不再作为逐机验收门禁 |
| T5 | Debian 12/13 | 1C1G | 10 GB / XFS 或 ext4 | 100 Mbps | 以实机为准 | 低带宽边界 | Debian 12 v5→rc.10 路径通过；Debian 13 rc.12 本地候选完成错误参数拒绝、purge、apply、重启 verify 和幂等门禁；最终修复哈希及严格代理验证待复核 |
| T6 | Debian 13 | 1C1G | 容量未采集 / ext4 | 1000 Mbps | `6.12.100+deb13-amd64` | 高带宽边界 | rc.9 完整退出和 swap 所有权迁移、rc.10 apply、重启严格 verify、BBR/fq/swap、重复 apply 通过；最终修复哈希待目标机复核 |
| T7 | Debian 12 | 2C2G | 以实机为准 | 200 Mbps | `6.1.x`，以实机为准 | 2C2G 资源契约 | 待执行 |
| T8 | Debian 13 | 2C2G | 以实机为准 | 200 Mbps | `6.12.x`，以实机为准 | 2C2G 系统兼容 | 待执行 |
| T9 | Debian 12 | 1C512MB | 以实机为准 | 200 Mbps | `6.1.x`，以实机为准 | 最小内存边界 | 待执行 |
| T10 | Debian 13 | 1C512MB | 以实机为准 | 200 Mbps | `6.12.x`，以实机为准 | 最小内存系统兼容 | 待执行 |

T1、T2 必须通过才能发布首个稳定版；T3、T4 是 Debian 13 稳定版门槛；T5、T6 用于确认 100–1000 Mbps 输入边界，不能用 200 Mbps 的结果代替。T7、T8 用于证明同一 `1c2g` 兼容 profile 在 2 vCPU 下的完整生命周期；T9、T10 用于证明 512 MiB 的缓冲截断、journald、swap 和 3X-UI 生命周期。本地 fixture 不能替代目标机证据。这些门槛验证的是生命周期、恢复和业务可用性，不要求在每台目标机重跑 TcpQuality、HTB reference、candidate sweep 或 A/B/A；只有发布说明准备作出相应性能或整形主张时，才另行要求 L4 研究证据。

上述目标机结果绑定测试时日志中的具体版本与 SHA-256。rc.18 不改变 rc.17 写入的 17 个 sysctl、swap、journald、NOFILE、预算或迁移状态契约，但会修正 `mq 0:` 的 qdisc 句柄处理，且 profile 版本和哈希已经变化，不能继承为 rc.18 目标机通过结论。当前环境没有目标 VPS 的 SSH 凭据，rc.18 最终哈希的首次生命周期、rc.17→rc.18 迁移、真实 OCI `mq 0:` 应用/回滚、重启持久性和真实代理链路均不能由本地或 CI fixture 冒充。

## rc.18 自动缓冲矩阵

该矩阵验证的是输入算法和资源上限，不是吞吐结论。目标 RTT 为 200 ms；512M/1G/2G 的自动目标分别为 1×/1.25×/1.5×BDP，再向上取 16/32/64 MiB 档。

| 资源档 | 100 Mbps | 200 Mbps | 500 Mbps | 1000 Mbps | fixture |
|---|---:|---:|---:|---:|---|
| 1C512MB | 16 MiB | 16 MiB | 16 MiB | 16 MiB + 截断警告 | 1000 Mbps 通过；其余待补 |
| 1C1GB | 16 MiB | 16 MiB | 16 MiB | 32 MiB | 100 Mbps 目标机候选通过；200/500/1000 Mbps fixture 通过 |
| 1C2GB/2C2GB | 16 MiB | 16 MiB | 32 MiB | 64 MiB | 200/500/1000 Mbps 通过；100 待补 |
| 2C2GB | 16 MiB | 16 MiB | 32 MiB | 64 MiB | 与 1C2GB 共用算法；控制器 CPU fixture 通过，目标机待测 |

rc.18 保持 rc.17/rc.16/rc.15/rc.14/rc.13/rc.12/rc.11/rc.10 的该矩阵。跨脚本版本时仍必须先通过只读 update 检查，再人工执行 rollback → reboot → preflight → apply → reboot → verify 建立同版本状态，不得用 `reconfigure` 接管旧版本 state。只有同一 rc.18 profile 的 `VERIFIED` 状态在服务商端口变化后才能重配置：100→200 Mbps 等价于保持 16 MiB；2G 档 200→500 Mbps 变为 32 MiB，500→200 Mbps 恢复 16 MiB。fixture 只验证推导、事务和恢复逻辑，不证明目标 VPS 的实时 sysctl、生效持久性或性能。

## 每台目标机的生命周期矩阵

每一行都要分别在 T1–T10 回填“通过/失败/不适用”、执行时间、脚本 SHA-256 和脱敏证据路径。任一失败都应保留退出码和错误输出。

| 阶段 | 操作 | 关键判据 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M0 | 基线采集 | OS、内核、CPU、内存、根文件系统、磁盘、双栈、qdisc、swap 可追溯 | 待执行 | 待执行 | 待执行 | rc.12 通过 | 待执行 | 部分完成，磁盘容量与地址未采集 | 待执行 | 待执行 | 待执行 | 待执行 |
| M1 | 未安装状态执行 `verify` | 退出码 5；提示先运行 `preflight`/`apply`；无系统写入 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M2 | `preflight` | 退出码 0；识别资源档和文件系统；无系统写入 | 待执行 | rc.7 通过 | 待执行 | rc.12 通过（含厂商 sysctl 迁移门禁） | rc.12 修正前候选通过 | rc.9 通过 | 待执行 | 待执行 | 待执行 | 待执行 |
| M3 | `apply` | 退出码 0；状态为 `VERIFIED`；含 NOFILE drop-in，swap/qdisc 符合预期 | 待执行 | rc.7 通过 | 待执行 | rc.12 通过 | rc.12 修正前候选通过 | rc.9 通过 | 待执行 | 待执行 | 待执行 | 待执行 |
| M4 | 立即 `verify` | 退出码 0；sysctl、qdisc、journald、swap、drop-in 一致 | 待执行 | rc.7 通过 | 待执行 | rc.12 通过 | rc.12 修正前候选通过 | rc.9 通过 | 待执行 | 待执行 | 待执行 | 待执行 |
| M5 | 重启后 `verify` | 退出码 0；BBR、fq、sysctl、swap 持久 | 待执行 | rc.7 通过 | 待执行 | rc.12 通过 | rc.12 修正前候选通过 | rc.9 通过 | 待执行 | 待执行 | 待执行 | 待执行 |
| M6 | 重复 `apply` | 退出码 0；报告无需重复写入；无重复 fstab/unit | 待执行 | rc.7 通过 | 待执行 | rc.12 通过 | rc.12 修正前候选通过 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M7 | 安装 3X-UI 后严格验证 | `REQUIRE_PROXY_SERVICE=1 verify` 通过；x-ui/Xray 运行时 NOFILE ≥ 65536 | 待执行 | rc.7 通过 | 待执行 | 待执行 | 待执行 | rc.9 安装后及再次重启后通过 | 待执行 | 待执行 | 待执行 | 待执行 |
| M8 | VLESS + REALITY + TCP | IPv4/IPv6 按实际能力建立连接；连续传输无异常 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M9 | 普通 `rollback` | 恢复 qdisc/sysctl，删除 drop-in；脚本 swap 默认保留；状态可追溯 | 待执行 | rc.7 实际恢复通过；rc.8 后置验证待复测 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M10 | 回滚后重启 | `status` 正确；无残留 unit/sysctl/journald/drop-in | 待执行 | rc.7 通过 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M11 | 显式 purge | `swapoff` 成功才删除 swap/fstab 行；失败时保留证据 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M12 | 业务负载期间 `diagnose` | 记录 TCP/softnet/CPU/接口/ethtool、qdisc、队列/IRQ、Xray、代理进程及 policy rules；自定义规则时记录对应全部路由表；无配置写入 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M13 | 授权 iperf3 benchmark | 固定 endpoint/地址族/时长/run ID/新目录；验证进程组硬超时、`policy-routing.txt`、原始 JSON、计数、PASS/COMPLETED/哈希；确认不当作代理业务结果 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M14 | 固定 Release 安装器 | 外层 installer SHA-256、内置 manifest SHA-256、逐资产哈希均通过；版本化目录为 root-owned 且不可被 group/world 写；`current`/`dvt` 原子切换；安装前后 sysctl/qdisc/state 不变 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M15 | advisory-only `dvt probe` | `--plan-only` 零流量；超预算/无授权 host/无 cap 阻断；实际样本固定单流并记录 `rate_cap_enforced=true`；每个样本及顶层证据哈希通过；只输出 `REVIEW_REQUIRED`/`REVIEW_BLOCKED`，state/sysctl/qdisc 不变 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M16 | 同值或有效值不变的 `reconfigure` | 同值只验证无写入；100→200 等 buffer 档位不变时只更新管理文件注释、哈希和 state，不重写运行时 sysctl；qdisc/swap/journald/NOFILE 不变 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M17 | 有效值变化的 `reconfigure` | 2G 档 200→500 自动 buffer 从 16 MiB 变为 32 MiB；500→200 恢复 16 MiB；只通过项目 sysctl 文件应用；完成态为 `VERIFIED`，重启后再次 verify | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |
| M18 | 重配置失败与 `recover` | 在 sysctl 应用、候选验证和恢复步骤注入失败；可恢复路径回到旧 `VERIFIED` 配置；不可完整恢复时保留 `DEGRADED`、事务备份和失败证据，修复外部原因后 `recover` 成功 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 | 待执行 |

状态初始化还必须覆盖 jq 构造器失败路径：状态 JSON 未成功提交时，不得创建 sysctl、journald、helper、unit 或 x-ui drop-in；脚本应删除本次进程创建的 qdisc 快照、JSON 临时文件和空状态目录，并明确报告“未写入系统配置”。

状态兼容性测试必须使用 Debian 12 的 jq 1.6 语义，至少覆盖：0 字节、仅空白、`null`、缺字段对象、多个连续 JSON 对象、jq 编译失败、jq 转换失败和有效单对象。任何无效输入都不得覆盖既有状态。不能只用 jq 1.7/1.8 的 `-e` 空输入退出码证明兼容。

rc.2 空状态的 `recover` 必须拒绝一般损坏 JSON、有效状态、仍存在项目文件、脚本 swap/fstab 行、活动 fq helper 或 qdisc 不一致；成功时只能把状态目录改名隔离，不能删除证据。

已有任何管理状态时，`preflight` 不得输出可直接应用的“通过”：`VERIFIED`/`APPLIED` 应引导执行 `verify` 或先回滚，`SWAP_RETAINED` 应引导显式 purge；`RECONFIGURING` 或带合法 `.reconfigure` 元数据的 `DEGRADED` 必须先执行 `recover`，其他事务状态才要求完成 `rollback`。

独立 `preflight` 的状态阻断不得破坏重复 `apply`：相同参数且状态为 `VERIFIED` 时，`apply` 必须进入验证后无写入返回；参数不同或事务状态不允许时才阻断。

sysctl 校验应比较归一化后的字段值：内核通过 `sysctl -n` 返回的连续空格或制表符只用于显示对齐，不构成配置差异；字段数量或任一字段数值变化仍必须失败。NOFILE 审计必须把 `/proc/<PID>/limits` 的 soft/hard 两列分别输出，不能受脚本全局 `IFS` 影响。未安装 3X-UI 时，已托管 drop-in + 无服务属于正常待安装状态；安装后必须验证 `LimitNOFILESoft`、`LimitNOFILE`、主进程和直接 Xray 子进程，任一运行时 soft 或 hard limit 低于 65536 都失败。

事务阶段顺序必须为 `PREPARED → APPLYING → APPLIED → VERIFIED`。`APPLYING` 必须在首个系统文件写入前提交。`PREPARED`、`ROLLBACK_PENDING` 或 `DEGRADED` 只有在项目文件均不存在、外部 swap 未被脚本接管、当前 qdisc 与快照语义一致且原始 sysctl 已恢复时，才允许直接清理残留状态。

带宽重配置使用独立的 `VERIFIED → RECONFIGURING → VERIFIED` 事务。任何系统文件变化前必须存在可校验的旧 state/sysctl 备份；候选验证未完成前不得删除事务元数据。恢复必须先验证备份路径、类型、所有权、权限、摘要和旧状态语义，再恢复旧 sysctl 文件并应用、按旧状态完整验证，最后原子恢复旧 state。任何一步失败都不得清理恢复证据或把状态报告为 `VERIFIED`。

## qdisc 回归矩阵

自定义 qdisc 测试应在可恢复的测试 VPS 或控制台可救援环境执行。测试前后保存 `tc -j qdisc show`；比较 `kind`、`handle`、`parent` 和 `options`，不能只看 qdisc 名称。

| ID | 初始拓扑 | apply 预期 | rollback 预期 | 状态 |
|---|---|---|---|---|
| Q1 | 根 `fq`，含非默认参数 | 不执行 replace，参数不变 | 不执行 replace，参数不变 | 待执行 |
| Q2 | 根 `fq_codel`，仅含受支持参数 | 切换为 `fq` | 按快照恢复 `fq_codel` 参数 | 待执行 |
| Q3 | 根 `mq`，叶子全为自定义 `fq` | 不替换任何叶子 | 不替换任何叶子 | 待执行 |
| Q4 | 根 `mq`，叶子混合 `fq`/`fq_codel` | 只替换 `fq_codel` 叶子 | 原 `fq` 不动，恢复原 `fq_codel` | 待执行 |
| Q5 | HTB/TBF/CAKE 或未知层次 | `preflight` 阻断，无写入 | 不适用 | 待执行 |
| Q6 | 根 `fq_codel`，`tc` 显示 `limit 10240p`，JSON 时间比整毫秒少 1 微秒 | 切换为 `fq` | 用纯整数 `limit 10240` 恢复；±1 微秒视为语义一致 | 待执行 |
| Q7 | 默认参数、无附加层次的根 `pfifo_fast` | 切换为 `fq` | 恢复根 `pfifo_fast` 并通过语义比较 | fixture 通过；目标机待执行 |
| Q8 | 自定义参数或带附加层次的 `pfifo_fast` | `preflight` 阻断，无写入 | 不适用 | fixture 通过；目标机待执行 |

## 业务性能矩阵

调优脚本不自动生成流量。应使用受控客户端和固定 VLESS + TCP + REALITY 配置，在相同路由时段记录至少三次测试；保留中位数以及异常值，不只保存最好结果。

| 并发 | 目标 | 必记指标 | 通过判据 |
|---:|---|---|---|
| 1 | 单连接起速与稳定吞吐 | 首包/握手时间、5 s/30 s 吞吐、重传、CPU、RSS | 无连接失败；与未调优基线相比不得出现可重复的明显退化 |
| 3 | 一般低并发 | 每连接吞吐、聚合吞吐、p50/p95 RTT、重传、softnet drop/time_squeeze | 三连接持续可用，无队列丢包持续增长 |
| 5 | 典型峰值 | 聚合吞吐、公平性、p95 RTT、CPU steal/system、Xray RSS | 五连接无异常断开；512M 档无 OOM/持续 swap thrash |
| 10 | 设计上限 | 成功连接数、聚合吞吐、p95/p99 RTT、重传、CPU、内存、swap | 10 个连接均建立并持续传输；无 OOM、服务重启或系统失联 |

四个资源档至少各取得 200 Mbps/200 ms 目标下的 1、3、5、10 并发证据。100、500、1000 Mbps 或其他自定义端口值用于带宽边界扩展；高 BDP 线路还要记录实际 RTT 和 profile 是否发生缓冲截断。不同 VPS 的吞吐绝对值不能直接互相替代。

## TcpQuality 重复测试协议

TcpQuality 只作为外部线路观察，不作为 sysctl、qdisc、3X-UI 或代理体验的单独验收。一次测试序列开始前必须固定并保存：

- TcpQuality release tag、commit SHA、三个脚本、`rootfs-manifest.json` 和 rootfs 的 SHA-256；
- 完整命令行以及显式 `-c`、`-s`、`-p`、`TCPQUALITY_MODE` 和运行模式；参数语义必须绑定固定 commit；
- VPS boot ID、内核、profile 脚本 SHA-256、管理状态和 `PORT_SPEED_MBPS`/RTT/BUF_MAX；
- IPv4/IPv6 默认路由、测试开始/结束时间和当前版本 `diagnose` 脱敏日志；
- 本地 debug archive、指标来源和可获得的机器可读结果；公开模式还要保存报告 ID，并记录报告/debug bundle 的上传边界；只有远程图片时必须标记不可复算。

rc.16 的 `tcpquality-evidence.sh` 沿用 rc.13 的固定 TcpQuality 资产和证据契约，必须使用预先固定的本地目录、rootfs SHA-256、显式模式和尚不存在的证据目录；每轮保存唯一 CSV/debug archive、通过固定 schema 校验的 `all`/`tos` 节点前后快照、节点/CSV/debug 哈希、逻辑节点增删、节点 IP 变化、主机状态、`retransmission-evidence.tsv` 和最终 `SHA256SUMS`。只有 `ebpf_*` 或 `tcp_info_*` 来源可用于流级重传比较；`nstat` 回退必须标记为降级，不能用于调优因果判断。旧版整机 `TcpRetransSegs` 裸增量与新版流级百分比不得拼接比较。成功批次必须存在 `COMPLETED` 且不存在 `INCOMPLETE`。节点快照不一致不自动删除证据，但变化节点不得直接进入同节点配对结论；固定本地资产不等于固定远端节点、测速端点、运营商路径或测试时段。

一次 smoke 或同日配对序列至少重复 3 次；要形成性能结论，同一配置还应覆盖低负载、白天和晚高峰，每个时段至少重复 5 次。比较中位数、P95 和异常节点复现率，不比较单次最佳值；工具 commit、节点集合、参数、VPS、内核、profile 或业务负载任一变化都应开始新的序列。即使固定 commit，远端测试节点和运营商路径仍可能变化，不能把时间先后直接解释为脚本因果。

## 已取得的目标机证据

2026-08-16，一台脱敏的 Debian 13.6、1 vCPU、1974 MiB、15 GB ext4、200 Mbps、内核 `6.12.101+deb13-cloud-amd64` 目标机，使用 `debian13-1c2g` rc.12 profile（SHA-256 `4381df00360eea2c0396184c40cb4157d12bd79f204eebdaf06069df609f4f1f`）完成只读 preflight、厂商 `/etc/sysctl.conf` 中 `fq`/`bbr` 归属迁移、apply、立即 verify、重启后 boot ID/受管文件哈希复核和重复 apply 幂等门禁。终态为 schema 4 `VERIFIED`、BBR、根 `fq`、16 MiB TCP 缓冲上限、活动项目 swap 和 active `proxy-vps-fq.service`。该证据覆盖 T4 的 M0、M2–M6；未执行未安装状态 M1、代理严格验证、真实业务、benchmark 或 HTB A/B/A，不得上推为这些阶段通过。

2026-08-02，Debian 12 1C1G、1000 Mbps 目标机使用 rc.6 完成受控空状态恢复，随后 `preflight` 通过。`apply` 已写入并切换到 fq，但 `verify` 把 `tcp_rmem`/`tcp_wmem` 的制表符对齐误判为值不一致，因此事务按设计自动回滚；日志确认“回滚完成，管理状态已清理”。这证明 recover 和该次失败回滚路径通过，不代表 M3 apply 通过，也不代表 rc.7 已在目标机通过。

2026-08-02，Debian 12 1C2G、200 Mbps、已有外部 `/swapfile-3xui` 的目标机使用 SHA-256 `8c241f3a5c58ab34c5d7286621ab52e2552dd17cdeaa4aa1c46137c17d53d7e4` 的 rc.7 完成干净迁移、preflight、apply、立即/重启后 verify、重复 apply、严格 3X-UI verify、rollback、回滚后重启、重新 apply 和最终重启后严格 verify。rollback 立即恢复为功能参数一致的 `fq_codel`，内核自动分配 `handle 8001:`，时间字段回显比快照少 1 微秒；重启后恢复为原始 `handle 0:`、`target 4999`、`interval 99999`。外部 swap 始终保留，x-ui/Xray 始终活动。该证据证明 rc.7 实际生命周期成功，同时暴露其恢复命令后缺少删除状态前语义复核；rc.8 已修复但尚未取得目标机运行证据。

2026-08-03，Debian 13 1C1G、929 MiB、1000 Mbps、ext4、内核 `6.12.100+deb13-amd64` 的目标机使用固定 `v0.1.0-rc.9` Release 总控入口，自动选择 `debian13-1c1g-vps-tuning.sh`，profile SHA-256 为 `9fd70c593b83d41337c6dfcada737855ce583e8bc3451ee8bb5952db850c81c6`。安全引导、preflight、首次 apply 和立即验证均为退出码 0、警告 0；安装 3X-UI 前重启后联网 verify 通过，`proxy-vps-fq.service` 为 loaded/active/enabled，BBR、默认 fq、`eth0` 实际根 fq 和 1024 MiB `/swapfile-proxy` 均保持。安装 3X-UI 后严格 verify 通过，再次重启后严格 verify 仍通过；新 `x-ui.service` 主进程和直接 Xray 子进程 NOFILE soft/hard 均为 65536/65536。该证据覆盖 T6 的 M2–M5、M7 和固定 Release 真实下载，不覆盖 M0 完整基线、M1、M6、M8–M11，也不证明业务性能。

2026-08-06，一台脱敏的 Debian 13 1C1G、200 Mbps、ext4、内核 `6.12.100+deb13-cloud-amd64` 目标机完成 rc.11 `preflight`、apply 后语义与受管文件哈希门禁、重启后 verify 和重复执行幂等门禁。相同固定 TcpQuality commit/rootfs 和 `-c 30 -s 0 -p 16 --all` 参数下，调优前 S1 与调优后 S2 各保存三轮文本、CSV 和节点快照。该证据证明 rc.11 生命周期与采集流程可执行；由于 S1/S2 时点不同、远端节点可变化且没有同时段随机交错对照，不能把组间差异识别为 rc.11 的因果性能收益，也不能替代 rc.12–rc.16 最终哈希验证。

2026-08-07，一台脱敏的 Debian 13 1C1G、967 MiB、100 Mbps、10 GB ext4、内核 `6.12.101+deb13-cloud-amd64` 目标机运行 rc.12 本地候选。已有 500 Mbps 状态时，`apply --port 100` 在系统写入前以退出码 4 拒绝；随后普通 rollback 恢复原 qdisc 并保留项目 swap，显式 `PURGE_CREATED_SWAP=1 rollback` 完成清理。按 100 Mbps 重新执行后，重启后 `verify` 与重复 `apply`/`verify` 均返回 0；运行值为 BBR + fq，1024 MiB 项目 swap 活动，失败 unit 为 0。服务商 minimal 镜像原本不存在 `/etc/sysctl.conf`，preflight、apply 和重启均未创建该文件，状态记录迁移为 `NOT_REQUIRED`。该运行暴露了“参数不一致时请先 rollback”提示会诱导不必要普通回滚，以及不存在文件却记录 `0/0/000` 占位所有权的问题；修正会改变 profile 哈希，因此本记录只作为缺陷复现和修正前候选证据，不能替代最终候选的哈希绑定复核。3X-UI 尚未安装，M7/M8 未覆盖。

qdisc 快照往返测试必须区分显示单位和命令输入：不得把文本输出的 `p` 后缀拼入 `limit`；`memory_limit` 使用 `tc -j` 返回的原始字节整数。`target`、`interval` 和 `ce_threshold` 可容忍 ±1 微秒回显量化差异。快照 `handle 0:` 与内核自动分配的 classless qdisc handle 视为等价；显式非零 handle、kind、parent、root 及其他 options 仍严格比较。恢复命令成功后还必须执行后置语义比较；不一致时保留状态和快照并进入 `DEGRADED`。

## 每台 VPS 的验收顺序

```text
基线采集
→ 总控脚本安全引导/独立 preflight
→ 总控脚本确认后 apply
→ verify
→ reboot
→ verify
→ 重复 apply
→ 安装/启动 3X-UI v3.4.2
→ REQUIRE_PROXY_SERVICE=1 verify
→ VLESS/REALITY 客户端连接
→ rollback
→ reboot
→ status
```

控制器目标机证据必须额外保存：控制器版本、固定 Release tag、自动档位、所选文件名、端口带宽、打印的 SHA-256、底层 action 和最终退出码。使用总控入口不得替代对同一 profile 的独立脚本回归；二者至少各执行一次 preflight、apply、verify 和 rollback。

## 必须保存的脱敏证据

```bash
cat /etc/os-release
uname -a
free -m
df -h /
findmnt -n -o FSTYPE /
ip -br address
ip -4 route show default
ip -6 route show default
sysctl net.ipv4.tcp_available_congestion_control
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
tc -j qdisc show
swapon --show
systemctl status proxy-vps-fq.service --no-pager
systemctl show x-ui.service -p LoadState -p ActiveState -p MainPID -p LimitNOFILE -p LimitNOFILESoft
ufw status verbose
```

不要上传密码、UUID、REALITY 私钥、API Token、TLS 私钥或未脱敏配置。

## 通过条件

- 所有命令退出码符合文档；
- `apply` 后关键验证全部通过；
- 重启后 BBR、fq、sysctl 和 swap 状态保持；
- 重复 `apply` 不产生重复 fstab 行或漂移文件；
- UFW 规则和代理配置不被修改；
- 先调优、后安装 3X-UI 时不需要额外重启；若 apply 时 x-ui 已活动，脚本不主动重启，必须在人工重启服务或主机后再通过严格验证；
- `x-ui.service` 和直接 Xray 子进程运行时 NOFILE soft/hard limit 均不低于 65536；
- VLESS + REALITY + TCP 可以实际建立连接；
- 回滚只删除本项目管理的文件；
- 回滚失败时状态和证据保留；
- 普通回滚保留 swap，显式 purge 只在 `swapoff` 成功后删除。
- 原本已经是 `fq` 的根或 `mq` 叶子在 apply/rollback 后保持原有参数；
- XFS 根文件系统允许创建 swap，已知不适用或未知文件系统只警告并跳过；
- 1/3/5/10 并发业务矩阵无连接失败、OOM、意外服务重启或持续增长的 softnet/qdisc 丢包。

## 失败路径

至少覆盖：四个资源档边界、512M 自动缓冲截断和显式越界拒绝、已有 swap、同名非项目 swap 文件、XFS、已知不适用和未知根文件系统、磁盘不足、sysctl 冲突、厂商相同值 `fq`/`bbr` 的只读分类、事务迁移、故障恢复、外部修改拒绝、schema 3 只读升级兼容、同名非项目 unit/drop-in、带自定义参数的根 `fq`、常规和非常规 `pfifo_fast`、`mq` 下混合 `fq`/`fq_codel` 叶子、qdisc 快照仅 `refcnt` 不同、qdisc 时间回显相差 1 微秒、`fq_codel limit` 文本输出带 `p`、`noqueue`、复杂 qdisc、双栈不同默认网卡、未安装项目状态时执行 `verify`、已有 `DEGRADED` 状态时执行 `preflight`、0 字节/空白/多文档状态、状态 JSON 构造器编译失败、状态转换失败、rc.2 空状态 recover、状态提交前应用中断、`DEGRADED` 无活动配置恢复、调优后尚未安装 3X-UI、停止的 `x-ui.service`、NOFILE 低于 65536、缺失的 Xray 子进程、应用中断、`swapoff` 失败、`/etc/fstab` 过滤或原子替换失败，以及已安装非默认带宽下的重复 `apply`。

## README 迁入的历史验证摘要

以下内容从 `c8fcfbcc4d2cd4bb40eeb7bbc594e1d07d9c3a61` 的 README 迁入，保留原信息日期、样本数、版本与证据限制；不计为当前版本新增运行结果。

### 真实环境验证基线（截至 2026-08-07）

截至 2026-08-07，项目已取得下列脱敏目标机证据。表中编号代表验证记录，不代表 VPS 数量；同一资产在不同时期的同类配置可以形成多条记录。公开文档不记录服务商、区域、IP、域名、主机名、面板端口、订阅地址、账号、凭据、证书标识或可反查报告 ID。

| 记录 | 操作系统与内核系列 | VPS 配置 | 存储/网络 | 已覆盖路径 | 证据边界 |
|---|---|---|---|---|---|
| C1 | Debian 13；Linux 6.12 系列 | 1 vCPU / 约 1 GiB；`debian13-1c1g` | ext4；套餐上限 1000 Mbps | 固定 rc.9 资产校验、安全引导、`preflight`、`apply`、立即/重启后 `verify`、安装 3X-UI 后严格验证；BBR、fq、swap 和 NOFILE 重启后保持 | 只证明对应 rc.9 产物和该配置类别的主路径，不继承为后续 rc 结论 |
| C2 | Debian 12；Linux 6.1 系列 | 1 vCPU / 约 1 GiB；`debian12-1c1g` | XFS；套餐上限 200 Mbps | 退出 rc.8 后完成 rc.10 候选 `apply`、重启后普通/严格 `verify` 和重复 `apply`；重复执行未重写配置 | 不替代最终 Release 资产复核，不证明代理吞吐或线路质量 |
| C3 | Debian 12；Linux 6.1 系列 | 1 vCPU / 约 2 GiB；`debian12-1c2g` | XFS；套餐上限 200 Mbps | 退出 rc.8 后完成 rc.10 候选 `apply`、重启后普通/严格 `verify` 和重复 `apply`；3X-UI 主进程及 Xray 直接子进程 NOFILE 为 65536/65536 | 不覆盖 2C2G、512 MiB、其他文件系统或最终 Release 资产 |
| C4 | Debian 13；Linux 6.12 系列 | 1 vCPU / 约 1 GiB；`debian13-1c1g` | ext4；套餐上限 1000 Mbps | 使用隔离目录完成 rc.9→rc.10 候选迁移、重启后严格 `verify` 和重复 `apply` | 这是迁移记录，配置类别可能与 C1 重合；不代表新增一台独立 VPS |
| C5 | Debian 13；Linux 6.12 系列 | 1 vCPU / 约 1 GiB；`debian13-1c1g` | ext4；套餐上限 200 Mbps | 固定 rc.11 候选完成 `preflight`、`apply`、立即/重启后 `verify`、幂等门禁，以及固定 commit/rootfs 的三轮 S1 与三轮 S2 TcpQuality 采集 | 原始证据私有保存；只证明 rc.11 生命周期和两时段线路观察，不证明 rc.12–rc.16 最终哈希或调优导致性能改善 |
| C6 | Debian 13；Linux 6.12 系列 | 1 vCPU / 967 MiB；`debian13-1c1g` | 10 GB / ext4；套餐上限 100 Mbps | rc.12 本地候选完成校验和复核、错误参数退出、显式 swap purge、100 Mbps `preflight`/`apply`、重启后 `verify` 和重复 `apply`；BBR、fq、1024 MiB swap 持久，缺失的 `/etc/sysctl.conf` 未被创建 | 暴露并修正了改参提示和缺失文件元数据；原运行绑定修正前 profile 哈希，最终候选仍须重跑哈希绑定门禁；未安装 3X-UI，不覆盖严格代理验证或性能收益 |

每条记录均绑定测试时的脚本哈希。脚本内容或 SHA-256 改变后，必须按 [验证矩阵](validation.md) 重新取证；版本名称或配置值相同不足以继承原结论。rc.16 最终哈希尚未完成目标 VPS 生命周期、端口重配置与恢复、真实 benchmark 超时/信号回收、策略路由诊断、严格代理验证和 TcpQuality 证据工具验证。

### 1C2G / 200 Mbps 性能观察案例

同一 Debian 12、1C2G 配置类别曾在旧 v6 配置和 rc.10 配置下分别运行 TcpQuality。本文只保留聚合结果；报告 URL、报告 ID、精确测试时间、服务商和区域不公开。原始报告保存在维护者的私有证据集中。

三次报告均显示 `bbr`、`fq`、TCP 发送缓冲 `4K/64K/16M` 和接收缓冲 `4K/128K/16M`。下表每格依次为“零异常 / 1–20% / >20%”：普通回程按丢包率分档，大包回程按重传率分档，每类包含 93 个判定项。

| 脱敏样本 | IPv4 回程 | IPv4 大包回程 | IPv6 回程 |
|---|---:|---:|---:|
| v6 基线样本 | 93 / 0 / 0 | 91 / 0 / 2 | 69 / 24 / 0 |
| rc.10 样本 A | 92 / 1 / 0 | 84 / 7 / 2 | 67 / 23 / 3 |
| rc.10 样本 B | 93 / 0 / 0 | 92 / 0 / 1 | 79 / 14 / 0 |

同一 rc.10 配置的两个时段样本中，IPv4 大包零重传节点由 84 变为 92，IPv6 零丢包节点由 67 变为 79。组内波动已经大于或接近 v6 与 rc.10 样本 A 的组间差异。这三次观测不能证明 v6 或 rc.10 的内核参数更快，也不能将个别区域或运营商的集中异常唯一归因于某条路由。测试时段、运营商链路、测速节点、共享宿主机负载和工具版本均可能影响结果。

样本量同样不足：v6 只有一次，rc.10 只有两次，无法估计稳定分布。TcpQuality 未指定 `-s` 时随机使用内置包长，默认 `-c` 每个节点只发送 30 个包。该工具直接测试 VPS 网络栈，不经过 3X-UI、VLESS、REALITY 或客户端链路。现有证据以远程图片为主，缺少可供公开复算的机器可读原始表格。

这些报告不足以支持回退 rc.10、修改 rc.11–rc.16 的 17 个受管 sysctl，或增加激进参数。仅当准备形成可发布的性能或永久整形主张时，研究协议才固定 TcpQuality commit、脚本 SHA-256、节点文件和 `-c/-s/-p` 参数，并在受控环境比较中位数、P95 与异常节点复现率。普通业务 VPS 验收只覆盖真实 VLESS + REALITY + TCP 冒烟，不重复全量公网性能矩阵。完整分层见 [验证矩阵](validation.md)。
