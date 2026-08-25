$root = Split-Path -Parent $PSScriptRoot
$vbs = Join-Path $PSScriptRoot 'gui.vbs'
$lnk = Join-Path $root 'Reasoning Proxy.lnk'
$icon = Join-Path $root 'assets\logo.ico'
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnk)
$shortcut.TargetPath = $wscript
$shortcut.Arguments = "`"$vbs`""
$shortcut.IconLocation = "$icon,0"
$shortcut.WorkingDirectory = $root
$shortcut.Description = 'Reasoning Proxy GUI'
$shortcut.Save()

Write-Host "Shortcut created: $lnk"
