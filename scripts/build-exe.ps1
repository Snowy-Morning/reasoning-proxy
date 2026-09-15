param(
    [string]$OutputName = "ReasoningProxy.exe",
    [string]$Version = "1.2.2"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot "build"
$distDir = Join-Path $repoRoot "dist"
$blobPath = Join-Path $buildDir "sea-prep.blob"
$seaConfigPath = Join-Path $buildDir "sea-config.generated.json"
$versionPath = Join-Path $buildDir "sea-version.txt"
$outExe = Join-Path $distDir $OutputName
$sentinelFuse = "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2"

Set-Location $repoRoot

if (Test-Path $distDir) {
    Remove-Item $distDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

Write-Host "[build] creating SEA blob..."
# The packaged exe needs its own version at runtime to register itself under
# Settings > Apps. sea.getConfig() does not exist in the Node we build with, so
# the version rides along as an extra asset instead. A generated copy of the
# config keeps sea-config.json itself free of build-time values.
$seaConfig = Get-Content (Join-Path $repoRoot "sea-config.json") -Raw | ConvertFrom-Json
Set-Content -LiteralPath $versionPath -Value $Version -Encoding ASCII -NoNewline
$seaConfig.assets | Add-Member -NotePropertyName "version" -NotePropertyValue "build/sea-version.txt" -Force
# Depth 2 is the PowerShell default and would flatten the nested asset map.
$seaConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $seaConfigPath -Encoding ASCII
node --experimental-sea-config $seaConfigPath
if ($LASTEXITCODE -ne 0) {
    throw "Node SEA config failed with exit code $LASTEXITCODE"
}

$nodeExe = (Get-Command node.exe).Source
Write-Host "[build] copying node runtime: $nodeExe"
Copy-Item $nodeExe $outExe -Force

Write-Host "[build] injecting SEA blob..."
npx --yes postject $outExe NODE_SEA_BLOB $blobPath --sentinel-fuse $sentinelFuse
if ($LASTEXITCODE -ne 0) {
    throw "postject failed with exit code $LASTEXITCODE"
}

Write-Host "[build] setting exe icon..."
$iconPath = Join-Path $repoRoot "assets\logo.ico"
$toolDir = Join-Path $env:TEMP "reasoning-proxy-build-resedit"
$toolModules = Join-Path $toolDir "node_modules"
# A half-cleaned cache can leave the package folders present but empty, so check
# the exact files set-exe-icon.mjs imports and reinstall from scratch if any is
# missing rather than failing near the end of the build.
$neededModuleFiles = @(
    (Join-Path $toolModules "resedit\package.json"),
    (Join-Path $toolModules "resedit\dist\index.js"),
    (Join-Path $toolModules "pe-library\dist\index.js")
)
if (@($neededModuleFiles | Where-Object { -not (Test-Path $_) }).Count -gt 0) {
    Remove-Item $toolDir -Recurse -Force -ErrorAction SilentlyContinue
    npm install --prefix $toolDir resedit --no-audit --no-fund --silent
    if ($LASTEXITCODE -ne 0) {
        throw "npm install resedit failed with exit code $LASTEXITCODE"
    }
}

node (Join-Path $repoRoot "scripts\set-exe-icon.mjs") $outExe $iconPath $toolModules $Version
if ($LASTEXITCODE -ne 0) {
    throw "setting exe icon failed with exit code $LASTEXITCODE"
}

if (Test-Path $blobPath) {
    Remove-Item $blobPath -Force
}
if (Test-Path $seaConfigPath) {
    Remove-Item $seaConfigPath -Force
}
if (Test-Path $versionPath) {
    Remove-Item $versionPath -Force
}

Write-Host "[build] done: $outExe"
Write-Host "[build] run: .\$OutputName"
Write-Host "[build] background proxy: .\$OutputName --proxy"
