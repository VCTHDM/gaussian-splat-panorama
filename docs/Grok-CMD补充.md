# Grok CMD 入口补充

`scripts/invoke-grok.cmd` 是 Windows 批处理入口，转调同目录 `invoke-grok.ps1`。不要用 LF 行尾，也不要在本文件里 `chcp 65001`。

## 已知失败（已修）

- **现象**：`cmd.exe /d /c` 立刻退出 1；出现 `'ensions'/'t'/'cho'/'voke-grok.cmd' is not recognized`；Grok 未启动。
- **原因**：脚本为 LF（无 CR）。`chcp 65001` 在 LF 批处理里会吃掉后续行首字符，命令被拆碎。
- **修复**：ASCII 正文、CRLF、无 BOM、无 `chcp`。UTF-8 控制台由 `invoke-grok.ps1` 的 `Protect-Utf8Console` 处理。中文目录靠 `%~dp0` 传给 `-File`，不在 CMD 里写中文示例。

## 调用约定

```text
invoke-grok.cmd TASK_FILE [RESUME_SESSION_ID] [MAX_TURNS]
```

- 无 `TASK_FILE`：打印 Usage，退出 **2**。
- `setlocal EnableExtensions DisableDelayedExpansion`：保留参数中的 `!` 等字符。
- 空 resume（省略、`""`、或未定义）**不传** `-ResumeSessionId`，避免 PowerShell 5.1 把空 `""` 吞掉后参数错位（`-MaxTurns` 被当成 resume）。
- 有非空 resume 才传 `-ResumeSessionId`。
- `MaxTurns` 缺省 35；数值合法性由 PS1 校验（`< 1` 抛错）。
- 使用 `call powershell.exe ...` 再 `exit /b %ERRORLEVEL%`，把包装器退出码原样传出。
- 成功路径在括号外（`goto` 分支），避免 `%ERRORLEVEL%` 在 `()` 块里被提前展开。

## 验证用法（不要用 stub 代替）

Usage：

```text
cmd.exe /d /c "scripts\invoke-grok.cmd"
```

期望退出 2，stdout 含 `Usage: invoke-grok.cmd`。

真实一轮探针（空 resume + MaxTurns=1）：

```text
scripts\invoke-grok.cmd ".grok-tasks\wrapper-smoke.md" "" 1
```

期望：包装器退出 0；`handoff.json` 中 `stop_reason=end_turn`；模型原文精确为 `GROK_WRAPPER_OK`。记录见 `reports/cmd-entry-fix.json`。

上面一行在项目根目录的CMD里执行。若从PowerShell调用，可用实际验证过的形式：

```powershell
cmd.exe /d /c 'scripts\invoke-grok.cmd ".grok-tasks\wrapper-smoke.md" "" 1'
```

不要把C语言风格的反斜杠转义双引号直接抄给CMD。
