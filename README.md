# VPS Tuning

Development status: the [unpublished 0.2.0 candidate](docs/releases/v0.2.0.md) is undergoing validation and freezing of its own final assets. Public installation below remains pinned to rc.5; production migration, business acceptance and public release remain pending.

English | [简体中文](README.zh-CN.md)

[![Pre-release](https://img.shields.io/github/v/release/alieismy/vps-tuning?include_prereleases&filter=v*)](https://github.com/alieismy/vps-tuning/releases)
[![shell-static-checks](https://github.com/alieismy/vps-tuning/actions/workflows/shellcheck.yml/badge.svg?branch=master)](https://github.com/alieismy/vps-tuning/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Host network diagnostics, budgeted automatic measurement with public iperf3 endpoints, and verifiable, reversible BBR + fq configuration for Linux VPS hosts. Measurement needs neither prior tuning nor a self-hosted endpoint. Temporary HTB rate sweeps explore the relationship between sending rate and retransmissions.

> This README is translated from the [Chinese README](README.zh-CN.md). The guides under `docs/` are in Chinese. Where the two READMEs differ, the Chinese README prevails.

**Current pre-release: [`v0.2.0-rc.5`](https://github.com/alieismy/vps-tuning/releases/tag/v0.2.0-rc.5) (2026-11-23 UTC); there is no stable release yet.** A host with existing DVT managed state must complete a cross-version migration before running managed actions under the new version; see [Upgrades and rollback](#upgrades-and-rollback).

## Capabilities and effects

| Goal | Entry point | Effects and conditions |
|---|---|---|
| Inspect host capabilities and network state | `dvt diagnose` | No prior apply, active test traffic or system configuration changes; outputs a capability snapshot |
| Automatically select an endpoint and measure outgoing TCP | `dvt measure` | No prior apply; explicit cap and shared budget; keeps sysctl/qdisc and saves local evidence |
| Explore temporary shaping rates | `dvt htb-sweep` | Requires a fully restorable single root fq; temporarily limits all interface egress, including SSH; verifies restoration |
| Manage host configuration | `dvt preflight` → `dvt apply` | Persistently manages BBR + fq, TCP buffers, queue settings, optional swap, journald and NOFILE; includes verification and rollback |
| Inspect captured results | `dvt report` | Verifies independent measurement report hashes; never applies a candidate rate |
| Explain retransmissions and candidate evidence offline | [`explain_measurement.py`](docs/measurement-explanation.md) | Runs from the complete source directory without VPS installation; preserves the original classification and makes no shaping decision |

The project does not install or rewrite proxy services, configure firewalls, routing, DNS, NAT or TProxy. `verify` and legacy incremental diagnostics (`diagnose --managed`) may read an accessible generated Xray configuration to report selected TFO/keepalive fields; they do not rewrite it or output its credentials. Persistent HTB is not enabled.

## Support and prerequisites

| Capability | Requirements |
|---|---|
| Persistent configuration | Debian 12/13 or Ubuntu 24.04 LTS, `x86_64`/`aarch64`, native systemd; at least 1 logical CPU and 384 MiB RAM; available BBR/fq, a conventional default route and recoverable qdisc |
| Independent diagnostics | Linux, Python 3.9+ and available observation commands; no root required; unreadable items are unavailable |
| Independent measurement | Python 3.9+, Bash, iperf3, iproute2, jq, awk, GNU coreutils and util-linux; execution needs root and a shared budget ledger; no distro or CPU/RAM tier allowlist |
| Temporary HTB | Measurement dependencies, HTB/fq, an explicit interface and full restoration support; mq, clsact, ingress, extra classes/filters or unknown fq parameters are rejected |

Dependencies are not installed automatically. See [preparation instructions (Chinese)](docs/usage.md#执行前准备). Rate-limited tests should use iperf3 3.18 or a version containing the equivalent fix.

Original Debian resource tiers keep their policies; other supported combinations use adaptive profiles. Persistent `--port` accepts **1–10000 Mbps** and means the provider's plan limit, not the virtual NIC link speed or a shaper. Measurement `--rate-cap` is a separate sending target and budget input. Accepted values do not prove tested throughput; see the [platform and resource contract (Chinese)](docs/platform-support.md).

## Quick start

### Choose a path before installation

- **New host:** verify and install the pinned release below, then choose diagnostics/measurement or persistent configuration.
- **Existing managed state:** first read the [migration guide (Chinese)](docs/migration.md). Installing an entrypoint does not migrate state. Never apply a new version over old state. If saved original `tcp_rmem/tcp_wmem` vectors have fewer than three fields, stop at read-only inspection; keep state and original assets, and do not rollback/reboot.
- **Before changing configuration:** save the baseline and confirm console/rescue access and backups. If the provider already supplies BBR/fq, inspect preflight before deciding whether the project should take ownership; existing BBR/fq does not itself require another tuning layer.

### Installation

Run in a root shell (`id -u` must return `0`). This downloads the complete fixed `v0.2.0-rc.5` installer, verifies its SHA-256 and then executes it. `--no-launch` installs only, without tuning or measurement traffic.

```bash
(
  set -Eeuo pipefail
  dvt_i="$(mktemp)"
  trap 'rm -f -- "$dvt_i"' EXIT
  curl --fail --show-error --silent --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 120 \
    -o "$dvt_i" \
    https://github.com/alieismy/vps-tuning/releases/download/v0.2.0-rc.5/install.sh
  printf '%s  %s\n' \
    'de7967a738fb28d0da24ff70b7928f32aee6d0ad7965d938d4152e2903f0ada0' \
    "$dvt_i" | sha256sum -c -
  bash "$dvt_i" --no-launch
)
```

Continue only after successful exit. The installer verifies the pinned manifest and all runtime assets, installs `/usr/local/bin/dvt`, and refuses inconsistent existing content. Downloads never fall back to mutable branches, `latest` or third-party mirrors. Do not replace this with an unverified `curl | bash` command.

```bash
dvt --version
```

### Path A: diagnostics or independent measurement

No prior apply is needed. After installation, inspect capabilities and preview the traffic-free plan:

```bash
dvt diagnose
dvt measure --rate-cap 20 --plan-only
```

After reviewing the testing window, budget and public service terms, the following **example generates outgoing TCP traffic**. Run as root; the output directory must not exist. Never delete a ledger or change its window ID to bypass recorded consumption:

```bash
install -d -m 0700 /root/dvt-traffic
dvt measure --rate-cap 20 --family 4 --budget-mib 600 \
  --ledger /root/dvt-traffic/window.json --window-id path-check-01 \
  --output-dir /root/dvt-measure-01
```

The tool displays its plan and asks for confirmation, then performs bounded public endpoint selection. Public services see the VPS source address and may be busy or unreachable. The example 600 MiB budget covers application payload, excluding protocol, retransmission and provider-billing overhead. See [automatic measurement (Chinese)](docs/automatic-measurement.md) for dependencies, results and failed-reservation accounting. Inspect a completed report with:

```bash
dvt report --input-dir /root/dvt-measure-01
```

`INSUFFICIENT_EVIDENCE` is an allowed result; exit code 0 only means report collection completed. Tests do not traverse a VLESS/REALITY client and do not establish proxy performance benefits. For temporary shaping, read the [htb-sweep guide (Chinese)](docs/temporary-htb.md), including its whole-interface impact and restoration conditions.

For scan coverage gaps, absolute retransmission counts, byte exposure and candidate evidence limits, use [offline explanation tool 0.1.1](https://github.com/alieismy/vps-tuning/releases/tag/measurement-explanation-v0.1.1). This is a separate source prerelease; see the [tool release notes (Chinese)](docs/releases/measurement-explanation-v0.1.1.md) for download verification and Windows/Linux commands. It requires neither a VPS upgrade nor the installer and does not change the installed main-program version.

### Path B: persistent configuration

For a new host without old managed state, replace `200` with the provider plan limit and run read-only preflight:

```bash
dvt preflight --port 200
```

After preflight passes and you have reviewed the write scope:

```bash
dvt apply --port 200
```

After successful application, reboot as instructed:

```bash
reboot
```

Log in again and verify. These commands neither need the bandwidth again nor reapply settings:

```bash
dvt verify
dvt status
```

Stop on any failed step and retain complete output. After installing and starting 3X-UI, also run strict verification for service activity and NOFILE limits in systemd, the main process and direct Xray children. Repeat after reboot:

```bash
env REQUIRE_PROXY_SERVICE=1 PROXY_SERVICE_UNITS='x-ui.service' dvt verify
```

See the [operations guide (Chinese)](docs/usage.md) for other services, preflight refusals, swap and qdisc restoration.

## Default Low-Traffic Acceptance Path

Persistent installation and migration use fixed-asset verification, preflight, apply, post-reboot verify, applicable strict proxy-service verification and a small real-client business smoke test. Routine checks use status/verify; start troubleshooting with traffic-free diagnose. Routine checks do not require reapplying settings.

`measure`, `htb-sweep`, legacy probe, benchmark, TcpQuality and HTB research are not mandatory per-host acceptance steps. Active measurement requires a concrete question and budget; benchmark, TcpQuality and legacy HTB reference/sweep/A/B/A research additionally require a separate high-quota host. See the [validation boundaries (Chinese)](docs/validation.md#默认验收路径与研究边界).

## Common operations

| Operation | Command or documentation |
|---|---|
| Interactive menu | `dvt`; guided preflight asks before apply; mismatched state defaults to local diagnostics, while update requires explicit selection |
| Entrypoint version / managed state | `dvt --version` shows the entrypoint version; `dvt status` requires a matching managed-state version. If they differ, use the read-only state inspection in the [migration guide (Chinese)](docs/migration.md) |
| Verify managed configuration | `dvt verify` |
| Legacy profile incremental/proxy diagnostics | `dvt diagnose --managed`; `DIAG_*` variables affect this path only |
| Change only the plan bandwidth, with the same version/profile | `dvt reconfigure --port 500`; requires valid `VERIFIED` state |
| Read-only update check | `dvt update`; no automatic migration or reboot; cross-line targets require explicit `--target` |
| Recover an interrupted bandwidth reconfiguration | `dvt recover`; follows transaction state, not a generic repair for corrupt state |
| Parameters, manual downloads, offline bundles and standalone profiles | [Operations guide (Chinese)](docs/usage.md) |
| Explicit-endpoint probe, benchmark, TcpQuality and legacy HTB | [Advanced measurement (Chinese)](docs/advanced-measurement.md) |

## Upgrades and rollback

**Updating executable files, migrating managed state and business acceptance are separate steps.** Before a managed host can run managed actions under a new version, it must pass the cross-version migration and original-state checks: the **fixed old Release** verifies and restores the source from its own state, followed by a checkpoint, two manual reboot gates and target apply/verify. Ubuntu and port speeds above 1000 Mbps remain outside the migrator scope; new-install support does not expand migration support. See the [current migration procedure and historical appendix (Chinese)](docs/migration.md).

Run `dvt rollback` only when restoration conditions are complete and the entrypoint matches the state version. Normal rollback keeps project-created swap; confirm memory headroom before an explicit purge as described in the [rollback guide (Chinese)](docs/usage.md#回滚). On failure, retain state, checkpoints, backups and the ledger. Never delete state, guess original values or overwrite old state with new apply.

Use `reconfigure --port` for a bandwidth-only change. An invalid-parameter call rejected before writes needs no rollback; other changes follow their applicable recovery procedure.

## Companion repositories and order

The three repositories are used in the order of the table below: harden first, then tune, then set up the proxy (vps-hardening requirements D27; rationale in its [requirements §7.3](https://github.com/alieismy/vps-hardening/blob/master/docs/requirements.md#73-与-vps-tuning-的约定)).

| Order | Repository | Purpose |
|---|---|---|
| 1 | [vps-hardening](https://github.com/alieismy/vps-hardening) | Baseline security hardening |
| 2 | vps-tuning (this repository) | Network tuning, diagnostics and measurement |
| 3 | [vps-proxy-setup](https://github.com/alieismy/vps-proxy-setup) | Proxy service setup (3X-UI as the example) |

Full flow (vps-hardening requirements D27, D41, D42):

1. **Preparation**: update the system, install basic tools and reboot; done by the administrator;
2. **vps-hardening**: harden and confirm;
3. **vps-tuning**: tune as in [Path B](#path-b-persistent-configuration) (preflight → apply → reboot → verify);
4. **vps-proxy-setup**: install and configure 3X-UI, then open its ports with `vps-hardening ports` and confirm;
5. **Final checks**: this repository's strict proxy-service verification (requires the proxy service to be running); after a reboot, check again with `vps-hardening verify`, the strict verification and a proxy client connection.

Apply and reboot for tuning only after the hardening is confirmed: a reboot before confirmation automatically undoes the hardening.

## Validation status and limitations

- `v0.2.0-rc.5` is a Pre-release; its pinned assets have been verified through public downloads. Persistent profiles support Debian 12/13 and Ubuntu 24.04 LTS on x86_64/ARM64; independent diagnostics and measurement check actual Linux capabilities.
- On 2026-11-24, the user confirmed that the current VPS fleet excluding Oracle and AWS had been reinstalled with rc.4, including apply and post-reboot verify. The deployment manuals identify nine hosts; see the [current deployment baseline (Chinese)](docs/validation.md#current-fleet-baseline). This is user-confirmed runtime status without newly collected per-host deployment archives, and does not establish rc.5 or stable-candidate acceptance. The [five-host rc.2 acceptance record (Chinese)](docs/validation.md#rc2-fleet-acceptance) from 2026-10-11 remains historical evidence and does not establish recovery baselines for the reinstalled hosts, performance gains or long-term stability. The first stable release now follows [capability-based acceptance gates (Chinese)](docs/validation.md#stable-release-gates); the old T1–T10 physical-host release requirements have been retired.
- Seven isolated guest lifecycle jobs cover Debian 12/13 and Ubuntu 24.04 x86_64/ARM64 adaptive profiles, plus Debian 13 x86_64 legacy. They include real guest reboots, idempotency, reconfiguration and restoration. ARM64 uses QEMU/TCG on ARM runners; it is not vendor-specific hardware acceptance.
- Public IPv4 measurement and temporary HTB normal/signal-interrupted restoration have bounded VPS evidence. One complete low-rate sweep had 15 samples, 11 eligible, and still returned `INSUFFICIENT_EVIDENCE`. Reliable policer (traffic policing) detection and proxy benefits remain unproven.
- The main business validation scenario is native systemd with 3X-UI/Xray/VLESS + REALITY + TCP. Recorded versions are 3X-UI v3.4.2 and Xray-core v26.6.27; other versions need separate verification. Persistent Docker, policy-routing, TProxy, gateway and complex-qdisc configurations are outside current support.
- 1–10000 Mbps is an input range. Broader public-path platform coverage, IPv6, high rates, specific large-resource hardware and business performance still have unvalidated areas.
- The repository was renamed from `debian-vps-tuning` on 2026-10-10, and old links redirect here automatically. The `dvt` command, release asset file names, installation paths and managed-state paths are unchanged. These verified runtime assets retain the old repository constant; the installer and controller reach the renamed repository through GitHub redirects. Do not recreate the old repository name in the same account, as that would disable those redirects.

Changes in each version are listed under [Releases](https://github.com/alieismy/vps-tuning/releases) and in the [CHANGELOG](CHANGELOG.md). Pinned commits, historical failures and detailed limits are recorded in the [platform matrix](docs/platform-support.md), [validation record](docs/validation.md) and [release notes](docs/releases/v0.2.0-rc.5.md), currently in Chinese.

## Documentation

The guides are in Chinese.

| Topic | Guide |
|---|---|
| Installation, daily operation, diagnostics, parameters and rollback | [Operations](docs/usage.md) |
| Upgrades, old state and historical recovery | [Migration](docs/migration.md) |
| Automatic selection, budgets and result interpretation | [Independent measurement](docs/automatic-measurement.md) |
| Offline counts, byte exposure and candidate limits | [Explanation tool](docs/measurement-explanation.md) · [Separate tool release](docs/releases/measurement-explanation-v0.1.1.md) |
| Temporary HTB and full restoration | [Temporary experiments](docs/temporary-htb.md) |
| Platforms, resources and adaptive buffers | [Support matrix](docs/platform-support.md) |
| Advanced explicit measurement and research | [Advanced measurement](docs/advanced-measurement.md) |
| Design and validation evidence | [Design scope](docs/design-scope.md) · [Validation](docs/validation.md) |
| Offline calibration for fixed profiles | [Measured calibration](docs/measured-calibration.md); no traffic/apply, adaptive inputs not yet accepted |
| Version changes | [Release history](docs/releases/) |

## Help, contributing and security

Use [GitHub Issues](https://github.com/alieismy/vps-tuning/issues) for usage questions, reproducible bugs and suggestions. Include the script version, OS/architecture, steps, exit status and sanitized output. Do not publish real addresses, credentials, subscription links, full proxy configurations or traceable report identifiers; see the [sanitization guide (Chinese)](docs/usage.md#日志脱敏与安全报告). Report security issues through the private channel in [SECURITY.md](SECURITY.md) (Chinese).

Reproducible fixes and documentation improvements are welcome. For profile changes, edit `tools/profile-template.sh.in` and the corresponding declarations, then regenerate; do not edit generated files alone. On Linux, run [`bash tests/static-check.sh`](tests/static-check.sh); experiment changes also need the applicable [experiment checks](experiments/htb-aggregate/tests/static-check.sh). Root lifecycle and platform requirements are in the [validation guide (Chinese)](docs/validation.md).

## License

[MIT License](LICENSE)

<details>
<summary>Links from the former Chinese README</summary>

This file used to be the Chinese README. The anchors below keep its old section links working; each entry leads to the matching section of the [Chinese README](README.zh-CN.md) or the guide that now holds the content.

- <a id="功能与边界"></a>[功能与边界](README.zh-CN.md#功能与边界)
- <a id="支持范围与前置条件"></a>[支持范围与前置条件](README.zh-CN.md#支持范围与前置条件)
- <a id="快速开始"></a>[快速开始](README.zh-CN.md#快速开始)
- <a id="安装前先选择路径"></a>[安装前先选择路径](README.zh-CN.md#安装前先选择路径)
- <a id="联网安装与验证"></a>[联网安装与验证](README.zh-CN.md#联网安装与验证)
- <a id="安装"></a>[安装](README.zh-CN.md#安装)
- <a id="路径-a只诊断或独立测量"></a>[路径 A：只诊断或独立测量](README.zh-CN.md#路径-a只诊断或独立测量)
- <a id="路径-b应用持久配置"></a>[路径 B：应用持久配置](README.zh-CN.md#路径-b应用持久配置)
- <a id="默认低流量验收路径"></a>[默认低流量验收路径](README.zh-CN.md#默认低流量验收路径)
- <a id="常用操作"></a>[常用操作](README.zh-CN.md#常用操作)
- <a id="升级与回滚"></a>[升级与回滚](README.zh-CN.md#升级与回滚)
- <a id="验证状态与已知限制"></a>[验证状态与已知限制](README.zh-CN.md#验证状态与已知限制)
- <a id="文档导航"></a>[文档导航](README.zh-CN.md#文档导航)
- <a id="帮助贡献与安全报告"></a>[帮助、贡献与安全报告](README.zh-CN.md#帮助贡献与安全报告)
- <a id="许可证"></a>[许可证](README.zh-CN.md#许可证)
- <a id="1-联网安装"></a>[1. 联网安装](README.zh-CN.md#安装)
- <a id="2-重启后联网验证"></a>[2. 重启后联网验证](docs/usage.md#入口不可用时的联网验证)
- <a id="3-安装-3x-ui-后严格联网验证"></a>[3. 安装 3X-UI 后严格联网验证](docs/usage.md#入口不可用时的严格代理验证)
- <a id="4-从早期-rc-版本执行只读升级检查历史-rc17-示例"></a>[4. 从早期 rc 版本执行只读升级检查（历史 rc.17 示例）](docs/migration.md#早期-rc-的历史-rc17-升级检查)
- <a id="5-联网执行注意事项"></a>[5. 联网执行注意事项](docs/usage.md#执行前准备)
- <a id="厂商已预装-bbrfq-时的处理"></a>[厂商已预装 BBR/fq 时的处理](docs/usage.md#厂商已预装-bbrfq-时的处理)
- <a id="真实环境验证基线"></a>[真实环境验证基线](docs/validation.md#真实环境验证基线截至-2026-08-07)
- <a id="1c2g--200-mbps-性能观察案例"></a>[1C2G / 200 Mbps 性能观察案例](docs/validation.md#1c2g--200-mbps-性能观察案例)
- <a id="本地使用与命令行模式"></a>[本地使用与命令行模式](docs/usage.md#本地使用与命令行模式)
- <a id="适用场景"></a>[适用场景](README.zh-CN.md#支持范围与前置条件)
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
- <a id="验证与已知限制"></a>[验证与已知限制](README.zh-CN.md#验证状态与已知限制)
- <a id="安全问题"></a>[安全问题](docs/usage.md#日志脱敏与安全报告)

</details>
