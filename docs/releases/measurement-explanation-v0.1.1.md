# 离线测量解释工具 0.1.1 发布说明

发行类型：独立源码 **Pre-release**，不设为 Latest。tag 为 `measurement-explanation-v0.1.1`；用户已授权发布，当前记录为发布准备状态，固定提交、CI 与公开回验完成后补记。本工具不替代主程序 `v0.2.0-rc.4`，不进入 `dvt update`，不是 VPS 升级包。

## 内容与兼容性

中文输出按最终归档 schedule 的 sweep 项，列出计划档位及期望样本数、样本齐全且原汇总有效的档位，以及缺失、不足或无效档位。已追加细扫纳入，control/reference 与发送 cap 不混算；旧计划不支持或资料矛盾时保守显示不可评估。

原状态、候选、停止原因和恢复/完整性拒绝保持。`dvt.measurement-explanation/1` 字段集合及语义不变，`tool_version` 从 0.1.0 更新为 0.1.1。没有新增采集、系统写入、运行依赖或统计准确率承诺。完整契约见[工具说明](../measurement-explanation.md)。

## 下载与使用

[GitHub Release](https://github.com/alieismy/vps-tuning/releases/tag/measurement-explanation-v0.1.1) 将提供三项固定资产：

- `dvt-measurement-explanation-0.1.1-source.zip`：固定 Git 提交的完整源码，保留依赖、测试、历史文档和 MIT 许可证。
- `RELEASE-NOTES.zh-CN.md`：版本、摘要和 Windows/Linux 校验与运行命令。
- `SHA256SUMS`：前两项资产的 SHA-256 清单。

保留完整解包目录，使用 Python 3.9+ 执行 `python tools/explain_measurement.py --input-dir <已完成报告目录>`；追加 `--json` 输出机器结果。无需 pip、Git、root、SSH 凭据或运行安装器。与采集并发时先使用冻结副本。

发布后将三项资产下载到同一目录，先校验，再解包。Windows PowerShell：

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

两段命令的报告路径均为示例，须替换为自己的已完成报告目录。退出 0 仅表示解释成功；是否形成有效测量仍以原报告状态为准。三项资产公开并回验前，中英文 README 继续指向已发布的 0.1.0。

## 验证边界

发布门禁包括 29 项解释器回归及既有完整 Linux CI，分别验证工具契约和源码树回归；打包时核对 ZIP 文件与固定提交逐字节一致，并核验重复制包、解包运行和源证据不变。最终结果见[验证记录](../validation.md#measurement-explanation-011-release)。

此次只有合成冻结归档，没有新增历史真实归档回读。测试不证明网络容量、性能改善、可靠 policer 识别或旧部署迁移；其他工作区运行代码修复未纳入此版本，原有发布资产保持不可变。
