@echo off
REM ===========================================================================
REM  Open-Guard-UI.cmd -- launch the standalone DSH Guard window.
REM
REM  This window does NOT depend on DSH. Even if DSH will not start at all,
REM  you can open it and roll the profile back to a good snapshot.
REM
REM  It goes through ui\Open-Guard-UI.vbs so that no console window flashes.
REM  For a proper Desktop shortcut WITH the guard icon, run
REM  Create-Desktop-Shortcut.cmd (a .cmd file cannot carry a custom icon).
REM
REM  This file is intentionally ASCII-only (cmd.exe reads .cmd as ANSI).
REM ===========================================================================
setlocal
wscript.exe "%~dp0ui\Open-Guard-UI.vbs"
endlocal
