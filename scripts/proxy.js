const http = require("http");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const PROXY_PORT = Number(process.env.PROXY_PORT || 3120);
const TARGET_HOST = process.env.TARGET_HOST || "10.0.8.19";
const TARGET_PORT = process.env.TARGET_PORT || "80";
const KIMI_TEMPERATURE = Number(process.env.KIMI_TEMPERATURE || 1);
const KIMI_TOP_P = Number(process.env.KIMI_TOP_P || 0.95);

function readReasoningEffort() {
  try {
    const configPath = path.join(__dirname, "..", "config", "config.bat");
    const content = fs.readFileSync(configPath, "utf8");
    const match = content.match(/^\s*set\s+REASONING_EFFORT\s*=\s*(.*?)\s*$/m);
    if (match && match[1].trim()) {
      return match[1].trim();
    }
  } catch {}
  return process.env.REASONING_EFFORT || "high";
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
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    let bodyBuffer = Buffer.concat(chunks);

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

server.listen(PROXY_PORT, "127.0.0.1", () => {
  console.log(`[proxy] listening on http://127.0.0.1:${PROXY_PORT}`);
  console.log(`[proxy] forwarding to http://${TARGET_HOST}:${TARGET_PORT}`);
  console.log(`[proxy] default reasoning_effort=${readReasoningEffort()}`);
  console.log(`[proxy] default kimi temperature=${KIMI_TEMPERATURE}`);
  console.log(`[proxy] default kimi top_p=${KIMI_TOP_P}`);
});
