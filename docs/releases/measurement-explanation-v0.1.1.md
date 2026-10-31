# 离线测量解释工具 0.1.1 发布说明

发行类型：独立源码 **Pre-release**，2026-10-31 发布，不设为 Latest。tag 为 `measurement-explanation-v0.1.1`，固定源码为 `30d5ca4063274ae06a1c8497db745f2c3257b419`，由 [PR #44](https://github.com/alieismy/vps-tuning/pull/44) 合入主线。本工具不替代主程序 `v0.2.0-rc.4`，不进入 `dvt update`，不是 VPS 升级包。

## 内容与兼容性

中文输出按最终归档 schedule 的 sweep 项，列出计划档位及期望样本数、样本齐全且原汇总有效的档位，以及缺失、不足或无效档位。已追加细扫纳入，control/reference 与发送 cap 不混算；旧计划不支持或资料矛盾时保守显示不可评估。

原状态、候选、停止原因和恢复/完整性拒绝保持。`dvt.measurement-explanation/1` 字段集合及语义不变，`tool_version` 从 0.1.0 更新为 0.1.1。没有新增采集、系统写入、运行依赖或统计准确率承诺。完整契约见[工具说明](../measurement-explanation.md)。

## 下载与使用

[GitHub Release](https://github.com/alieismy/vps-tuning/releases/tag/measurement-explanation-v0.1.1) 提供三项固定资产：

- [dvt-measurement-explanation-0.1.1-source.zip](https://github.com/alieismy/vps-tuning/releases/download/measurement-explanation-v0.1.1/dvt-measurement-explanation-0.1.1-source.zip)：固定 Git 提交的完整源码，保留依赖、测试、历史文档和 MIT 许可证。
- [RELEASE-NOTES.zh-CN.md](https://github.com/alieismy/vps-tuning/releases/download/measurement-explanation-v0.1.1/RELEASE-NOTES.zh-CN.md)：版本、摘要和 Windows/Linux 校验与运行命令。
- [SHA256SUMS](https://github.com/alieismy/vps-tuning/releases/download/measurement-explanation-v0.1.1/SHA256SUMS)：前两项资产的 SHA-256 清单。

保留完整解包目录，使用 Python 3.9+ 执行 `python tools/explain_measurement.py --input-dir <已完成报告目录>`；追加 `--json` 输出机器结果。无需 pip、Git、root、SSH 凭据或运行安装器。与采集并发时先使用冻结副本。

将三项资产下载到同一目录，先校验，再解包。Windows PowerShell：

```powershell
Get-Content -LiteralPath .\SHA256SUMS | ForEach-Object {
    $parts = $_ -split '  ', 2
    if ($parts.Count -ne 2) { throw 'Invalid checksum entry' }
    $actual = (Get-FileHash -LiteralPath $parts[1] -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $parts[0]) { throw ('Checksum mismatch: ' + $parts[1]) }
}
Expand-Archive -LiteralPath .\dvt-measurement-explanation-0.1.1-source.zip -DestinationPath .\explanation-0.1.1
Set-Location .\explanation-0.1.1\dvt-measurement-explanation-0.1.1
python tools/explain_measurement.py --input-dir 'D:\reports\completed-measurement'
```

Linux：

```bash
sha256sum -c SHA256SUMS
python3 -m zipfile -e dvt-measurement-explanation-0.1.1-source.zip explanation-0.1.1
cd explanation-0.1.1/dvt-measurement-explanation-0.1.1
python3 tools/explain_measurement.py --input-dir /path/to/completed-measurement
```

两段命令的报告路径均为示例，须替换为自己的已完成报告目录。退出 0 仅表示解释成功；是否形成有效测量仍以原报告状态为准。三项资产已完成公开下载回验，中英文 README 已切换到 0.1.1。

源码 ZIP 为 1707132 bytes、132 个文件，SHA-256：

```text
eafed801458ba5965760ca508107e80c70f57e2689c5ffd76b41f8363c2a54c7
```

## 验证边界

[合并提交 CI](https://github.com/alieismy/vps-tuning/actions/runs/41197058699)与[tag CI](https://github.com/alieismy/vps-tuning/actions/runs/41197087932)均通过既有完整 Linux workflow。主 unittest 154 项为 `OK (skipped=1)`，其中 root 限定恢复用例在普通用户阶段跳过，后继 sudo 入口的 20 项恢复测试全部通过；静态、PTY、安装/迁移、隔离 tc/iperf3 与 ShellCheck 均通过。

Windows/Python 解包目录通过 29 项工具测试、生成及 24 项运行资产摘要检查；132 个文件逐 Git blob 一致，两次 ZIP 完全相同。8 个合成冻结归档的 JSON 除工具版本外保持，32 个源文件不变；真实 PowerShell 校验/解包命令通过。三个资产从无认证公开 URL 下载，与批准制品和 GitHub digest 逐项一致，下载 ZIP 的 29 项测试通过。历史 17 个 Release 的记录及资产标识/摘要保持。详见[验证记录](../validation.md#measurement-explanation-011-release)。

此次只有合成冻结归档，没有新增历史真实归档回读。测试不证明网络容量、性能改善、可靠 policer 识别或旧部署迁移；其他工作区运行代码修复未纳入此版本，原有发布资产保持不可变。
