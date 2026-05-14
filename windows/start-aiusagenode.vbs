' AI Usage Node - silent launcher
' Runs AIUsageNode.ps1 with no visible console window. Pointed at by the
' HKCU\...\Run autostart entry so the tray icon comes up at login.
Set sh = CreateObject("WScript.Shell")
scriptDir = Replace(WScript.ScriptFullName, "\" & WScript.ScriptName, "")
psScript  = scriptDir & "\AIUsageNode.ps1"

' Prefer PowerShell 7 if available, fall back to Windows PowerShell 5.1.
psExe = "powershell.exe"
On Error Resume Next
sh.RegRead("HKLM\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions\")
If Err.Number = 0 Then psExe = "pwsh.exe"
Err.Clear
On Error Goto 0

cmd = """" & psExe & """ -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psScript & """"
sh.Run cmd, 0, False
