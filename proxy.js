const http = require("http");
const crypto = require("crypto");

const PROXY_PORT = Number(process.env.PROXY_PORT || 3120);
const TARGET_HOST = process.env.TARGET_HOST || "10.0.8.19";
const TARGET_PORT = process.env.TARGET_PORT || "80";
const REASONING_EFFORT = process.env.REASONING_EFFORT || "high";

function injectReasoningEffort(bodyBuffer) {
  try {
    const data = JSON.parse(bodyBuffer.toString("utf8"));
    if (data.reasoning_effort === undefined) {
      data.reasoning_effort = REASONING_EFFORT;
      console.log(
        `[proxy] injected reasoning_effort=${REASONING_EFFORT} for model=${data.model ?? "?"}`
      );
      return Buffer.from(JSON.stringify(data), "utf8");
    }
    console.log(`[proxy] request already sets reasoning_effort=${data.reasoning_effort}`);
    return null;
  } catch {
    console.warn("[proxy] non-JSON body, passing through unchanged");
    return null;
  }
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
      const rewritten = injectReasoningEffort(bodyBuffer);
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
  console.log(`[proxy] default reasoning_effort=${REASONING_EFFORT}`);
});
