// End-to-end smoke test against a running `wrangler dev` (http://127.0.0.1:8787).
// 1) mint a session  2) open ingest WS + push events  3) connect SSE + verify replay + live.
const BASE = process.env.BASE || "http://127.0.0.1:8787";
const KEY = process.env.INGEST_KEY || "dev-ingest-key-local-only";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function fail(m) { console.error("FAIL:", m); process.exit(1); }

// 1) mint
const sres = await fetch(`${BASE}/api/session`, {
  method: "POST",
  headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" },
  body: JSON.stringify({ name: "smoke-device" }),
});
if (sres.status !== 200) fail(`/api/session -> ${sres.status}`);
const sess = await sres.json();
console.log("session:", sess.sessionId, "viewerUrl:", sess.viewerUrl);
const token = sess.viewerToken;
const sid = sess.sessionId;

// auth negatives
const bad = await fetch(`${BASE}/api/session`, { method: "POST", headers: { Authorization: "Bearer nope" } });
if (bad.status !== 401) fail(`bad key should 401, got ${bad.status}`);
const noTok = await fetch(`${BASE}/sse/${sid}?t=tampered`);
if (noTok.status !== 403) fail(`bad token should 403, got ${noTok.status}`);
console.log("auth negatives OK (401 + 403)");

// 2) ingest WS — push a buffered (replay) event BEFORE any viewer connects
const ws = new WebSocket(sess.ingestUrl.replace(/^ws/, "ws"), { headers: { Authorization: `Bearer ${KEY}` } });
await new Promise((res, rej) => { ws.addEventListener("open", res); ws.addEventListener("error", rej); });
ws.send(JSON.stringify({ t: "log", d: { id: "1", timestamp: Date.now(), message: "buffered-before-viewer", source: "stdout", category: "info" } }));
await sleep(150);

// 3) connect SSE viewer, read stream
const sseRes = await fetch(`${BASE}/sse/${sid}?t=${encodeURIComponent(token)}`, { headers: { Accept: "text/event-stream" } });
if (sseRes.status !== 200) fail(`/sse -> ${sseRes.status}`);
const reader = sseRes.body.getReader();
const dec = new TextDecoder();
let buf = "";
const seen = [];
const pump = (async () => {
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    seen.push(buf);
    if (buf.includes("live-net-event")) break;
  }
})();

await sleep(200);
// push live events of every type
ws.send(JSON.stringify({ t: "net", d: { id: "n1", url: "https://api.example.com/x", method: "GET", statusCode: 200, durationMs: 42, timestamp: Date.now(), error: null, requestHeaders:{}, responseHeaders:{}, bytesReceived: 10 } }));
ws.send(JSON.stringify({ t: "log", d: { id: "2", timestamp: Date.now(), message: "live-net-event", source: "stdout", category: "debug" } }));
await Promise.race([pump, sleep(2000)]);
reader.cancel().catch(() => {});
ws.close();

const all = buf;
const checks = [
  ["replay buffered log", all.includes("buffered-before-viewer")],
  ["live default(log) event", all.includes("live-net-event")],
  ["named net event", all.includes("event: net") && all.includes("api.example.com")],
];
let okAll = true;
for (const [name, ok] of checks) { console.log(ok ? "PASS" : "FAIL", "-", name); okAll = okAll && ok; }
if (!okAll) { console.error("\n--- stream dump ---\n" + all); process.exit(1); }
console.log("\nALL CHECKS PASSED");
process.exit(0);
