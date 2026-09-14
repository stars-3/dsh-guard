@echo off
REM ===========================================================================
REM  Uninstall-Plugin.cmd -- remove the DSH Guard plugin from your DSH profile.
REM
REM  Deletes <profile>\node_modules\dsh-guard and drops "dsh-guard" from the
REM  profile's dsh.profile.bundles. Your snapshots in %USERPROFILE%\.dsh-guard
REM  are KEPT (delete that folder by hand if you want them gone too).
REM
REM  Restart DSH afterwards.
REM
REM  This file is intentionally ASCII-only (cmd.exe reads .cmd as ANSI).
REM ===========================================================================
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Plugin.ps1" -Revert %*
echo.
echo --- finished (exit code: %ERRORLEVEL%) ---
pause
endlocal
