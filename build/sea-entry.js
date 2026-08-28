const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const os = require("node:os");
const { spawnSync } = require("node:child_process");
const sea = require("node:sea");

const ASSET_NAMES = [
  "scripts/proxy.js",
  "scripts/proxy-gui.ps1",
  "scripts/start.bat",
  "scripts/start-background.ps1",
  "scripts/gui.vbs",
  "assets/logo.png",
  "assets/logo.ico",
  "config/config.bat",
];

function getAssetBuffer(name) {
  const asset = sea.getAsset(name);
  return Buffer.isBuffer(asset) ? asset : Buffer.from(asset);
}

function appDataDir() {
  return (
    process.env.LOCALAPPDATA ||
    path.join(os.homedir(), "AppData", "Local")
  );
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function runtimeDir() {
  const hash = crypto.createHash("sha256");
  for (const name of ASSET_NAMES) {
    hash.update(name);
    hash.update(getAssetBuffer(name));
  }
  const version = hash.digest("hex").slice(0, 16);
  return path.join(appDataDir(), "ReasoningProxy", "runtime", version);
}

function writeAssetIfChanged(target, content) {
  try {
    const current = fs.readFileSync(target);
    if (Buffer.compare(current, content) === 0) return;
  } catch {}
  ensureDir(path.dirname(target));
  fs.writeFileSync(target, content);
}

function extractRuntime() {
  const dir = runtimeDir();
  ensureDir(dir);
  for (const name of ASSET_NAMES) {
    writeAssetIfChanged(path.join(dir, name), getAssetBuffer(name));
  }
  return dir;
}

function canWriteDir(dir) {
  try {
    ensureDir(dir);
    fs.accessSync(dir, fs.constants.W_OK);
    const testPath = path.join(dir, ".reasoning-proxy-write-test");
    fs.writeFileSync(testPath, "");
    fs.rmSync(testPath, { force: true });
    return true;
  } catch {
    return false;
  }
}

function chooseDataDir(preferredDir) {
  if (canWriteDir(preferredDir)) return preferredDir;
  const fallbackDir = path.join(appDataDir(), "ReasoningProxy", "data");
  ensureDir(fallbackDir);
  return fallbackDir;
}

function ensureDefaultData(runtime, dataDir) {
  const configDir = path.join(dataDir, "config");
  const configPath = path.join(configDir, "config.bat");
  const logsDir = path.join(dataDir, "logs");

  ensureDir(configDir);
  ensureDir(logsDir);

  if (!fs.existsSync(configPath)) {
    fs.writeFileSync(configPath, getAssetBuffer("config/config.bat"));
  }
}

function runProxy(runtime, dataDir) {
  process.env.REASONING_PROXY_DIR = dataDir;
  process.env.REASONING_PROXY_RUNTIME_DIR = runtime;
  process.env.REASONING_PROXY_FILE_LOG = "1";

  const proxyPath = path.join(runtime, "scripts", "proxy.js");
  const code = fs.readFileSync(proxyPath, "utf8");
  const proxyModule = { exports: {} };

  // SEA may not load extra files through require, but it can run extracted
  // CommonJS source as a normal module body.
  const loadModule = new Function(
    "exports",
    "require",
    "module",
    "__filename",
    "__dirname",
    code
  );
  loadModule(proxyModule.exports, require, proxyModule, proxyPath, path.dirname(proxyPath));
}

function startGui(runtime, dataDir) {
  const scriptPath = path.join(runtime, "scripts", "proxy-gui.ps1");

  const psQuote = (value) => `'${String(value).replace(/'/g, "''")}'`;
  const command = [
    `$ErrorActionPreference = 'Stop'`,
    `$env:REASONING_PROXY_DIR = ${psQuote(dataDir)}`,
    `$env:REASONING_PROXY_RUNTIME_DIR = ${psQuote(runtime)}`,
    `$env:REASONING_PROXY_EXE = ${psQuote(process.execPath)}`,
    `$guiScript = ${psQuote(scriptPath)}`,
    `$logDir = Join-Path ${psQuote(dataDir)} 'logs'`,
    `if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }`,
    `Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$guiScript) -WorkingDirectory ${psQuote(dataDir)} -WindowStyle Hidden`,
  ].join("\n");
  const encodedCommand = Buffer.from(command, "utf16le").toString("base64");

  const result = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encodedCommand],
    {
      windowsHide: true,
      encoding: "utf8",
    }
  );

  if (result.error || result.status !== 0) {
    const detail = result.error?.stack || result.stderr || `powershell exited with code ${result.status}`;
    throw new Error(detail);
  }
}

function main() {
  const exeDir = path.dirname(process.execPath);

  if (!sea.isSea()) {
    console.error("[sea] run this file from the packaged ReasoningProxy.exe");
    process.exitCode = 1;
    return;
  }

  const args = process.argv.slice(2);
  const proxyMode = args.includes("--proxy");
  const runtime = process.env.REASONING_PROXY_RUNTIME_DIR || extractRuntime();
  const dataDir =
    process.env.REASONING_PROXY_DIR || (proxyMode ? exeDir : chooseDataDir(exeDir));

  ensureDefaultData(runtime, dataDir);

  if (proxyMode) {
    runProxy(runtime, dataDir);
    return;
  }

  startGui(runtime, dataDir);
}

try {
  main();
} catch (err) {
  console.error(err);
  process.exit(1);
}
