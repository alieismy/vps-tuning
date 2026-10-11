# Security Policy

## Supported versions

在首个正式版本发布前，主程序仅最新的预发布版本接受安全修复，当前为 [`v0.2.0-rc.1`](docs/releases/v0.2.0-rc.1.md)。旧预发布版本不承诺回补安全修复；修复通过新版本交付，已公开的 tag、Release 和资产保持不变。正式发布后，支持范围将在此更新。

## Reporting a vulnerability

请使用 GitHub 仓库的 [Security → Advisories → Report a vulnerability](https://github.com/alieismy/vps-tuning/security/advisories/new) 私密报告入口；需要登录 GitHub。不要先创建公开 Issue。

报告建议包含：

- 受影响的脚本名和版本；
- 操作系统及版本（如 Debian 12/13、Ubuntu 24.04 LTS）、内核版本和 CPU 架构（如 x86_64/amd64、aarch64/ARM64）；持久配置支持范围见[平台支持](docs/platform-support.md)；
- 可复现步骤、实际退出码和脱敏日志；
- 是否涉及文件删除、状态所有权、qdisc、swap、sysctl 或 systemd；
- 预期行为与实际行为。

不得提交：

- SSH 私钥或密码；
- 面板用户名、密码或 API Token；
- VLESS UUID；
- REALITY privateKey；
- TLS/ACME 私钥；
- 未脱敏的 3X-UI 数据库或 Xray 完整配置。

## Operational safety

这些脚本以 root 权限运行。请从 GitHub Release 下载、核对 `SHA256SUMS`、阅读脚本并先执行 `preflight`。不要把未知 fork 或未经核验的网络内容直接通过 `curl | bash` 交给 root shell。
