param(
    [string]$ProxyPath,
    [string]$WorkingDirectory,
    [string]$LogPath,
    [string]$ErrLogPath
)

$WorkingDirectory = $WorkingDirectory.TrimEnd('\')
$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
$nodeCommand = "node `"$ProxyPath`" >> `"$LogPath`" 2>> `"$ErrLogPath`""
Start-Process -FilePath "cmd.exe" -ArgumentList "/c $nodeCommand" -WorkingDirectory $WorkingDirectory -WindowStyle Hidden
