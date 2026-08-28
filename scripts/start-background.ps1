param(
    [string]$ProxyPath,
    [string]$ProxyExe = "",
    [string]$WorkingDirectory,
    [string]$LogPath,
    [string]$ErrLogPath
)

$WorkingDirectory = $WorkingDirectory.TrimEnd('\')
$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
if ($ProxyExe) {
    $env:REASONING_PROXY_FILE_LOG = "1"
    Start-Process -FilePath $ProxyExe -ArgumentList "--proxy" -WorkingDirectory $WorkingDirectory -WindowStyle Hidden
} else {
    $nodeCommand = "node `"$ProxyPath`" >> `"$LogPath`" 2>> `"$ErrLogPath`""
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $nodeCommand" -WorkingDirectory $WorkingDirectory -WindowStyle Hidden
}
