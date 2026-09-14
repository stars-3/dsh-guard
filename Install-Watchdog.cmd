@echo off
REM ===========================================================================
REM  Install-Watchdog.cmd -- install the DSH Guard watchdog.
REM
REM  This one registers a Scheduled Task, which needs administrator rights:
REM  Windows will show a UAC prompt -- click Yes.
REM
REM  If you do NOT want to grant admin (or UAC keeps getting refused), use
REM  Install-Watchdog-NoAdmin.cmd instead: same watchdog, installed into the
REM  Startup folder, no admin at all.
REM
REM  Extra arguments are passed through, e.g.
REM      Install-Watchdog.cmd -UseStartup      (same as the NoAdmin script)
REM      Install-Watchdog.cmd -WebPort 3101    (pin the port to watch)
REM
REM  This file is intentionally ASCII-only (cmd.exe reads .cmd as ANSI).
REM ===========================================================================
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\install-watchdog.ps1" -Profile web %*
echo.
echo --- finished (exit code: %ERRORLEVEL%) ---
pause
endlocal
