param(
    [string]$ProxyPath,
    [string]$WorkingDirectory,
    [string]$LogPath,
    [string]$ErrLogPath
)

$WorkingDirectory = $WorkingDirectory.TrimEnd('\')
$nodeCommand = "node `"$ProxyPath`" >> `"$LogPath`" 2>> `"$ErrLogPath`""
Start-Process -FilePath "cmd.exe" -ArgumentList "/c $nodeCommand" -WorkingDirectory $WorkingDirectory -WindowStyle Hidden
