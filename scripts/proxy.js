const http = require("http");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const ROOT_DIR = process.env.REASONING_PROXY_DIR || path.join(__dirname, "..");
const CONFIG_PATH = path.join(ROOT_DIR, "config", "config.bat");

function readConfigValue(name, fallback) {
  try {
    const content = fs.readFileSync(CONFIG_PATH, "utf8");
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const match = content.match(new RegExp(`^\\s*set\\s+${escaped}\\s*=\\s*(.*?)\\s*$`, "m"));
    if (match && match[1].trim()) {
      return match[1].trim();
    }
  } catch {}
  return fallback;
}

const PROXY_PORT = Number(readConfigValue("PROXY_PORT", process.env.PROXY_PORT || 3120));
const TARGET_HOST = readConfigValue("TARGET_HOST", process.env.TARGET_HOST || "10.0.8.19");
const TARGET_PORT = readConfigValue("TARGET_PORT", process.env.TARGET_PORT || "80");
const KIMI_TEMPERATURE = Number(readConfigValue("KIMI_TEMPERATURE", process.env.KIMI_TEMPERATURE || 1));
const KIMI_TOP_P = Number(readConfigValue("KIMI_TOP_P", process.env.KIMI_TOP_P || 0.95));
const LM_API_KEY = readConfigValue("LM_API_KEY", process.env.LM_API_KEY || "");

// Loopback-only helpers the GUI can call without learning about the upstream.
const INTERNAL_PREFIX = "/__reasoning_proxy/";
const MODELS_FETCH_TIMEOUT_MS = 15000;

// The Authorization header most recently forwarded upstream. Reusing it lets the
// GUI list upstream models without the key ever being typed in or written to disk.
let lastAuthorization = "";

function getAuthSource() {
  if (lastAuthorization) return "captured";
  if (LM_API_KEY) return "config";
  return "none";
}

function pickModelIds(payload) {
  const source = Array.isArray(payload)
    ? payload
    : payload && (payload.data || payload.models || payload.models?.data);
  if (!Array.isArray(source)) return null;
  const ids = [];
  for (const item of source) {
    const id = typeof item === "string" ? item : item && item.id;
    if (typeof id === "string" && id.trim()) ids.push(id.trim());
  }
  return ids;
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
    "cache-control": "no-store",
  });
  res.end(payload);
}

function proxyModelsRequest(res) {
  const auth = lastAuthorization || LM_API_KEY;
  const authSource = getAuthSource();
  const headers = {
    host: `${TARGET_HOST}:${TARGET_PORT}`,
    accept: "application/json",
  };
  if (auth) headers.authorization = auth;

  const upstream = http.request(
    {
      host: TARGET_HOST,
      port: TARGET_PORT,
      path: "/v1/models",
      method: "GET",
      headers,
    },
    (upstreamRes) => {
      const chunks = [];
      let bytes = 0;
      upstreamRes.on("data", (chunk) => {
        if (bytes < 2 * 1024 * 1024) {
          chunks.push(chunk);
          bytes += chunk.length;
        }
      });
      upstreamRes.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        const status = upstreamRes.statusCode || 0;
        let payload = null;
        try {
          payload = JSON.parse(text);
        } catch {}
        const ids = pickModelIds(payload);
        if (status >= 200 && status < 300 && ids) {
          console.log(`[proxy] models list: ${ids.length} model(s) from upstream, auth=${authSource}`);
          sendJson(res, 200, {
            ok: true,
            models: ids,
            count: ids.length,
            authSource,
            upstreamStatus: status,
          });
          return;
        }
        console.warn(
          `[proxy] models list failed: status=${status} auth=${authSource} body=${text.slice(0, 240)}`
        );
        sendJson(res, status >= 400 ? status : 502, {
          ok: false,
          error:
            status === 401 || status === 403
              ? "upstream rejected the model list request"
              : "upstream did not return a model list",
          authSource,
          upstreamStatus: status,
          body: text.slice(0, 500),
        });
      });
    }
  );

  upstream.setTimeout(MODELS_FETCH_TIMEOUT_MS, () => {
    upstream.destroy(new Error(`timed out after ${MODELS_FETCH_TIMEOUT_MS}ms`));
  });
  upstream.on("error", (err) => {
    console.error(`[proxy] models list error: ${err.message}`);
    if (!res.headersSent) {
      sendJson(res, 502, {
        ok: false,
        error: `could not reach ${TARGET_HOST}:${TARGET_PORT}: ${err.message}`,
        authSource,
      });
    }
  });
  upstream.end();
}

function handleInternalRequest(req, res) {
  const route = String(req.url || "").split("?")[0];
  if (req.method !== "GET") {
    sendJson(res, 405, { ok: false, error: "method not allowed" });
    return;
  }
  if (route === `${INTERNAL_PREFIX}models`) {
    proxyModelsRequest(res);
    return;
  }
  if (route === `${INTERNAL_PREFIX}status`) {
    sendJson(res, 200, {
      ok: true,
      listening: PROXY_PORT,
      target: `${TARGET_HOST}:${TARGET_PORT}`,
      reasoningEffort: readReasoningEffort(),
      authSource: getAuthSource(),
    });
    return;
  }
  sendJson(res, 404, { ok: false, error: `unknown route ${route}` });
}

function readReasoningEffort() {
  return readConfigValue("REASONING_EFFORT", process.env.REASONING_EFFORT || "high");
}

function formatLogArg(arg) {
  if (typeof arg === "string") return arg;
  if (arg instanceof Error) return arg.stack || `${arg.name}: ${arg.message}`;
  try {
    return JSON.stringify(arg);
  } catch {
    return String(arg);
  }
}

function appendLogFile(filePath, args) {
  try {
    const line = args.map(formatLogArg).join(" ") + "\n";
    fs.appendFileSync(filePath, line, "utf8");
  } catch {}
}

function enableFileLogging() {
  const logsDir = path.join(ROOT_DIR, "logs");
  try {
    fs.mkdirSync(logsDir, { recursive: true });
  } catch {}

  const stdoutPath = path.join(logsDir, "proxy.log");
  const stderrPath = path.join(logsDir, "proxy.err.log");
  const originalLog = console.log.bind(console);
  const originalError = console.error.bind(console);

  console.log = (...args) => {
    originalLog(...args);
    appendLogFile(stdoutPath, args);
  };
  console.info = console.log;
  console.warn = console.log;
  console.error = (...args) => {
    originalError(...args);
    appendLogFile(stderrPath, args);
  };
}

if (String(process.env.REASONING_PROXY_FILE_LOG) === "1") {
  enableFileLogging();
}

function rewriteRequestBody(bodyBuffer) {
  let data;
  try {
    data = JSON.parse(bodyBuffer.toString("utf8"));
  } catch {
    console.warn("[proxy] non-JSON body, passing through unchanged");
    return null;
  }

  let changed = false;

  if (data.reasoning_effort === undefined) {
    const effort = readReasoningEffort();
    data.reasoning_effort = effort;
    console.log(
      `[proxy] injected reasoning_effort=${effort} for model=${data.model ?? "?"}`
    );
    changed = true;
  } else {
    console.log(`[proxy] request already sets reasoning_effort=${data.reasoning_effort}`);
  }

  const model = String(data.model ?? "");
  const isKimi = /kimi/i.test(model);
  if (isKimi && data.temperature !== undefined && data.temperature !== KIMI_TEMPERATURE) {
    console.log(
      `[proxy] kimi model uses fixed temperature=${KIMI_TEMPERATURE}, rewriting temperature=${data.temperature} -> ${KIMI_TEMPERATURE}`
    );
    data.temperature = KIMI_TEMPERATURE;
    changed = true;
  }
  if (isKimi && data.top_p !== undefined && data.top_p !== KIMI_TOP_P) {
    console.log(
      `[proxy] kimi model uses fixed top_p=${KIMI_TOP_P}, rewriting top_p=${data.top_p} -> ${KIMI_TOP_P}`
    );
    data.top_p = KIMI_TOP_P;
    changed = true;
  }

  return changed ? Buffer.from(JSON.stringify(data), "utf8") : null;
}

function summarizeRequest(bodyBuffer) {
  const hash = crypto.createHash("sha256").update(bodyBuffer).digest("hex").slice(0, 12);
  let model = "?";
  let stream = false;
  try {
    const data = JSON.parse(bodyBuffer.toString("utf8"));
    model = data.model ?? "?";
    stream = Boolean(data.stream);
  } catch {}
  console.log(`[proxy] -> model=${model} stream=${stream} bytes=${bodyBuffer.length} hash=${hash}`);
}

function extractCacheStats(buffer) {
  const text = buffer.toString("utf8");
  const stats = {};
  const patterns = {
    prompt_cache_hit_tokens: /"prompt_cache_hit_tokens"\s*:\s*(\d+)/,
    prompt_cache_miss_tokens: /"prompt_cache_miss_tokens"\s*:\s*(\d+)/,
    cached_tokens: /"cached_tokens"\s*:\s*(\d+)/,
    cache_read_input_tokens: /"cache_read_input_tokens"\s*:\s*(\d+)/,
  };
  for (const [key, re] of Object.entries(patterns)) {
    const match = text.match(re);
    if (match) stats[key] = Number(match[1]);
  }
  return stats;
}

const server = http.createServer((req, res) => {
  const url = String(req.url || "");
  if (url.startsWith(INTERNAL_PREFIX)) {
    handleInternalRequest(req, res);
    return;
  }

  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    let bodyBuffer = Buffer.concat(chunks);

    // Remember the credential the client already sends so the model list can
    // reuse it later. Only the header value is kept, in memory, for this process.
    if (typeof req.headers["authorization"] === "string" && req.headers["authorization"]) {
      lastAuthorization = req.headers["authorization"];
    }

    const contentType = String(req.headers["content-type"] || "");
    if (
      req.method === "POST" &&
      contentType.includes("application/json") &&
      bodyBuffer.length > 0
    ) {
      const rewritten = rewriteRequestBody(bodyBuffer);
      if (rewritten) bodyBuffer = rewritten;
    }

    const headers = { ...req.headers };
    headers.host = `${TARGET_HOST}:${TARGET_PORT}`;
    headers["content-length"] = Buffer.byteLength(bodyBuffer);
    summarizeRequest(bodyBuffer);

    const upstream = http.request(
      {
        host: TARGET_HOST,
        port: TARGET_PORT,
        path: req.url,
        method: req.method,
        headers,
      },
      (upstreamRes) => {
        const collected = [];
        let collectedBytes = 0;
        upstreamRes.on("data", (chunk) => {
          if (collectedBytes < 2 * 1024 * 1024) {
            collected.push(chunk);
            collectedBytes += chunk.length;
          }
        });
        upstreamRes.on("end", () => {
          const stats = extractCacheStats(Buffer.concat(collected));
          if (Object.keys(stats).length > 0) {
            console.log(`[proxy] <- cache stats: ${JSON.stringify(stats)}`);
          }
        });
        res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
        upstreamRes.pipe(res);
      }
    );

    upstream.on("error", (err) => {
      console.error(`[proxy] upstream error: ${err.message}`);
      res.writeHead(502, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          error: { message: `proxy could not reach ${TARGET_HOST}:${TARGET_PORT}: ${err.message}` },
        })
      );
    });

    upstream.end(bodyBuffer);
  });
});

// listen() reports failures as an event, not a throw. Without a handler Node
// prints a raw stack trace for the case users hit most: the port is busy.
server.on("error", (err) => {
  const hint =
    err.code === "EADDRINUSE"
      ? "port is busy; stop the running instance or set another PROXY_PORT in config.bat"
      : err.message;
  console.error(`[proxy] cannot listen on 127.0.0.1:${PROXY_PORT}: ${hint}`);
  process.exit(1);
});

server.listen(PROXY_PORT, "127.0.0.1", () => {
  console.log(`[proxy] listening on http://127.0.0.1:${PROXY_PORT}`);
  console.log(`[proxy] forwarding to http://${TARGET_HOST}:${TARGET_PORT}`);
  console.log(`[proxy] default reasoning_effort=${readReasoningEffort()}`);
  console.log(`[proxy] default kimi temperature=${KIMI_TEMPERATURE}`);
  console.log(`[proxy] default kimi top_p=${KIMI_TOP_P}`);
});
