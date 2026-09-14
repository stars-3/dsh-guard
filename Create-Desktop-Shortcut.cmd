@echo off
REM ===========================================================================
REM  Create-Desktop-Shortcut.cmd -- put a DSH Guard shortcut on your Desktop,
REM  using the project's own icon (ui\guard.ico).
REM
REM  Why a shortcut is needed for the icon: .cmd and .vbs files cannot carry a
REM  custom icon -- only .lnk can. The shortcut targets wscript.exe +
REM  ui\Open-Guard-UI.vbs, so launching it does not flash a console window.
REM
REM  This file is intentionally ASCII-only (cmd.exe reads .cmd as ANSI).
REM ===========================================================================
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ui\Guard-UI.ps1" -CreateShortcut
echo.
echo --- finished (exit code: %ERRORLEVEL%) ---
pause
endlocal
