# WSL 组件启用方案（待批准，未执行）

2026-09-09。Codex 阶段验收与范围限定。

WSL 2.7.13 MSI 已成功安装（退出码 0），版本查询成功。Windows 的 IWslSupport 接口缺失，WslService 启动退出 1058，Ubuntu 尚未注册。普通 DISM 功能查询报 0x800f080c；指定本机包查询后，发现对应功能处于 Disabled，包适用于本机且已暂存。不能据此断言启用一定成功，也不能承诺无需重启。

证据：`logs/wsl/diag-cbs-compare.json`、`logs/wsl/diag-start-service.json`、`logs/wsl/a0-package-featureinfo.txt`、`reports/wsl-install-result.json`。

## 拟执行的唯一系统变更

经用户明确批准后，由 Grok 执行以下命令，保存完整 DISM 日志与退出码：

```powershell
Dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /PackageName:Microsoft-Windows-Lxss-Optional-Package~31bf3856ad364e35~amd64~~10.0.26100.2314 /All /NoRestart /LimitAccess
```

此命令启用本机已暂存的 WSL 功能及其必需父功能；禁止自动重启，禁止从 Windows Update 下载组件。可能要求用户之后重启。Microsoft 官方文档支持指定父包启用功能，并解释了 `/All` 和 `/LimitAccess`：[DISM 包维护命令](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-operating-system-package-servicing-command-line-options?view=windows-11#enable-feature)。

## 执行后的检查与停止条件

1. 复核启用状态、IWslSupport 注册项、WslService 和版本/状态查询。记录确切退出码；若 3010 或其他明确重启提示，留待用户重启。
2. 若无需重启且服务正常，复用本地 Ubuntu 文件导入 `GS-Ubuntu2204`，检查 Ubuntu 22.04 与 GPU 接口，再继续已授权的最短视频流程。
3. 若失败，仅收集退出码和日志，不自动重复修复。禁止扩展为 `/Add-Package`、`/IgnoreCheck`、`RestoreHealth`、手工注册 COM/替换系统 DLL、重装 Windows 或改驱动。任何后续不同方案先形成独立审阅结果。

## 为何需要再次批准

用户此前批准的 WSL MSI 与 Ubuntu 安装已被执行。Grok 本轮尝试提交 DISM Enable-Feature/Add-Package 时，自动审批明确拒绝：修改 Windows 可选组件属于系统级维护，需要明确批准。该命令未执行。此方案将范围收窄到上述一次 Enable-Feature，移除被提议的 Add-Package/IgnoreCheck 后备；仍须等待用户对本次组件启用的批准，不能换工具绕过拒绝。

## 最新状态：组件已启用，等待 Windows 重启

用户最新授权已记录，未关闭或绕过自动审批。Grok 执行一次已审阅 DISM Enable-Feature 后，Codex 独立查询成功（exit 0）：Microsoft-Windows-Subsystem-Linux = Enabled。CBS 会话 31277147_3811460562 最终 S_OK，明确 Reboot required yes，CBSRebootPending 已存在。没有自动重启，IWslSupport 此时仍未出现，Ubuntu 尚未导入。

DISM 宿主/客户端在退出码写盘前消失，因此实际客户端退出码未知，不能捏造 3010，也不能重复启用。以上完成结论来自系统状态查询及 CBS 日志。报告：reports/wsl-feature-enable-result.json、reports/a0-wsl-feature-review.json。当前阻塞是重启，不是权限确认。重启后从 .grok-tasks/09-after-reboot-ubuntu.md 继续，环境通过后运行已准备的03最短片SfM任务。历史待批准/Disabled条目仅表示此前状态。
