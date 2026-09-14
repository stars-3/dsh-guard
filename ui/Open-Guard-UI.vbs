' ===========================================================================
'  Open-Guard-UI.vbs -- launch the standalone DSH Guard window with no console.
'
'  Why a .vbs: a .cmd always flashes a console window, and a .cmd cannot carry
'  a custom icon. A shortcut can: point it at wscript.exe with this file as the
'  argument and set its icon to ui\guard.ico (see Create-Desktop-Shortcut.cmd).
'
'  This file is intentionally ASCII-only -- .vbs must be kept in ANSI/GBK or
'  Windows Script Host reports "invalid character (800A0408)".
' ===========================================================================
Option Explicit

Dim fso, sh, here, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = fso.BuildPath(here, "Guard-UI.ps1")

If Not fso.FileExists(ps1) Then
    MsgBox "Guard-UI.ps1 not found next to this launcher:" & vbCrLf & ps1, _
           16, "DSH Guard"
    WScript.Quit 2
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
' 0 = hidden console, False = do not wait
sh.Run cmd, 0, False
