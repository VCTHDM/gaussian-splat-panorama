# WSL 离线安装计划（安装前落盘）

编制：2026-09-09。本文件写于下载/msiexec 之前。

## 依据

- Microsoft Learn WSL install → Offline install（Codex 已核验 2026-09-09）：下载 GitHub 微软官方 WSL MSI；启用 VirtualMachinePlatform；再装发行版。
- 本机 `VirtualMachinePlatform=Enabled`，`RestartNeeded=False`。
- 本机无 `wsl.exe`。`Microsoft-Windows-Subsystem-Linux` 可选功能名在此镜像上查询为空/未知（历史 DISM `0x800f080c`）。**不把该缺失可选功能当作永久阻塞。**
- 不安装预览通道（GitHub `latest` 非 prerelease = **2.7.13**；2.9.x 为 PreRelease，不用）。
- `msiexec /norestart`。不自动重启、不修组件存储、不改 BCD/启动、不换驱动。
- 下载上限 4GB。C: 空闲约 215 GiB（计划写入时核对）。

## 将发生的变化

1. 安装 `wsl.2.7.13.0.x64.msi`（约 247 MB）。预期：出现 `C:\Windows\System32\wsl.exe` 及 WSL 服务。可能返回 msiexec `3010`（成功但需重启才能启动 VM）。
2. 下载 Ubuntu 22.04.5 官方 `.wsl`（约 344 MB），导入为发行版 **GS-Ubuntu2204**，目录 `env/wsl/GS-Ubuntu2204`。不执行 `wsl --set-default`。现机无其它发行版，因此它会因“唯一发行版”成为默认，这不是改已有默认。
3. 不启用已缺失的旧可选功能 `Microsoft-Windows-Subsystem-Linux`。
4. 若 `wsl --status` 明确要求重启才能启动：停止在“MSI 已装 + 发行版文件已校验/已导入或已离线准备”，写入证据，**不重启**。

## 固定版本与校验

| 文件 | 来源 | SHA256 | 大小 |
|---|---|---|---|
| wsl.2.7.13.0.x64.msi | https://github.com/microsoft/WSL/releases/download/2.7.13/wsl.2.7.13.0.x64.msi （`repos/microsoft/WSL/releases/latest`，prerelease=false，2026-09-04） | `a3505a50f4cc585551d11d9de824ba4375448d7a68f2e71d3fb315fa986fc754` | 258985984 |
| ubuntu-22.04.5-wsl-amd64.wsl | https://releases.ubuntu.com/jammy/ubuntu-22.04.5-wsl-amd64.wsl （Microsoft `DistributionInfo.json` ModernDistributions Ubuntu-22.04 Amd64Url，2026-09-09 读取） | `4499c4fe257f2fc83145b429ce211a0a43fd590e70d6261ede616210947d9f8f` | 360684292 |

合计约 591 MB ≪ 4 GB。Authenticode 须为 Microsoft 有效签名，否则中止。

## 命令（预期）

```
msiexec /i <msi> /qn /norestart /L*v logs/wsl/msiexec-wsl-2.7.13.log
wsl --version
wsl --status
wsl --install --from-file <ubuntu.wsl> --name GS-Ubuntu2204 --location <repo>\env\wsl\GS-Ubuntu2204 --no-launch
```

`--from-file` 的精确开关以安装后 `wsl --help` 为准；若无 `--name/--location` 则改 `wsl --import`，仍不用 `--set-default`。

## 明确不做

- 预览版 WSL、`wsl --update --pre-release`
- 自动重启 / `shutdown /r`
- DISM 修复 / 启用未知可选功能
- 改驱动、改 hypervisorlaunchtype
- 卸载或改动任何已有发行版（当前无）
- 下载 torch / CUDA toolkit / 编译 PGSR
