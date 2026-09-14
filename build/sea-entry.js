const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const os = require("node:os");
const { spawnSync } = require("node:child_process");
const sea = require("node:sea");

const ASSET_NAMES = [
  "scripts/proxy.js",
  "scripts/proxy-gui.ps1",
  "scripts/language-models.ps1",
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

// Runtime folders are keyed by asset hash, so every released version leaves one
// behind forever unless a later launch clears the others.
const RUNTIME_NAME_RE = /^[0-9a-f]{16}$/;
const RUNTIME_PRUNE_GRACE_MS = 6 * 60 * 60 * 1000;

function pruneStaleRuntimes(currentDir) {
  const baseDir = path.dirname(currentDir);
  let entries;
  try {
    entries = fs.readdirSync(baseDir, { withFileTypes: true });
  } catch {
    return;
  }

  const now = Date.now();
  let removed = 0;
  for (const entry of entries) {
    if (!entry.isDirectory() || !RUNTIME_NAME_RE.test(entry.name)) continue;
    if (entry.name === path.basename(currentDir)) continue;
    const staleDir = path.join(baseDir, entry.name);
    // An older build may still be open in another window and dot-sources files
    // from its own folder on demand, so leave anything touched recently alone and
    // never fail the launch over a folder that refuses to go away.
    try {
      if (now - fs.statSync(staleDir).mtimeMs < RUNTIME_PRUNE_GRACE_MS) continue;
      fs.rmSync(staleDir, { recursive: true, force: true, maxRetries: 2, retryDelay: 50 });
      removed += 1;
    } catch {}
  }
  if (removed > 0) {
    console.log(`[sea] pruned ${removed} stale runtime folder(s)`);
  }
}

function extractRuntime() {
  const dir = runtimeDir();
  ensureDir(dir);
  for (const name of ASSET_NAMES) {
    writeAssetIfChanged(path.join(dir, name), getAssetBuffer(name));
  }
  pruneStaleRuntimes(dir);
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

// ReasoningProxy.exe --uninstall stops the app's own processes and deletes the
// folders it created. VS Code's chatLanguageModels.json is deliberately kept:
// it can hold providers this tool never touched, so reverting it is a human call.
function stopRelatedProcesses(patterns, selfPid) {
  const command = [
    "$pats = @()",
    "foreach ($p in ($env:RP_UNINSTALL_PATTERNS -split '[\\r\\n]+')) { if ($p) { $pats += [regex]::Escape($p) } }",
    "if ($pats.Count -eq 0) { exit 0 }",
    "$re = $pats -join '|'",
    "$self = [int]$env:RP_UNINSTALL_SELF_PID",
    // A plain foreach shares scope with its caller, while ForEach-Object would trap
    // the counter inside its scriptblock and the report would claim zero stops.
    "$victims = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {",
    "  ($_.ProcessId -ne $self) -and (('{0} {1}' -f $_.ExecutablePath, $_.CommandLine) -match $re)",
    "})",
    "$killed = 0",
    "foreach ($target in $victims) {",
    "  try { Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop; $killed += 1 } catch {}",
    "}",
    "Write-Output \"[uninstall] stopped $killed related process(es)\"",
  ].join("\n");
  const encoded = Buffer.from(command, "utf16le").toString("base64");
  const result = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
    {
      windowsHide: true,
      encoding: "utf8",
      env: {
        ...process.env,
        RP_UNINSTALL_PATTERNS: patterns.join("\n"),
        RP_UNINSTALL_SELF_PID: String(selfPid),
      },
    }
  );
  if (result.stdout) process.stdout.write(result.stdout);
}

function removeTree(dir, removed, problems) {
  try {
    fs.rmSync(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
    removed.push(dir);
  } catch (err) {
    problems.push(`${dir} (${err.message})`);
  }
}

// A folder next to the exe only counts as ours when it carries something this app
// demonstrably wrote, so an unrelated "logs" or "config" directory survives.
const OWN_LOG_NAMES = ["proxy.log", "proxy.err.log", "lm-sync.log"];

function ownsLogsDir(dir) {
  try {
    const names = new Set(fs.readdirSync(dir));
    return OWN_LOG_NAMES.some((name) => names.has(name));
  } catch {
    return false;
  }
}

function ownsConfigDir(dir) {
  try {
    return /LM_PROVIDER_NAME|REASONING_PROXY/.test(
      fs.readFileSync(path.join(dir, "config.bat"), "latin1")
    );
  } catch {
    return false;
  }
}

function reportEditorModels() {
  const appData = process.env.APPDATA;
  if (!appData) return;
  const userDir = path.join(appData, "Code", "User");
  const target = path.join(userDir, "chatLanguageModels.json");
  if (!fs.existsSync(target)) {
    console.log("[uninstall] no VS Code chatLanguageModels.json to keep");
    return;
  }
  console.log(`[uninstall] kept ${target} (it may hold providers you added by hand)`);
  let newest = "";
  try {
    const backups = fs
      .readdirSync(userDir)
      .filter((name) => /^chatLanguageModels\.json\.bak-\d{8}-\d{6}$/.test(name))
      .sort();
    if (backups.length > 0) newest = backups[backups.length - 1];
  } catch {}
  if (newest) {
    console.log(`[uninstall] newest backup: ${path.join(userDir, newest)}`);
  }
}

function uninstall(exeDir) {
  const baseDir = path.join(appDataDir(), "ReasoningProxy");
  // Match on the folder we are deleting and on this exe, so a proxy started from
  // a source checkout is left running. The current process is excluded by pid.
  stopRelatedProcesses([baseDir, process.execPath], process.pid);

  const removed = [];
  const problems = [];
  removeTree(baseDir, removed, problems);

  // A portable layout keeps settings and logs next to the exe.
  const logsDir = path.join(exeDir, "logs");
  if (ownsLogsDir(logsDir)) removeTree(logsDir, removed, problems);
  const configDir = path.join(exeDir, "config");
  if (ownsConfigDir(configDir)) removeTree(configDir, removed, problems);

  for (const dir of removed) console.log(`[uninstall] removed ${dir}`);
  for (const problem of problems) console.log(`[uninstall] could not remove ${problem}`);
  reportEditorModels();
  console.log(`[uninstall] delete ${process.execPath} to finish`);
}

function main() {
  const exeDir = path.dirname(process.execPath);

  if (!sea.isSea()) {
    console.error("[sea] run this file from the packaged ReasoningProxy.exe");
    process.exitCode = 1;
    return;
  }

  const args = process.argv.slice(2);

  // Handle this before extracting anything: an uninstall should not recreate the
  // runtime folders it is about to delete.
  if (args.includes("--uninstall")) {
    uninstall(exeDir);
    return;
  }

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
