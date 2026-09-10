@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
if "%~1"=="" (
  echo Usage: invoke-grok.cmd TASK_FILE [RESUME_SESSION_ID] [MAX_TURNS]
  exit /b 2
)
set "TASK=%~1"
set "RESUME=%~2"
set "TURNS=%~3"
if "%TURNS%"=="" set "TURNS=35"

if not defined RESUME goto :run_no_resume
if "%RESUME%"=="" goto :run_no_resume

call powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%invoke-grok.ps1" -TaskFile "%TASK%" -ResumeSessionId "%RESUME%" -MaxTurns %TURNS%
exit /b %ERRORLEVEL%

:run_no_resume
call powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%invoke-grok.ps1" -TaskFile "%TASK%" -MaxTurns %TURNS%
exit /b %ERRORLEVEL%
