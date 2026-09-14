@echo off
REM ===========================================================================
REM  Install-Watchdog-NoAdmin.cmd -- install the watchdog WITHOUT admin rights.
REM
REM  It puts a shortcut in your Startup folder instead of registering a
REM  Scheduled Task, so Windows never asks for UAC. Explorer launches it when
REM  you log in, and the watchdog then keeps watching DSH.
REM
REM  (The author's machine already runs the older DSH supervisor this way.)
REM
REM  This file is intentionally ASCII-only (cmd.exe reads .cmd as ANSI).
REM ===========================================================================
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\install-watchdog.ps1" -Profile web -UseStartup %*
echo.
echo --- finished (exit code: %ERRORLEVEL%) ---
pause
endlocal
