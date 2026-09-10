# WSL 服务阻塞：诊断与恢复方案

编制：2026-09-09。只读诊断 + 一次 `Start-Service WslService`。未重装 MSI、未下 Ubuntu、未改注册表、未自动重启、未推进 SfM。

## 结论（事实）

MSI 已成功（exit 0），`C:\Program Files\WSL\wsl.exe --version` 为 2.7.13.0。`WslService` 仍 Stopped / Win32 **1058**。一次 `Start-Service` 2.4s 失败，同一 1058。`wsl --status` 15s 无输出后已杀子进程（exit unknown）。

官方 2.7.13 源码：`helpers.cpp` 第31行键 `Software\Classes\Interface\{46f3c96d-ffa3-42f0-b052-52f5e7ecbb08}`；第481–493行 `IsWslSupportInterfacePresent()` 只读 HKLM 该键。`ServiceMain.cpp` 第174行若接口不存在则 `ERROR_SERVICE_DISABLED`（1058）。本机签名 `wslservice.exe` Unicode 含同一键。HKLM/HKCR 该键**不存在**。证据：`logs/wsl/wsl-2.7.13-src/`、`logs/wsl/diag-readonly-pass1.json`、`logs/wsl/diag-wslservice-strings.json`。

`System32\wslsupport.dll` 不存在。WinSxS 同名文件 2454 字节、魔数 DCS，不是 PE。DISM 包 `Microsoft-Windows-Lxss-Optional-Package~...26100.2314`：**适用=是，状态=暂存，功能 `Microsoft-Windows-Subsystem-Linux`=已禁用，重启=Possible**。`Get-FeatureInfo` 仍 0x800f080c 未知。CheckHealth exit 0。发行版注册表仅 `Lxss\MSI`，`env/wsl/GS-Ubuntu2204` 0 文件。

`distro_install exit -1`：Codex 结束卡住的导入 client **26368**（父 17152），**不是**自然安装失败，也**不是**新的审批拒绝。06 Grok 因轮次上限退出，不是安全拒绝。

## 不要做

造接口注册表、复制 DCS 占位 DLL、盲目 RestoreHealth、仅凭 1058 重启、换 ISO/重装系统/改驱动、再空等 `wsl` 15 分钟。PendingFileRename 仅为 Chrome 临时文件，CBS/WU 无 RebootPending。

## 需用户选择（新动作，本会话自动审批已拒绝 DISM 启用）

MSI/Ubuntu 批准仍有效，但**不等于**批准下面这条系统组件启用。

**路线 A（优先，需明确批准）** 启用本机已暂存功能，`/NoRestart`：

```text
Dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /PackageName:Microsoft-Windows-Lxss-Optional-Package~31bf3856ad364e35~amd64~~10.0.26100.2314 /All /NoRestart /LimitAccess
```

成功后再核对接口键、`Start-Service WslService`、`--import GS-Ubuntu2204`。启用退出码与是否必须重启 = **unknown**。若报源文件缺失，改走 B。

**路线 B** 用匹配 26100.2314 的官方 24H2 安装源做指定源启用或就地修复。可能重启。需用户另选。

启用成功前不导入发行版、不跑 SfM。安装脚本已加：服务未运行则跳过导入并 exit 23，client 15s。

## A0 审阅补充

指定 PackageName 的只读 Get-FeatureInfo 已 exit 0，明确 Disabled / Restart Possible，见 logs/wsl/a0-package-featureinfo.txt。当前审批只针对路线 A，执行范围与停止条件以 `WSL组件启用方案.md` 为准；不得自动转路线 B 或 Add-Package/IgnoreCheck。
