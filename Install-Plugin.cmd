@echo off
REM ===========================================================================
REM  Install-Plugin.cmd -- install the DSH Guard plugin into your DSH profile.
REM
REM  Double-click this file. It runs Install-Plugin.ps1 with Windows PowerShell.
REM
REM  Optional arguments (append after the file name, or from a terminal):
REM     -Verify      check only: installed? registered in bundles? syntax ok?
REM     -Revert      uninstall (delete the folder + drop it from bundles)
REM
REM  This file is intentionally ASCII-only (cmd.exe reads .cmd as ANSI).
REM ===========================================================================
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Plugin.ps1" %*
echo.
echo --- finished (exit code: %ERRORLEVEL%) ---
pause
endlocal
