@echo off
REM ===========================================================================
REM  Uninstall-Watchdog.cmd -- stop and remove the DSH Guard watchdog.
REM
REM  It stops the watchdog process, removes the Startup shortcut, and
REM  unregisters the Scheduled Task. Removing the Scheduled Task needs
REM  administrator rights, so Windows shows ONE UAC prompt -- click Yes.
REM
REM  Why this matters: if the task is left behind, Windows will start the
REM  watchdog again at your next logon.
REM
REM  This file is intentionally ASCII-only (cmd.exe reads .cmd as ANSI).
REM ===========================================================================
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\uninstall-watchdog.ps1" -Profile web %*
echo.
echo --- finished (exit code: %ERRORLEVEL%) ---
pause
endlocal
