const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const os = require("node:os");
const { spawn, spawnSync } = require("node:child_process");
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

// An empty file that says "this logs folder was created by ReasoningProxy". The
// log names alone are not enough: opening the GUI and never starting the proxy
// leaves the folder there with nothing in it, and uninstall would then have no way
// to tell it apart from an unrelated folder that happens to be called "logs".
const LOG_OWNER_NAME = ".reasoning-proxy";

function ensureLogsDir(dir) {
  ensureDir(dir);
  try {
    fs.writeFileSync(path.join(dir, LOG_OWNER_NAME), "", { flag: "a" });
  } catch {}
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
  ensureLogsDir(logsDir);

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

// autoStart is the sign-in case: the GUI is told to bring the proxy up as well, so the
// window the user lands on already reads running instead of waiting for a click.
function startGui(runtime, dataDir, autoStart) {
  const scriptPath = path.join(runtime, "scripts", "proxy-gui.ps1");

  const psQuote = (value) => `'${String(value).replace(/'/g, "''")}'`;
  const command = [
    `$ErrorActionPreference = 'Stop'`,
    `$env:REASONING_PROXY_DIR = ${psQuote(dataDir)}`,
    `$env:REASONING_PROXY_RUNTIME_DIR = ${psQuote(runtime)}`,
    `$env:REASONING_PROXY_EXE = ${psQuote(process.execPath)}`,
    ...(autoStart ? [`$env:REASONING_PROXY_AUTOSTART = '1'`] : []),
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

// Releases 1.2.3 and 1.2.4 generated an uninstall.bat next to the portable exe. It has
// been dropped again: Settings > Apps runs the very same command, so the script only
// added a file to explain. A copy left behind by those releases goes away on the next
// start, and the marker line is what makes that safe. Somebody else's script that
// happens to be called uninstall.bat is never touched, by the start or by the uninstall.
const UNINSTALL_BAT_NAME = "uninstall.bat";
const UNINSTALL_BAT_MARKER = /^rem ReasoningProxy uninstaller/mi;

function isOurUninstallBat(filePath) {
  try {
    return UNINSTALL_BAT_MARKER.test(fs.readFileSync(filePath, "latin1"));
  } catch {
    return false;
  }
}

function removeGeneratedUninstallBat(exeDir) {
  const target = path.join(exeDir, UNINSTALL_BAT_NAME);
  if (!isOurUninstallBat(target)) return;
  try {
    // Fails while the script is the one running this uninstall, which is fine: it
    // removes itself as its last line.
    fs.rmSync(target, { force: true });
    console.log(`[sea] removed the ${UNINSTALL_BAT_NAME} left behind by an older release`);
  } catch {}
}

// A portable exe has no installer, so Windows has nothing to list under
// Settings > Apps. The first run writes the key itself and --uninstall takes it
// away, which is what gives the user a visible uninstall button instead of having
// to know the flag exists.
// Every value stays ASCII on purpose: reg.exe prints what it wrote in the active
// console codepage, so a Chinese name would come back garbled and force a rewrite
// on every start.
const ARP_KEY =
  "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\ReasoningProxy";
const ARP_DWORDS = new Set(["EstimatedSize", "NoModify", "NoRepair"]);

function appVersion() {
  try {
    // The build adds a "version" asset; source runs and older blobs have none.
    const text = getAssetBuffer("version").toString("utf8").trim();
    return text || "0.0.0";
  } catch {
    return "0.0.0";
  }
}

function reg(args) {
  return spawnSync("reg.exe", args, { windowsHide: true, encoding: "utf8" });
}

function installedEntries() {
  const result = reg(["query", ARP_KEY]);
  if (result.status !== 0) return {};
  return parseRegValues(result.stdout);
}

// reg.exe prints one indented line per value, DWORDs in hex. The hex to decimal
// step matters: the code compares what it wrote against what a query reads back.
function parseRegValues(text) {
  const values = {};
  for (const line of String(text).split(/\r?\n/)) {
    const match = /^\s+(\S+)\s+REG_(SZ|EXPAND_SZ|DWORD)\s+(.*?)\s*$/.exec(line);
    if (!match) continue;
    values[match[1]] =
      match[2] === "DWORD" ? String(parseInt(match[3], 16)) : match[3];
  }
  return values;
}

function regFailure(result) {
  return (
    String(result.stderr || result.stdout || "").trim() ||
    `reg.exe exit ${result.status}`
  );
}

function wantedEntries(exeDir) {
  // --purge so that the button in Settings removes the program too, not just the
  // files it wrote. The exe cannot delete itself while it is running, which is what
  // scheduleExeRemoval below is for.
  const uninstall = `"${process.execPath}" --uninstall --purge`;
  const entries = {
    DisplayName: "Reasoning Proxy",
    DisplayVersion: appVersion(),
    Publisher: "Snowy-Morning",
    InstallLocation: exeDir,
    DisplayIcon: process.execPath,
    UninstallString: uninstall,
    QuietUninstallString: uninstall,
    NoModify: "1",
    NoRepair: "1",
  };
  try {
    // Settings expects kilobytes, not bytes.
    entries.EstimatedSize = String(
      Math.max(1, Math.round(fs.statSync(process.execPath).size / 1024))
    );
  } catch {}
  return entries;
}

function registerAddRemovePrograms(exeDir) {
  const wanted = wantedEntries(exeDir);
  const current = installedEntries();
  const changed = Object.keys(wanted).filter((name) => current[name] !== wanted[name]);
  for (const name of changed) {
    const type = ARP_DWORDS.has(name) ? "REG_DWORD" : "REG_SZ";
    const result = reg(["add", ARP_KEY, "/v", name, "/t", type, "/d", wanted[name], "/f"]);
    if (result.status !== 0) {
      // Saying nothing here is how a missing entry becomes undiagnosable: the app
      // runs fine, only the uninstall button is gone.
      console.log(`[sea] could not register in Settings > Apps (${name}: ${regFailure(result)})`);
      return;
    }
  }
  if (changed.length > 0) {
    console.log(`[sea] listed in Settings > Apps (${changed.length} value(s) written)`);
  }
}

function unregisterAddRemovePrograms() {
  if (reg(["query", ARP_KEY]).status !== 0) return "none";
  return reg(["delete", ARP_KEY, "/f"]).status === 0 ? "removed" : "failed";
}

// Start at sign-in. HKCU\...\Run is the only place a portable exe can put itself
// without admin rights, and Windows hands whatever it finds straight to
// CreateProcess, so the value cannot name ReasoningProxy.exe: that is a console
// program and every login would flash a black window. The value names a generated
// VBS instead, and wscript starts the app with no console of its own, which is the
// same trick scripts/gui.vbs uses for the GUI. What does show up is the app window,
// because signing in is meant to hand back a running proxy, not a button to press.
// The script sits at a fixed path under %LOCALAPPDATA% rather than next to the exe,
// because the exe is the thing users move around. Only the script body holds the exe
// path, so a launch after a move rewrites the body and the key never has to change.
const RUN_KEY = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const RUN_VALUE = "ReasoningProxy";
const AUTOSTART_SCRIPT_NAME = "autostart.vbs";

function autostartScriptPath() {
  return path.join(appDataDir(), "ReasoningProxy", AUTOSTART_SCRIPT_NAME);
}

function vbsQuote(value) {
  return `"${String(value).replace(/"/g, '""')}"`;
}

function autostartCommand(scriptPath) {
  return `wscript.exe //B //Nologo ${vbsQuote(scriptPath)}`;
}

// --login, not --proxy: the sign-in should leave the user with the window and the
// tray icon as well, so the proxy can be looked at and stopped from there.
function autostartScriptText(exePath) {
  const launch = `${vbsQuote(exePath)} --login`;
  return [
    "' Generated by ReasoningProxy.exe. Do not edit: it is rewritten on every start.",
    "Set shell = CreateObject(\"WScript.Shell\")",
    `command = ${vbsQuote(launch)}`,
    "shell.Run command, 0, False",
    "",
  ].join("\r\n");
}

function writeAutostartScript(exePath) {
  const scriptPath = autostartScriptPath();
  writeAssetIfChanged(scriptPath, Buffer.from(autostartScriptText(exePath), "utf8"));
  return scriptPath;
}

function runValue() {
  const result = reg(["query", RUN_KEY, "/v", RUN_VALUE]);
  if (result.status !== 0) return "";
  return parseRegValues(result.stdout)[RUN_VALUE] || "";
}

// Three states, because a value name is not proof of ownership. "foreign" means
// something else answers to ReasoningProxy in the Run key: not ours to heal, and not
// ours to delete. Anything that names our own script stays "on" even when the script
// has since been deleted by hand, because that is the setting the user left and the
// next launch puts the file back.
function autostartState() {
  const data = runValue();
  if (!data) return { state: "off", data };
  const lower = data.toLowerCase();
  const ours =
    lower.includes(autostartScriptPath().toLowerCase()) ||
    lower === autostartCommand(autostartScriptPath()).toLowerCase();
  return { state: ours ? "on" : "foreign", data };
}

function enableAutostart() {
  let scriptPath;
  try {
    scriptPath = writeAutostartScript(process.execPath);
  } catch (err) {
    return { ok: false, detail: `could not write ${AUTOSTART_SCRIPT_NAME}: ${err.message}` };
  }
  const current = autostartState();
  const result = reg([
    "add",
    RUN_KEY,
    "/v",
    RUN_VALUE,
    "/t",
    "REG_SZ",
    "/d",
    autostartCommand(scriptPath),
    "/f",
  ]);
  if (result.status !== 0) return { ok: false, detail: regFailure(result) };
  return {
    ok: true,
    command: autostartCommand(scriptPath),
    replaced: current.state === "foreign" ? current.data : "",
  };
}

function disableAutostart() {
  // The script lives inside the folder --uninstall deletes, but --keep-backups leaves
  // that folder root alone, so it is also taken out by name here.
  try {
    fs.rmSync(autostartScriptPath(), { force: true });
  } catch {}
  const current = autostartState();
  if (current.state !== "on") {
    // Already off, or a value that is not ours to take away.
    return { ok: true, removed: false, state: current.state, data: current.data };
  }
  const result = reg(["delete", RUN_KEY, "/v", RUN_VALUE, "/f"]);
  if (result.status !== 0) {
    return { ok: false, removed: false, detail: regFailure(result) };
  }
  return { ok: true, removed: true, state: "off" };
}

// A sign-in that starts nothing because the script went missing is the failure nobody
// sees, so the entry heals itself on launch. An app that was never enabled stays
// untouched: no file written, no key read beyond this query.
function refreshAutostartScript() {
  if (autostartState().state !== "on") return;
  try {
    writeAutostartScript(process.execPath);
  } catch {}
}

// --autostart is answered by the exe so the GUI does not have to know the registry
// layout; status= is the part it parses, the rest is for a person at a console.
function autostartRequest(args) {
  let asked = false;
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    let value = "";
    if (arg === "--autostart") {
      asked = true;
      value = args[i + 1] || "";
    } else if (arg.startsWith("--autostart=")) {
      asked = true;
      value = arg.slice("--autostart=".length);
    }
    if (value === "enable" || value === "on") return "enable";
    if (value === "disable" || value === "off") return "disable";
    if (value === "status") return "status";
  }
  return asked ? "usage" : "";
}

function reportAutostart(request) {
  if (request === "usage") {
    console.log("[autostart] usage: --autostart enable|disable|status");
    process.exitCode = 1;
    return;
  }
  if (request === "status") {
    const current = autostartState();
    if (current.state === "foreign") {
      // Naming what is in there is what lets a person tell "not enabled" apart from
      // "somebody else already owns that name".
      console.log(`[autostart] ${RUN_VALUE} is in use by another program: ${current.data}`);
    }
    console.log(`[autostart] status=${current.state === "on" ? "on" : "off"}`);
    return;
  }
  if (request === "enable") {
    const result = enableAutostart();
    if (!result.ok) {
      console.log(`[autostart] could not be enabled: ${result.detail}`);
      console.log("[autostart] status=off");
      process.exitCode = 1;
      return;
    }
    if (result.replaced) {
      console.log(`[autostart] replaced another program's entry: ${result.replaced}`);
    }
    console.log(`[autostart] enabled: ${result.command}`);
    console.log("[autostart] status=on");
    return;
  }
  const result = disableAutostart();
  if (!result.ok) {
    console.log(`[autostart] could not be disabled: ${result.detail}`);
    console.log("[autostart] status=on");
    process.exitCode = 1;
    return;
  }
  console.log(
    result.removed
      ? "[autostart] disabled"
      : result.state === "foreign"
        ? `[autostart] left the entry alone, ${RUN_VALUE} there is not ours`
        : "[autostart] was already off"
  );
  console.log("[autostart] status=off");
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
const OWN_LOG_NAMES = [LOG_OWNER_NAME, "proxy.log", "proxy.err.log", "lm-sync.log"];

function ownsLogsDir(dir, installDirConfirmed) {
  try {
    const names = new Set(fs.readdirSync(dir));
    if (OWN_LOG_NAMES.some((name) => names.has(name))) return true;
    // Builds before the marker file could leave an empty logs folder behind when the
    // GUI was opened but the proxy never started. With our own config.bat next to it
    // the folder is provably part of this install, and an empty directory is not
    // worth keeping; without that evidence it stays exactly as it is.
    return installDirConfirmed === true && names.size === 0;
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

// Backups sit in one folder per synced target, named <file>.bak-<yyyymmdd>-<hhmmss>.
// The name is the clock: mtime cannot be trusted because the copy inherits the
// mtime of the version being backed up.
const BACKUP_STAMP_RE = /\.bak-(\d{8}-\d{6})$/;

function newestBackupFile(root) {
  let groups;
  try {
    groups = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return "";
  }
  let newest = "";
  let newestStamp = "";
  for (const group of groups) {
    if (!group.isDirectory()) continue;
    let names;
    try {
      names = fs.readdirSync(path.join(root, group.name));
    } catch {
      continue;
    }
    for (const name of names) {
      const match = BACKUP_STAMP_RE.exec(name);
      if (match && match[1] > newestStamp) {
        newestStamp = match[1];
        newest = path.join(root, group.name, name);
      }
    }
  }
  return newest;
}

function reportLeftovers(backupsDir, newest, keepBackups, customDir) {
  const appData = process.env.APPDATA;
  const target = appData
    ? path.join(appData, "Code", "User", "chatLanguageModels.json")
    : "";
  if (target && !fs.existsSync(target)) {
    console.log("[uninstall] no VS Code chatLanguageModels.json to keep");
  } else if (target) {
    console.log(`[uninstall] kept ${target} (it may hold providers you added by hand)`);
  }
  if (keepBackups) {
    console.log(`[uninstall] kept backups under ${backupsDir}`);
    if (newest) console.log(`[uninstall] newest backup: ${newest}`);
  } else if (newest) {
    console.log(`[uninstall] removed the backups, newest was ${newest}`);
  }
  if (customDir) {
    console.log(`[uninstall] LM_BACKUP_DIR is ${customDir}, remove it by hand if you want it gone`);
  }
}

// Read a `set KEY=value` line out of config.bat, expanding %VARS% the way cmd
// would. LM_BACKUP_DIR can point outside the tree we remove, and uninstall never
// chases it: deleting a path somebody typed by hand is a bigger risk than leaving
// a clearly named folder behind, so that one is only reported.
function configuredSetting(configDirs, key) {
  for (const dir of configDirs) {
    let text;
    try {
      text = fs.readFileSync(path.join(dir, "config.bat"), "latin1");
    } catch {
      continue;
    }
    const match = new RegExp("^[ \\t]*set[ \\t]+" + key + "=(.*)$", "im").exec(text);
    if (!match) continue;
    const value = match[1].replace(/["']/g, "").trim();
    if (!value) return "";
    return value.replace(/%([^%]+)%/g, (all, name) => process.env[name] || all);
  }
  return "";
}

// Mirrors Select-LmTargetPaths in language-models.ps1: one file, and an explicit
// LM_CONFIG_PATH wins over the default VS Code location.
function editorTargetPath(configDirs) {
  const configured = configuredSetting(configDirs, "LM_CONFIG_PATH");
  if (configured) return path.resolve(configured);
  const appData = process.env.APPDATA;
  if (!appData) return "";
  return path.join(appData, "Code", "User", "chatLanguageModels.json");
}

// Backups written next to the editor's own file by builds from before the move.
// Reaching into that folder is normally off limits, so the reach is narrowed to
// this exact file name plus the exact stamp format: nothing else in there can be
// matched, and the live chatLanguageModels.json is never a candidate.
function listStrayBackups(targetPath) {
  const dir = path.dirname(targetPath);
  const prefix = path.basename(targetPath) + ".bak-";
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }
  return names
    .filter((name) => name.startsWith(prefix) && BACKUP_STAMP_RE.test(name))
    .map((name) => path.join(dir, name));
}

function sweepStrayBackups(targetPath) {
  let removed = 0;
  const problems = [];
  for (const file of listStrayBackups(targetPath)) {
    try {
      fs.rmSync(file, { force: true, maxRetries: 2, retryDelay: 50 });
      removed += 1;
    } catch (err) {
      problems.push(`${file} (${err.message})`);
    }
  }
  return { removed, problems };
}

function isInside(child, parent) {
  const a = path.resolve(child).toLowerCase();
  const b = path.resolve(parent).toLowerCase();
  return a === b || a.startsWith(b + path.sep);
}

// Windows keeps the image of a running exe locked, so this process cannot delete the
// file that is running it. The last step goes to a helper written in %TEMP% and
// launched detached, which waits for this process to disappear and then removes the
// exe, and the folder behind it only if it is empty by then.
//
// The helper is VBScript, not a batch file, because of how it has to wait. A detached
// process gets no console, and a batch file's only sleep is ping.exe: every call would
// be handed a brand new terminal window, so an uninstall that had to retry showed the
// user a stack of windows titled "ping -n 2 127.0.0.1". WScript.Sleep is built into the
// script host, and wscript.exe is a windowless host to begin with. The app already ships
// gui.vbs, so this adds no new dependency; where wscript is missing the uninstall says so
// instead of pretending the exe is on its way out.
//
// DeleteFolder is never used on a folder that still has anything in it. Its second
// argument is force, not recursion, and the method deletes contents along with the
// folder, so emptiness is counted here first and the folder is only dropped once it is
// truly down to nothing.
//
// Paths travel through the environment rather than the script text, so nothing here has
// to survive another layer of quoting.
function purgeScriptText() {
  return (
    [
      "' ReasoningProxy purge helper, written by ReasoningProxy.exe",
      "Dim shell, fso, env, exe, dir, i, target",
      'Set shell = CreateObject("WScript.Shell")',
      'Set fso = CreateObject("Scripting.FileSystemObject")',
      'Set env = shell.Environment("PROCESS")',
      "exe = env(\"RP_PURGE_EXE\")",
      "dir = env(\"RP_PURGE_DIR\")",
      "",
      "If exe <> \"\" Then",
      "  For i = 1 To 240",
      "    WScript.Sleep 250",
      "    On Error Resume Next",
      "    Err.Clear",
      "    fso.DeleteFile exe, True",
      "    If Err.Number = 0 Then Exit For",
      "    On Error GoTo 0",
      "  Next",
      "End If",
      "",
      "' The folder goes only when it holds nothing of anybody else's. It may still be",
      "' holding the uninstall script that launched this run, so this is retried.",
      "If dir <> \"\" Then",
      "  For i = 1 To 40",
      "    If Not fso.FolderExists(dir) Then Exit For",
      "    Set target = fso.GetFolder(dir)",
      "    If target.Files.Count = 0 And target.SubFolders.Count = 0 Then",
      "      On Error Resume Next",
      "      Err.Clear",
      "      fso.DeleteFolder dir, True",
      "      If Err.Number = 0 Then Exit For",
      "      On Error GoTo 0",
      "    End If",
      "    WScript.Sleep 250",
      "  Next",
      "End If",
      "",
      "On Error Resume Next",
      "fso.DeleteFile WScript.ScriptFullName, True",
      "",
    ].join("\r\n")
  );
}

function scheduleExeRemoval(exeDir) {
  const systemRoot = process.env.SystemRoot || "C:\\Windows";
  if (!fs.existsSync(path.join(systemRoot, "System32", "wscript.exe"))) {
    console.log("[uninstall] wscript.exe is not available, so the exe stays");
    console.log(`[uninstall] delete ${process.execPath} by hand to finish`);
    return;
  }
  const helper = path.join(
    os.tmpdir(),
    `reasoning-proxy-purge-${process.pid}-${crypto.randomBytes(4).toString("hex")}.vbs`
  );
  try {
    fs.writeFileSync(helper, purgeScriptText());
  } catch (err) {
    console.log(`[uninstall] could not write the removal helper: ${err.message}`);
    console.log(`[uninstall] delete ${process.execPath} by hand to finish`);
    return;
  }
  try {
    const child = spawn("wscript.exe", ["//B", "//Nologo", helper], {
      detached: true,
      stdio: "ignore",
      windowsHide: true,
      env: {
        ...process.env,
        RP_PURGE_EXE: process.execPath,
        RP_PURGE_DIR: exeDir,
      },
    });
    // Without a listener a spawn failure would surface as an unhandled error event
    // and crash the run that is already reporting success.
    child.on("error", () => {});
    child.unref();
  } catch (err) {
    console.log(`[uninstall] could not start the removal helper: ${err.message}`);
    console.log(`[uninstall] delete ${process.execPath} by hand to finish`);
  }
}

// Mirrors Resolve-LmBackupDir in language-models.ps1: backups live inside the
// same folder --uninstall removes, so nothing of ours can survive it.
function uninstall(exeDir, keepBackups, purge) {
  const baseDir = path.join(appDataDir(), "ReasoningProxy");
  const backupsDir = path.join(baseDir, "backups");
  // Read the settings before any of these folders are deleted.
  const configDirs = [
    path.join(exeDir, "config"),
    path.join(baseDir, "data", "config"),
  ];
  const custom = configuredSetting(configDirs, "LM_BACKUP_DIR");
  const customBackupDir = custom && !isInside(custom, baseDir) ? custom : "";
  const editorTarget = editorTargetPath(configDirs);
  // Read the ledger before deleting: once the folder is gone the newest backup can
  // only be named, never offered back.
  const newest = newestBackupFile(backupsDir);

  // Match on the folder we are deleting and on this exe, so a proxy started from
  // a source checkout is left running. The current process is excluded by pid.
  stopRelatedProcesses([baseDir, process.execPath], process.pid);

  // Drop the Settings > Apps entry before the files it points at disappear.
  const arp = unregisterAddRemovePrograms();
  // Same for the sign-in entry: leaving it behind would make every later login run a
  // script that no longer exists.
  const autostart = disableAutostart();

  const removed = [];
  const problems = [];
  if (keepBackups) {
    for (const name of ["runtime", "data"]) {
      const dir = path.join(baseDir, name);
      if (fs.existsSync(dir)) removeTree(dir, removed, problems);
    }
  } else {
    removeTree(baseDir, removed, problems);
  }

  // A portable layout keeps settings and logs next to the exe.
  const configDir = path.join(exeDir, "config");
  const portableInstall = ownsConfigDir(configDir);
  const logsDir = path.join(exeDir, "logs");
  if (ownsLogsDir(logsDir, portableInstall)) removeTree(logsDir, removed, problems);
  if (portableInstall) removeTree(configDir, removed, problems);

  // The generated uninstaller goes with the rest, unless it is the script running
  // this very process: taking the file away from cmd mid-run makes it complain about
  // a missing batch file instead of reaching its own pause and self delete. The script
  // names itself in RP_UNINSTALL_SCRIPT and removes itself as its last line.
  // A leftover uninstall.bat from 1.2.3 or 1.2.4 goes with the rest of it.
  const batPath = path.join(exeDir, UNINSTALL_BAT_NAME);
  let scriptRemovesItself = false;
  if (isOurUninstallBat(batPath)) {
    const running = (process.env.RP_UNINSTALL_SCRIPT || "").trim();
    scriptRemovesItself =
      running.toLowerCase() === path.resolve(batPath).toLowerCase();
    if (!scriptRemovesItself) {
      fs.rmSync(batPath, { force: true, maxRetries: 2, retryDelay: 50 });
      removed.push(batPath);
    }
  }

  let strays = { removed: 0, problems: [] };
  if (editorTarget && !keepBackups) {
    strays = sweepStrayBackups(editorTarget);
    problems.push(...strays.problems);
  }

  for (const dir of removed) console.log(`[uninstall] removed ${dir}`);
  for (const problem of problems) console.log(`[uninstall] could not remove ${problem}`);
  if (scriptRemovesItself) {
    console.log(`[uninstall] ${UNINSTALL_BAT_NAME} deletes itself, it is still running`);
  }
  if (strays.removed > 0) {
    console.log(`[uninstall] removed ${strays.removed} stray backup(s) next to ${editorTarget}`);
  }
  if (keepBackups && editorTarget) {
    const left = listStrayBackups(editorTarget).length;
    if (left > 0) console.log(`[uninstall] kept ${left} stray backup(s) next to ${editorTarget}`);
  }
  if (arp === "removed") console.log("[uninstall] removed the Settings > Apps entry");
  if (arp === "failed") console.log("[uninstall] could not remove the Settings > Apps entry");
  if (autostart.removed) console.log("[uninstall] removed the sign-in autostart entry");
  if (!autostart.ok) {
    console.log(`[uninstall] could not remove the autostart entry: ${autostart.detail}`);
  }
  if (autostart.state === "foreign") {
    console.log(
      `[uninstall] left the Run key alone, its ${RUN_VALUE} value is not ours: ${autostart.data}`
    );
  }
  reportLeftovers(backupsDir, newest, keepBackups, customBackupDir);
  if (purge) {
    scheduleExeRemoval(exeDir);
    console.log(`[uninstall] ${process.execPath} goes once this process exits`);
  } else {
    console.log(
      `[uninstall] kept ${process.execPath}, add --purge to remove it as well`
    );
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

  // Handle this before extracting anything: an uninstall should not recreate the
  // runtime folders it is about to delete.
  if (args.includes("--uninstall")) {
    uninstall(exeDir, args.includes("--keep-backups"), args.includes("--purge"));
    return;
  }

  // Also answered before the runtime is extracted: neither of these needs it, and an
  // autostart toggle should not leave runtime folders behind on a machine where the
  // app was never opened.
  const autostart = autostartRequest(args);
  if (autostart) {
    reportAutostart(autostart);
    return;
  }

  const proxyMode = args.includes("--proxy");
  // --login is what the generated sign-in script runs: the GUI, and the GUI starts the
  // proxy too. It is a separate flag rather than plain GUI mode because double clicking
  // the exe should stay a look-at-the-status thing, not a start-the-proxy thing.
  const loginMode = args.includes("--login");
  const runtime = process.env.REASONING_PROXY_RUNTIME_DIR || extractRuntime();
  // The GUI and start.bat always pass REASONING_PROXY_DIR, so this path is the one a
  // bare `ReasoningProxy.exe --proxy` or `--login` takes. chooseDataDir keeps both
  // working when the exe sits in a read-only folder.
  const dataDir = process.env.REASONING_PROXY_DIR || chooseDataDir(exeDir);

  ensureDefaultData(runtime, dataDir);
  // Cleanup of a file this app stopped generating, so it has to happen wherever the
  // exe lives, not only in the portable layout.
  removeGeneratedUninstallBat(exeDir);
  refreshAutostartScript();

  if (dataDir === exeDir) {
    // The portable layout keeps the exe where the user put it, which is the path
    // Windows should offer to uninstall. A redirected data dir says nothing about
    // where the exe lives, so only the portable case registers.
    try {
      registerAddRemovePrograms(exeDir);
    } catch (err) {
      console.log(`[sea] could not register in Settings > Apps: ${err.message}`);
    }
  }

  if (proxyMode) {
    runProxy(runtime, dataDir);
    return;
  }

  startGui(runtime, dataDir, loginMode);
}

try {
  main();
} catch (err) {
  console.error(err);
  process.exit(1);
}
