# 本机 Grok CLI 调用指南

编制：2026-09-09。适用本仓库后续阶段调度。旧文档《本机执行架构与Agent分工.md》里的 Codex 多模型岗位表（gpt-6-astra / gpt-5.6-sol / luna / terra 等）**不再作为执行路由**。CMD 入口的 CRLF / 空 resume 细节见 [Grok-CMD补充.md](Grok-CMD补充.md)。

## 1. 现行路由（覆盖旧分工）

| 角色 | 谁做 | 做什么 | 不做什么 |
|---|---|---|---|
| A0 / 复杂审查 | Codex | 架构判断、任务路由、阶段验收、Grok 连续失败后的故障 | 不承担常规实现、环境准备、批处理等待 |
| 常规执行 | 本机 Grok CLI，模型 `grok-4.6-build` | 实现、环境准备、本地运行编排、写报告与交接 | 不轮询等待长计算；不递归再开一层 Grok 完成当前任务 |
| 长计算 | 独立本地进程（PowerShell / cmd / Python / 以后的 COLMAP、训练） | 解码、SfM、训练、融合 | 不要让大模型反复 `sleep`/轮询工具来盯进度 |

失败策略：**同一 Grok 任务最多再试 1 次（合计 2 次）**，仍失败则写入 handoff，上交 Codex。禁止用换模型或加轮次来掩盖环境缺口。

禁止：扫描凭据目录、倾倒环境变量、把密钥写进日志、远程 push、付费、改驱动、自动重启、上传原视频或派生帧到在线服务。

## 2. 已实测 vs 待验证

### 已实测

- 可执行文件：`C:\Users\Administrator\.grok\bin\grok.exe`
- 版本：`grok 1.0.13 (5e9a58528b76)`（`grok --version`）
- 帮助中存在且探针/本任务已用到：`-p` / `--single`、`--prompt-file`、`--cwd`、`--max-turns`、`--no-subagents`、`--output-format json`、`--resume SESSION_ID`
- 探针：一次只回复 `GROK_ROUTE_OK` 成功。JSON 含 `text` / `sessionId` / `stopReason` / `usage` / `modelUsage`。模型 `grok-4.6-build`
- 启动 stderr 可能出现：旧 Claude PowerShell 规则不被识别；`rhino` MCP 未运行。**探针仍成功**。不要改全局 `~/.grok` 配置，也不要为此启动 Rhino
- **权限模式**：`grok --help` 列出 `--permission-mode` 可选值 `default, acceptEdits, auto, dontAsk, bypassPermissions, plan`。本 bootstrap 任务实际调度命令为：

  `grok --prompt-file .grok-tasks/01-bootstrap.md --max-turns 35 --no-subagents --permission-mode auto --output-format json`

  该进程内文件读写与本机命令已自动执行、无交互授权提示。因此 **`--permission-mode auto` 对本机 headless 调度可用**（已实测）。不要把它理解成“改了全局配置”
- 包装脚本：`scripts/invoke-grok.ps1`、`scripts/invoke-grok.cmd`。**stub 实测**（`scripts/tests/test-invoke-grok.ps1`，不调用模型）覆盖：stdout/stderr 读取、非 0 退出、空 stdout、`max_turns`、未知 `stopReason`、中文/空格路径、路径末尾反斜杠、同秒 OutDir 碰撞。报告：`reports/wrapper-stub-tests.json`（25/25）
- doctor `grok --version` 在修复 `$Args` 陷阱后 15s 超时包装下 exit 0，stdout `grok 1.0.13 (5e9a58528b76)`

### 待验证（缺测保持 null，不要当成功）

- `--resume SESSION_ID`：**未验证成功**。帮助存在。对 `01a085cc-ed89-7ed2-844f-216a9b0cbc79` 的恢复在 `session_create` 约 3 分钟无新事件后已停止。**默认用新会话 + 阶段任务文件**；须 Codex 后续真实调用成功后再把 resume 标成已实测。禁止把“写过 `--resume` 参数”当成已经跑通过
- `--cwd` 与进程工作目录不一致时的工具根路径行为
- `auto` 与 `--always-approve`、`bypassPermissions`、`dontAsk` 的权限差异
- `--output-format streaming-json` / `streaming-messages-json` 的行协议
- `--fork-session`、`--json-schema`、`--session-id` 新建会话
- `stopReason` 的完整枚举。包装器**只把已确认的 `end_turn` 当业务成功**；`max_turns`→`incomplete`；未知原因→`needs_review`。不要自行补全枚举
- Chocolatey PATH 里的 `ffmpeg`：**已实测失败**（shim 目标不存在）。可用的是 WinGet `Gyan.FFmpeg.Shared` 8.1.2，见 `configs/tools.json`

## 2.1 Windows 陷阱（必须记住）

1. **不要把 PowerShell 参数命名为 `$Args`。** `$Args` 是自动变量。`Exe-Version([string]$Path,[string[]]$Args)` 会丢掉调用方传入的数组；`grok.exe` 实际命令行只剩可执行文件，进入交互界面，doctor 挂起。应使用 `VersionArgs` 等非自动变量名。
2. 外部诊断必须有超时：版本查询 15s，DISM 60s。超时只杀**自己启动的**子进程，并写入 `timed_out` / `killed_self_child`。
3. **CRT 引号规则**：引号前的反斜杠、以及闭引号前的反斜杠必须按 CommandLineToArgvW 加倍，否则 `C:\dir\` 会把闭引号吃掉。实现：`scripts/lib/WinProcess.ps1` 的 `Quote-WinArg`。PowerShell 5.1 里 `'\\'` 是两个字符，反斜杠比较要用 `[char]0x5C`。
4. 不要用 `WaitForExit` + PS 事件 + 50ms 收 stdout（会丢输出或死锁）。使用并发 `CopyToAsync`/`ReadToEndAsync` 把 stdout/stderr **边跑边落盘**（`FileShare.ReadWrite`，便于无模型本地监控）。
5. **不要读、不要改、不要打印认证相关环境变量。** 子进程继承默认环境即可。本机 PS 5.1 上 `ProcessStartInfo.Environment` 与 `EnvironmentVariables` 都存在，但包装器两者都不碰。
6. 成功判定：`transport_ok`（进程起来、退出、流捕获）与 `business_ok`（仅 `stopReason=end_turn` 且退出码 0 且 JSON 字段齐全）严格分开。JSON 文件存在 ≠ 成功。

## 3. 标准调用

二进制始终写绝对路径。项目根含空格与中文，**每个参数都加引号**。不要依赖当前目录碰巧正确。

### 3.1 PowerShell 7 / Windows PowerShell 5.1

先设 UTF-8，再用参数数组，避免中文路径被拆开：

```powershell
chcp 65001 | Out-Null
$OutputEncoding = [Console]::OutputEncoding = [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

$Grok = 'C:\Users\Administrator\.grok\bin\grok.exe'
$Root = 'C:\Users\Administrator\Desktop\01_项目与代码\高斯破溅'
$Task = Join-Path $Root '.grok-tasks\01-bootstrap.md'

& $Grok @(
  '--prompt-file', $Task,
  '--max-turns', '35',
  '--no-subagents',
  '--permission-mode', 'auto',
  '--output-format', 'json',
  '--cwd', $Root
)
```

恢复会话（**待验证**，默认不要用；写法如下，不得标成已跑通）：

```powershell
& $Grok @(
  '--resume', $SessionId,
  '--prompt-file', $Task,
  '--max-turns', '20',
  '--no-subagents',
  '--permission-mode', 'auto',
  '--output-format', 'json',
  '--cwd', $Root
)
```

推荐走包装器（把 stdout JSON、stderr 日志、退出码、交接状态拆开写盘）：

```powershell
& (Join-Path $Root 'scripts\invoke-grok.ps1') `
  -TaskFile (Join-Path $Root '.grok-tasks\02-next.md') `
  -MaxTurns 35 `
  -Cwd $Root
```

### 3.2 cmd.exe

先 `cd` 到项目根目录，再执行包装器。下面这一行可直接复制，**不要**写成 C 语言风格的 `\"` 转义：

```bat
scripts\invoke-grok.cmd ".grok-tasks\任务.md" "" 20
```

`invoke-grok.cmd` 参数：`任务文件` `[恢复SESSION_ID或空]` `[最大轮次]`。空 resume 必须是 `""`，由包装器省略 `-ResumeSessionId`。CMD 入口限制见 [Grok-CMD补充.md](Grok-CMD补充.md)。

直接调 `grok.exe`（需要绝对路径时）：

```bat
set "GROK=C:\Users\Administrator\.grok\bin\grok.exe"
set "ROOT=C:\Users\Administrator\Desktop\01_项目与代码\高斯破溅"
"%GROK%" --prompt-file "%ROOT%\.grok-tasks\01-bootstrap.md" --max-turns 35 --no-subagents --permission-mode auto --output-format json --cwd "%ROOT%"
```

### 3.3 不要这样调用

- `grok -p "..."` 再让模型去 `grok --prompt-file ...`（嵌套 Grok）
- 把密钥、`GROK_*`、`XAI_*` 拼进命令行或打印 `Get-ChildItem Env:`
- `where ffmpeg` 后直接用 PATH 第一项
- 仅凭“生成了 `.json` 文件”判定成功
- 训练/SfM 期间让 Grok 循环查日志。应：本地脚本启动 → 写 `jobs/<id>/state.json` → 进程结束后再开**一次** Grok 读产物

## 4. JSON 输出、日志、session ID

`--output-format json` 时，stdout 应是一个 JSON 对象。已实测字段：

| 字段 | 用途 |
|---|---|
| `text` | 最终回复正文 |
| `sessionId` | 续跑与 `grok --resume` 用 |
| `stopReason` | 停止原因；不能只看进程退出码 |
| `usage` | 用量 |
| `modelUsage` | 分模型用量 |
| （隐式）模型名 | 探针为 `grok-4.6-build` |

stderr 可能含 MCP/规则警告，**警告 ≠ 失败**。包装器把 stderr 写入独立 `.log`，把 stdout 原样写入 `.json`。

成功判定分两层：

**transport_ok**（可以失败但必须记录）：进程启动、退出、stdout/stderr 已落到 `grok-stdout.json` / `grok-stderr.log`。

**status=ok / business_ok**（缺一不可）：

1. `transport_ok` 且进程退出码 `0`
2. stdout JSON **能解析**
3. 非空 `sessionId`、`stopReason`；`text` 字段存在（允许空字符串，但要记录）
4. `stopReason` **恰好是已确认的 `end_turn`**
5. `stopReason` 在失败集合（`error` / `aborted` / `cancelled` / `refused` / `permission_denied`）→ `failed`
6. `max_turns` → `incomplete`（包装器 exit 2），不是阶段完成
7. **未知 `stopReason` → `needs_review`（包装器 exit 3），不是成功**

JSON 文件存在但解析失败、缺字段、退出码非 0：均为失败。OutDir 默认带毫秒+8 位随机后缀；若目标目录已有 `grok-stdout.json` 则另建后缀目录，避免同一秒覆盖。

续跑：默认新会话。仅当 Codex 后续真实 `--resume` 成功后再更新本节。不要手抄密钥。认证沿用本机已登录状态，包装器不读 `~/.grok` 凭据文件，不读 `GROK_*`/`XAI_*`。

## 4.1 阶段调度与两类失败（不要混）

阶段默认：**新会话 + `.grok-tasks/` 任务文件 + 硬盘 handoff**。原 bootstrap session `01a085cc-ed89-7ed2-844f-216a9b0cbc79` 的 `--resume` 在 `session_create` 约 3 分钟无新事件后已停止，**resume 仍未验证**。不要用旧 session 续跑掩盖阶段边界。

把下面两类失败分开写进 handoff，禁止互相替换工具来“接着干”：

1. **网络/超时/续传**：下载未完、curl 超时、Range 探测失败。可以续传、换连接策略、把 pid/result 交给下一会话监督。**不要**把 running 写成 ready。
2. **自动审批拒绝**：系统级安装（msiexec、winget 安装、注册/启动发行版）被拒绝后，必须等待用户明确批准。禁止换 WSL 安装方式、禁止用旧任务文件里的授权覆盖最新拒绝。

`stopReason=cancelled` 且进程退出码 0 **不是**业务成功。包装器只把已确认的 `end_turn` 当 `business_ok`。

## 5. 独立阶段交接

每个 Grok 阶段结束必须留下（示例）：

```text
jobs/<job-id>/
  state.json          # queued|running|validating|done|retryable|needs_codex
  logs/
  reports/
```

`state.json` 最低字段：`job_id, stage, status, session_id, grok_exit_code, stop_reason, outputs[], issues[], next_owner, attempts`。缺测填 `null`。

`next_owner`：`grok` | `local-process` | `codex`。

长任务：Grok 只负责写启动脚本和验收清单，计算进程脱离模型生命周期。

## 6. 凭据与配置

- 继承当前用户已有 Grok 登录，不要在脚本里 `grok login` / `logout`
- 不读取、不复制、不打印任何密钥文件或含 `KEY`/`TOKEN`/`SECRET` 的环境变量值
- 不修改 `C:\Users\Administrator\.grok\config.toml` 来“修复” Claude 规则或 Rhino MCP 警告
- 日志只保存 argv、退出码、解析后的非敏感 JSON 字段

## 7. 本仓库调度入口

| 入口 | 说明 |
|---|---|
| `AGENTS.md` | 精简路由：Codex 架构/验收，Grok 执行，安装拒绝闸门 |
| `.grok-tasks/*.md` | 给 Grok 的任务书。本阶段为 `01-bootstrap.md` |
| `scripts/invoke-grok.ps1` | 主包装 |
| `scripts/invoke-grok.cmd` | cmd 转发。项目根复制：`scripts\invoke-grok.cmd ".grok-tasks\任务.md" "" 20` |
| `configs/tools.json` | 本机工具绝对路径（无密钥） |
| `env/gs-control` | 输入检查用隔离 Python 3.11，不往系统 Python 装包 |
| `docs/environment.md` | 版本锁定与 WSL 安装边界 |
| `scripts/lib/WinProcess.ps1` | CRT 引号 + 超时杀自己的子进程 + 流式落盘 |

后续任务文件继续放 `.grok-tasks/`，用包装器调用，产物进 `jobs/` 与 `reports/`。默认**新会话 + 阶段文件**，不要对本仓库未验证的 session id 使用 `--resume`。

## 8. A0 实测补记（2026-09-09）

- CMD 已经做过真实模型探针，而不只是 stub：退出 0，`stopReason=end_turn`，正文精确为 `GROK_WRAPPER_OK`；证据为 `reports/cmd-entry-fix.json`。主入口为 `scripts/invoke-grok.cmd`；在项目根 CMD 中调用 `scripts\invoke-grok.cmd ".grok-tasks\任务.md" "" 20`。详细编码约定见 [Grok-CMD补充.md](Grok-CMD补充.md)。
- Grok 1.0.13 实测在达到 `--max-turns 20` 时会返回 `stopReason=cancelled`，stderr 写 `Error: max turns reached`，进程退出 1。不要只凭 cancelled 就声称用户取消；对照 stderr、实际轮数和产物。包装器仍保守记为失败，A0 验收可复用产物，再缩小任务或交给本地进程。
- `Start-Process` 返回 PID 只证明曾启动。必须在父工具返回后确认进程仍存在、日志时间在更新，完成后再检查结果 JSON、退出码和输出。此轮启动后进程消失的情况由 A0 通过持续执行会话运行 Grok 已生成的下载脚本接管。长计算不需要大模型反复调用等待工具。
- 打开的下载文件在 Windows 目录查询中曾显示长度 0，而 curl 日志已显示实际接收数据。监督应结合进程、curl 日志及打开文件的长度；关闭并校验后再确认最终大小。
- 600 秒下载总时限对慢网络不足。固定版本、Range/ETag/大小确认后续传；保留部分文件，最终必须核对完整 SHA256。WSL MSI 的续传已实测成功。
- 系统安装被自动审批拒绝，与网络错误和轮次耗尽是不同情况。此次 WSL/Ubuntu 系统安装仍须用户明确确认；禁止重试原安装或改用别的工具绕过拒绝。普通离线下载、校验和报告仍可继续。
