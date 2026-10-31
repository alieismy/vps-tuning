# VPS Tuning

[简体中文](README.md) · English · [v0.2.0-rc.4 prerelease](https://github.com/alieismy/vps-tuning/releases/tag/v0.2.0-rc.4) · [Published rc.3](https://github.com/alieismy/vps-tuning/releases/tag/v0.2.0-rc.3)

**v0.2.0-rc.4 prerelease.** The `dvt` menu now defaults to local capability diagnostics when the entrypoint and managed-state versions differ; managed actions are unavailable and update checks require an explicit selection. Its migrator also accepts `0.2.0-rc.3` sources. Tuning behaviour is unchanged. See the [release notes (Chinese)](docs/releases/v0.2.0-rc.4.md) for scope and evidence. Managed hosts must complete a cross-version migration before running managed actions under the new version; successful preflight does not establish complete original TCP snapshots, and migration must still pass `migrate prepare`. Stable rc.2 hosts should not migrate solely for the interactive interface.

Host network diagnostics, budgeted automatic measurement with public iperf3 endpoints, and verifiable, reversible BBR + fq configuration for Linux VPS hosts. Measurement needs neither prior tuning nor a self-hosted endpoint. Temporary HTB rate sweeps explore the relationship between sending rate and retransmissions.

This is a **Pre-release**. The pinned rc.4 assets have been verified through public downloads. Persistent profiles support Debian 12/13 and Ubuntu 24.04 LTS on x86_64/ARM64; independent diagnostics and measurement check actual Linux capabilities. Functional and recovery evidence does not establish reliable policer identification or improved proxy performance.

The repository was renamed from `debian-vps-tuning` on 2026-10-10. Old links redirect here automatically. The `dvt` command, release asset file names, installation paths and managed-state paths are unchanged.

These verified runtime assets retain the old repository constant. The installer and controller reach the renamed repository through GitHub redirects; do not recreate the old repository name in the same account, as that would disable those redirects.

[Capabilities](#capabilities-and-effects) · [Requirements](#support-and-prerequisites) · [Quick start](#quick-start) · [Operations](#common-operations) · [Migration](#upgrades-and-rollback) · [Documentation](#documentation) · [Help](#help-contributing-and-security)

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

<a id="online-installation-and-verification"></a>

### Installation

Run in a root shell (`id -u` must return `0`). This downloads the complete fixed `v0.2.0-rc.4` installer, verifies its SHA-256 and then executes it. `--no-launch` installs only, without tuning or measurement traffic.

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

For absolute retransmission counts, byte exposure and candidate evidence limits, use [offline explanation tool 0.1.1](https://github.com/alieismy/vps-tuning/releases/tag/measurement-explanation-v0.1.1). This is a separate source prerelease; see the [tool release notes (Chinese)](docs/releases/measurement-explanation-v0.1.1.md) for download verification and Windows/Linux commands. It requires neither a VPS upgrade nor the installer and does not change the installed main-program version.

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

**Updating executable files, migrating managed state and business acceptance are separate steps.** A cross-version migration verifies and restores the source using its **fixed old Release**, then uses a checkpoint, two manual reboot gates and target apply/verify. See the [current migration procedure and historical appendix (Chinese)](docs/migration.md).

Run `dvt rollback` only when restoration conditions are complete and the entrypoint matches the state version. Normal rollback keeps project-created swap; confirm memory headroom before an explicit purge as described in the [rollback guide (Chinese)](docs/usage.md#回滚). On failure, retain state, checkpoints, backups and the ledger. Never delete state, guess original values or overwrite old state with new apply.

Use `reconfigure --port` for a bandwidth-only change. An invalid-parameter call rejected before writes needs no rollback; other changes follow their applicable recovery procedure.

## Validation status and limitations

- As of 2026-10-11, five Debian 13 VPS hosts have completed rc.2 migration and entrypoint installation, with `COMPLETE / VERIFIED` state and zero warnings from strict x-ui verification. The user confirmed panel access, real proxy traffic and reconnection for each host. Four use replacement recovery baselines and one uses historical evidence from the same deployment; see the [five-host acceptance record (Chinese)](docs/validation.md#rc2-fleet-acceptance). This does not establish quantitative performance gains or long-term stability. All five remain on rc.2; rc.3/rc.4 have not been migrated to or verified on these hosts.
- Seven isolated guest lifecycle jobs cover Debian 12/13 and Ubuntu 24.04 x86_64/ARM64 adaptive profiles, plus Debian 13 x86_64 legacy. They include real guest reboots, idempotency, reconfiguration and restoration. ARM64 uses QEMU/TCG on ARM runners; it is not vendor-specific hardware acceptance.
- Public IPv4 measurement and temporary HTB normal/signal-interrupted restoration have bounded VPS evidence. One complete low-rate sweep had 15 samples, 11 eligible, and still returned `INSUFFICIENT_EVIDENCE`. Reliable policer detection and proxy benefits remain unproven.
- The main business validation scenario is native systemd with 3X-UI/Xray/VLESS + REALITY + TCP. Recorded versions are 3X-UI v3.4.2 and Xray-core v26.6.27; other versions need separate verification. Persistent Docker, policy-routing, TProxy, gateway and complex-qdisc configurations are outside current support.
- 1–10000 Mbps is an input range. Broader public-path platform coverage, IPv6, high rates, specific large-resource hardware and business performance still have unvalidated areas.

Pinned commits, historical failures and detailed limits are recorded in the [platform matrix](docs/platform-support.md), [validation record](docs/validation.md) and [release notes](docs/releases/v0.2.0-rc.4.md), currently in Chinese.

## Documentation

The two README files share the current core workflows. Detailed guides below are in Chinese; their language does not imply a fully translated historical manual.

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

Use [GitHub Issues](https://github.com/alieismy/vps-tuning/issues) for usage questions, reproducible bugs and suggestions. Include the script version, OS/architecture, steps, exit status and sanitized output. Do not publish real addresses, credentials, subscription links, full proxy configurations or traceable report identifiers; see the [sanitization guide (Chinese)](docs/usage.md#日志脱敏与安全报告). Report security issues through the private channel in [SECURITY.md](SECURITY.md).

Reproducible fixes and documentation improvements are welcome. For profile changes, edit `tools/profile-template.sh.in` and the corresponding declarations, then regenerate; do not edit generated files alone. On Linux, run [`bash tests/static-check.sh`](tests/static-check.sh); experiment changes also need the applicable [experiment checks](experiments/htb-aggregate/tests/static-check.sh). Root lifecycle and platform requirements are in the [validation guide (Chinese)](docs/validation.md).

## License

[MIT License](LICENSE)

<details>
<summary>Previous section links (detailed guides in Chinese)</summary>

- <a id="1-online-installation"></a>[1. Online Installation](README.en-US.md#installation)
- <a id="2-online-verification-after-reboot"></a>[2. Online Verification After Reboot](docs/usage.md#入口不可用时的联网验证)
- <a id="3-strict-online-verification-after-3x-ui-installation"></a>[3. Strict Online Verification After 3X-UI Installation](docs/usage.md#入口不可用时的严格代理验证)
- <a id="4-execute-read-only-upgrade-check-from-early-rc-versions-historical-rc17-example"></a>[4. Execute Read-Only Upgrade Check from Early rc Versions (historical rc.17 example)](docs/migration.md#早期-rc-的历史-rc17-升级检查)
- <a id="5-online-execution-notes"></a>[5. Online Execution Notes](docs/usage.md#执行前准备)
- <a id="when-the-provider-already-supplies-bbrfq"></a>[When the Provider Already Supplies BBR/fq](docs/usage.md#厂商已预装-bbrfq-时的处理)
- <a id="real-environment-validation-baseline"></a>[Real Environment Validation Baseline](docs/validation.md#真实环境验证基线截至-2026-08-07)
- <a id="1c2g--200-mbps-performance-observation-case"></a>[1C2G / 200 Mbps Performance Observation Case](docs/validation.md#1c2g--200-mbps-性能观察案例)
- <a id="local-usage-and-command-line-mode"></a>[Local Usage and Command Line Mode](docs/usage.md#本地使用与命令行模式)
- <a id="applicable-scenarios"></a>[Applicable Scenarios](README.en-US.md#support-and-prerequisites)
- <a id="debian-1213-selection"></a>[Debian 12/13 Selection](docs/usage.md#历史系统选型说明2026-08-04)
- <a id="selection-by-vps-resource-tier"></a>[Selection by VPS Resource Tier](docs/usage.md#按-vps-资源档选择)
- <a id="virtualization-type-is-closer-to-kernel-reality-than-distro-name"></a>[Virtualization Type is Closer to Kernel Reality Than Distro Name](docs/usage.md#虚拟化类型比发行版名称更接近内核事实)
- <a id="script-selection"></a>[Script Selection](docs/usage.md#脚本选择)
- <a id="what-the-script-will-modify"></a>[What the Script Will Modify](docs/usage.md#脚本会修改什么)
- <a id="tcp-fast-open-and-xray-boundaries"></a>[TCP Fast Open and Xray Boundaries](docs/usage.md#tcp-fast-open-与-xray-的边界)
- <a id="what-the-script-will-not-modify"></a>[What the Script Will Not Modify](docs/usage.md#脚本不会修改什么)
- <a id="vps-initialization"></a>[VPS Initialization](docs/usage.md#vps-初始化)
- <a id="ufw-notes"></a>[UFW Notes](docs/usage.md#ufw-注意事项)
- <a id="download-and-verification"></a>[Download and Verification](docs/usage.md#下载与校验)
- <a id="usage"></a>[Usage](docs/usage.md#持久配置与验证)
- <a id="1-read-only-preflight"></a>[1. Read-Only Preflight](docs/usage.md#1-只读预检)
- <a id="2-apply"></a>[2. Apply](docs/usage.md#2-应用)
- <a id="3-verification-after-reboot"></a>[3. Verification After Reboot](docs/usage.md#3-重启后验证)
- <a id="4-verification-after-3x-ui-installation"></a>[4. Verification After 3X-UI Installation](docs/usage.md#4-安装-3x-ui-后验证)
- <a id="5-read-only-diagnose"></a>[5. Read-Only Diagnose](docs/usage.md#诊断与故障定位)
- <a id="6-research-only-explicit-iperf3-benchmark"></a>[6. Research-Only Explicit iperf3 Benchmark](docs/advanced-measurement.md#研究专用-benchmark)
- <a id="7-research-only-htb-reference-candidate-sweep-and-independent-aba-windows"></a>[7. Research-Only HTB Reference, Candidate Sweep, and Independent A/B/A Windows](docs/advanced-measurement.md#历史-htb-reference-与-aba)
- <a id="110000-mbps-configuration-inputs"></a>[1–10000 Mbps configuration inputs](docs/usage.md#110000-mbps-配置输入)
- <a id="parameters"></a>[Parameters](docs/usage.md#参数)
- <a id="state-and-idempotent-execution"></a>[State and Idempotent Execution](docs/usage.md#状态与重复执行)
- <a id="upgrading-from-rc15-to-rc16"></a>[Upgrading from rc.15 to rc.16](docs/migration.md#从-rc15-升级到-rc16)
- <a id="upgrading-from-rc14-to-rc15"></a>[Upgrading from rc.14 to rc.15](docs/migration.md#从-rc14-升级到-rc15)
- <a id="upgrading-from-rc13-to-rc14"></a>[Upgrading from rc.13 to rc.14](docs/migration.md#从-rc13-升级到-rc14)
- <a id="upgrading-from-rc12-to-rc13"></a>[Upgrading from rc.12 to rc.13](docs/migration.md#从-rc12-升级到-rc13)
- <a id="upgrading-from-rc11-to-rc12"></a>[Upgrading from rc.11 to rc.12](docs/migration.md#从-rc11-升级到-rc12)
- <a id="upgrading-from-rc8rc9-or-old-v5v6-to-rc10"></a>[Upgrading from rc.8/rc.9 or old v5/v6 to rc.10](docs/migration.md#从-rc8rc9-或旧-v5v6-升级到-rc10)
- <a id="rc2-empty-state-recovery"></a>[rc.2 Empty State Recovery](docs/migration.md#rc2-空状态恢复)
- <a id="rollback"></a>[Rollback](docs/usage.md#回滚)
- <a id="qdisc-boundaries"></a>[qdisc Boundaries](docs/usage.md#qdisc-边界)
- <a id="docker-boundaries"></a>[Docker Boundaries](docs/usage.md#docker-边界)
- <a id="validation-and-known-limitations"></a>[Validation and Known Limitations](README.en-US.md#validation-status-and-limitations)
- <a id="security-issues"></a>[Security Issues](docs/usage.md#日志脱敏与安全报告)

</details>
