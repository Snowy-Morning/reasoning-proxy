param(
    [string]$OutputName = "ReasoningProxy.exe"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot "build"
$distDir = Join-Path $repoRoot "dist"
$blobPath = Join-Path $buildDir "sea-prep.blob"
$outExe = Join-Path $distDir $OutputName
$sentinelFuse = "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2"

Set-Location $repoRoot

if (Test-Path $distDir) {
    Remove-Item $distDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

Write-Host "[build] creating SEA blob..."
node --experimental-sea-config sea-config.json
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
if (-not (Test-Path (Join-Path $toolModules "resedit"))) {
    npm install --prefix $toolDir resedit --no-audit --no-fund --silent
    if ($LASTEXITCODE -ne 0) {
        throw "npm install resedit failed with exit code $LASTEXITCODE"
    }
}

node (Join-Path $repoRoot "scripts\set-exe-icon.mjs") $outExe $iconPath $toolModules
if ($LASTEXITCODE -ne 0) {
    throw "setting exe icon failed with exit code $LASTEXITCODE"
}

if (Test-Path $blobPath) {
    Remove-Item $blobPath -Force
}

Write-Host "[build] done: $outExe"
Write-Host "[build] run: .\$OutputName"
Write-Host "[build] background proxy: .\$OutputName --proxy"
