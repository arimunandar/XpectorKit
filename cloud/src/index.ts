/**
 * Xpector Relay — ephemeral live debug relay (DEBUG-only tooling).
 *
 * NAT-friendly fan-out + device proxy: the instrumented app dials OUT over a
 * WebSocket; browsers connect with a short-lived signed token and get FULL
 * parity with the on-device LAN viewer.
 *
 *   App  ──WSS  /ingest/<sid>  (Authorization: Bearer INGEST_KEY)──►  DO
 *   Browser  ──GET /v/<sid>#t=<token>  (sets session cookie)
 *            ──SSE  /stream                  (streamed events)
 *            ──GET  /screen|/hierarchy|/node/*  (proxied to the device)
 *
 * Streamed events (logs/net/leak/nav) ride the WS app→DO→browser. Pull
 * endpoints (screen/layers/node) are answered by round-tripping a request back
 * to the device over the same WS (bidirectional RPC), so the cloud viewer has
 * every tab the LAN viewer has. Nothing is persisted — the DO evaporates with
 * the session.
 */

import { DurableObject } from "cloudflare:workers";
import VIEWER_HTML from "./viewer.html";

export interface Env {
  RELAY: DurableObjectNamespace<XPSessionRelay>;
  KEYS: DurableObjectNamespace<XPKeyRegistry>;
  INGEST_KEY: string;
  TOKEN_SECRET: string;
  PUBLIC_BASE: string;
  VIEWER_TTL_SECONDS: string;
  // Optional. When set, POST /api/keys requires `Authorization: Bearer <ADMIN_KEY>`
  // (operator-issued keys). When unset, key issuance is open + IP-rate-limited
  // so anyone self-hosting can let users mint their own keys.
  ADMIN_KEY?: string;
}

// ----- event protocol (app → DO → browser) ----------------------------------

type EventType = "log" | "net" | "leak" | "nav";
const SSE_EVENT: Record<EventType, string> = { log: "", net: "net", leak: "leak", nav: "nav" };
const CAP: Record<EventType, number> = { log: 100, net: 50, leak: 200, nav: 40 };

// Device-pull paths the cloud viewer proxies back to the app.
function isDevicePath(path: string): boolean {
  return path === "/screen" || path === "/hierarchy" || path.startsWith("/node/");
}

// ----- signed viewer tokens (HMAC-SHA256) -----------------------------------

function b64urlEncode(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const b of arr) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlToBytes(s: string): Uint8Array {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function b64ToBytes(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"]
  );
}
async function mintViewerToken(secret: string, sid: string, ttlSeconds: number, nowMs: number) {
  const expMs = nowMs + ttlSeconds * 1000;
  const payload = b64urlEncode(new TextEncoder().encode(JSON.stringify({ sid, exp: expMs })));
  const key = await hmacKey(secret);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
  return { token: `${payload}.${b64urlEncode(sig)}`, expMs };
}
async function verifyViewerToken(secret: string, token: string, sid: string, nowMs: number): Promise<boolean> {
  const dot = token.indexOf(".");
  if (dot < 0) return false;
  const payload = token.slice(0, dot);
  const sig = token.slice(dot + 1);
  const key = await hmacKey(secret);
  let ok: boolean;
  try {
    ok = await crypto.subtle.verify("HMAC", key, b64urlToBytes(sig), new TextEncoder().encode(payload));
  } catch {
    return false;
  }
  if (!ok) return false;
  try {
    const claims = JSON.parse(new TextDecoder().decode(b64urlToBytes(payload)));
    return claims.sid === sid && typeof claims.exp === "number" && claims.exp > nowMs;
  } catch {
    return false;
  }
}
function randomId(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return b64urlEncode(bytes);
}
function bearerKey(request: Request): string {
  const auth = request.headers.get("Authorization") ?? "";
  const m = auth.match(/^Bearer\s+(.+)$/i);
  return m ? m[1] : request.headers.get("X-Xpector-Key") ?? "";
}

async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return b64urlEncode(digest);
}

/** Constant-time string compare over fixed-length SHA-256 digests, so neither
 *  length nor content leaks via timing. */
async function secretEquals(a: string, b: string): Promise<boolean> {
  if (!a || !b) return false;
  const enc = new TextEncoder();
  const [da, db] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const av = new Uint8Array(da);
  const bv = new Uint8Array(db);
  let diff = 0;
  for (let i = 0; i < av.length; i++) diff |= av[i] ^ bv[i];
  return diff === 0;
}

/** Resolve the producer's tenant from its Bearer key, or null if unauthorized.
 *  The operator's `INGEST_KEY` secret (if set) maps to the reserved "root"
 *  tenant for backward compatibility; every other valid key is a registered
 *  tenant minted via POST /api/keys. */
async function resolveTenant(request: Request, env: Env): Promise<string | null> {
  const provided = bearerKey(request);
  if (!provided) return null;
  if (env.INGEST_KEY && (await secretEquals(provided, env.INGEST_KEY))) return "root";
  const tid = await env.KEYS.getByName("_root").lookupTenant(await sha256Hex(provided));
  return tid;
}

// Resolve + verify the viewer session from the `xp=<sid>.<token>` cookie that
// /v sets from the URL fragment. Returns the session id or null.
async function cookieSession(request: Request, env: Env, nowMs: number): Promise<string | null> {
  const cookie = request.headers.get("Cookie") ?? "";
  const m = cookie.match(/(?:^|;\s*)xp=([^;]+)/);
  if (!m) return null;
  const raw = decodeURIComponent(m[1]);
  const dot = raw.indexOf(".");
  if (dot < 0) return null;
  const sid = raw.slice(0, dot);
  const token = raw.slice(dot + 1);
  if (!sid || !(await verifyViewerToken(env.TOKEN_SECRET, token, sid, nowMs))) return null;
  return sid;
}

function cors(extra: Record<string, string> = {}): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type, X-Xpector-Key",
    ...extra,
  };
}
function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// ----- Worker (router) ------------------------------------------------------

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const now = Date.now();

    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors() });

    if (path === "/" || path === "/healthz") {
      return new Response("xpector-relay ok", { headers: cors({ "Content-Type": "text/plain" }) });
    }

    // Self-service key issuance. Each key is its own tenant; sessions minted
    // with it are isolated from other tenants'. Open + IP-rate-limited unless
    // ADMIN_KEY is configured, in which case it must be presented.
    if (path === "/api/keys" && request.method === "POST") {
      if (env.ADMIN_KEY) {
        if (!(await secretEquals(bearerKey(request), env.ADMIN_KEY))) {
          return new Response("unauthorized", { status: 401, headers: cors() });
        }
      }
      let label = "";
      try {
        const b = (await request.json()) as { label?: string };
        if (b && typeof b.label === "string") label = b.label.slice(0, 80);
      } catch {
        /* body optional */
      }
      const ip = request.headers.get("CF-Connecting-IP") || "unknown";
      const open = !env.ADMIN_KEY;
      const res = await env.KEYS.getByName("_root").issue(label, ip, open);
      if (!res) return new Response("rate limited", { status: 429, headers: cors() });
      // The raw key is returned exactly ONCE — only its hash is stored.
      return Response.json(res, { headers: cors() });
    }

    // Revoke a key (a key may revoke itself; ADMIN_KEY may revoke any).
    if (path === "/api/keys/revoke" && request.method === "POST") {
      const provided = bearerKey(request);
      const isAdmin = env.ADMIN_KEY ? await secretEquals(provided, env.ADMIN_KEY) : false;
      let target = provided;
      try {
        const b = (await request.json()) as { ingestKey?: string };
        if (isAdmin && b && typeof b.ingestKey === "string") target = b.ingestKey;
      } catch {
        /* body optional */
      }
      if (!target) return new Response("missing key", { status: 400, headers: cors() });
      const ok = await env.KEYS.getByName("_root").revokeKey(await sha256Hex(target));
      return Response.json({ revoked: ok }, { headers: cors() });
    }

    // App mints a session.
    if (path === "/api/session" && request.method === "POST") {
      const tid = await resolveTenant(request, env);
      if (!tid) return new Response("unauthorized", { status: 401, headers: cors() });
      const sid = randomId();
      const ttl = parseInt(env.VIEWER_TTL_SECONDS || "1800", 10);
      const { token, expMs } = await mintViewerToken(env.TOKEN_SECRET, sid, ttl, now);
      const base = env.PUBLIC_BASE.replace(/\/+$/, "");
      const wsBase = base.replace(/^http/, "ws");
      let name = "";
      try {
        const body = (await request.json()) as { name?: string };
        if (body && typeof body.name === "string") name = body.name.slice(0, 80);
      } catch {
        /* body optional */
      }
      // Bind the session to its creating tenant (and store the name) so only
      // that tenant can ingest into / revoke it.
      await env.RELAY.getByName(sid).init(tid, name);
      return Response.json(
        {
          sessionId: sid,
          ingestUrl: `${wsBase}/ingest/${sid}`,
          viewerUrl: `${base}/v/${sid}#t=${token}`,
          viewerToken: token,
          expiresAt: Math.floor(expMs / 1000),
        },
        { headers: cors() }
      );
    }

    // App kills a session (on regenerate) — old viewer links stop working.
    if (path === "/api/revoke" && request.method === "POST") {
      const tid = await resolveTenant(request, env);
      if (!tid) return new Response("unauthorized", { status: 401, headers: cors() });
      let sid = "";
      try {
        const b = (await request.json()) as { sessionId?: string };
        if (b && typeof b.sessionId === "string") sid = b.sessionId;
      } catch {
        /* ignore */
      }
      if (!sid) return new Response("missing sessionId", { status: 400, headers: cors() });
      const ok = await env.RELAY.getByName(sid).revoke(tid);
      if (!ok) return new Response("forbidden", { status: 403, headers: cors() });
      return Response.json({ revoked: true }, { headers: cors() });
    }

    // Producer WebSocket from the app.
    if (path.startsWith("/ingest/")) {
      if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return new Response("expected websocket", { status: 426, headers: cors() });
      }
      const tid = await resolveTenant(request, env);
      if (!tid) return new Response("unauthorized", { status: 401 });
      const sid = decodeURIComponent(path.slice("/ingest/".length));
      if (!sid) return new Response("missing session", { status: 400 });
      // The DO rejects the upgrade if `tid` isn't the session's owner.
      return env.RELAY.getByName(sid).fetch(
        new Request(`https://do/ingest?tid=${encodeURIComponent(tid)}`, request)
      );
    }

    // Viewer HTML — inject the live app name; the page sets the session cookie
    // from the #fragment so its subsequent requests are authed.
    if (path.startsWith("/v/")) {
      const sid = decodeURIComponent(path.slice("/v/".length));
      let name = "Xpector";
      if (sid) {
        try {
          const n = await env.RELAY.getByName(sid).getName();
          if (n) name = n;
        } catch {
          /* DO may not exist yet */
        }
      }
      const html = VIEWER_HTML.replaceAll("__XP_APP_NAME__", escapeHtml(name));
      return new Response(html, {
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          "Cache-Control": "no-store",
          // Defense-in-depth: the page is fully first-party, so lock everything
          // to 'self' (+ data: images, inline script/style the page relies on).
          // This blocks an XSS from exfiltrating the session token to an
          // off-origin host (connect-src/img-src 'self') and bars framing.
          "Content-Security-Policy":
            "default-src 'none'; connect-src 'self'; img-src 'self' data:; " +
            "script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " +
            "font-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
          "X-Content-Type-Options": "nosniff",
          "Referrer-Policy": "no-referrer",
        },
      });
    }

    // Viewer SSE via query token (kept for programmatic use / smoke tests).
    if (path.startsWith("/sse/")) {
      const sid = decodeURIComponent(path.slice("/sse/".length));
      const token = url.searchParams.get("t") || url.searchParams.get("token") || "";
      if (!sid || !(await verifyViewerToken(env.TOKEN_SECRET, token, sid, now))) {
        return new Response("forbidden", { status: 403, headers: cors() });
      }
      return env.RELAY.getByName(sid).fetch(new Request("https://do/sse", request));
    }

    // ---- cookie-authed viewer endpoints (mirror the LAN server's paths) ----

    // Live event stream.
    if (path === "/stream") {
      const sid = await cookieSession(request, env, now);
      if (!sid) return new Response("forbidden", { status: 403 });
      return env.RELAY.getByName(sid).fetch(new Request("https://do/sse", request));
    }

    // Pull endpoints proxied to the device: /screen, /hierarchy, /node/<id>[/image].
    if (isDevicePath(path)) {
      const sid = await cookieSession(request, env, now);
      if (!sid) return new Response("forbidden", { status: 403 });
      return env.RELAY.getByName(sid).fetch(
        new Request(`https://do/dev?path=${encodeURIComponent(path)}`)
      );
    }

    return new Response("not found", { status: 404, headers: cors() });
  },
};

// ----- Durable Object: one per session --------------------------------------

interface BufferedEvent {
  type: EventType;
  json: string;
}
interface DeviceResponse {
  status: number;
  ct?: string;
  b64?: string;
}

export class XPSessionRelay extends DurableObject<Env> {
  private producer: WebSocket | null = null;
  private viewers = new Set<WritableStreamDefaultWriter>();
  private buffers: Record<EventType, BufferedEvent[]> = { log: [], net: [], leak: [], nav: [] };
  private sessionName = "";
  private ownerTid: string | null = null;
  private revoked = false;
  private encoder = new TextEncoder();
  // Pending device round-trips: request id → resolver.
  private pending = new Map<string, { resolve: (r: DeviceResponse) => void; timer: ReturnType<typeof setTimeout> }>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Owner + revocation must survive eviction, or a killed link could revive /
    // a session could lose its tenant binding.
    ctx.blockConcurrencyWhile(async () => {
      this.revoked = (await ctx.storage.get<boolean>("revoked")) ?? false;
      this.ownerTid = (await ctx.storage.get<string>("owner")) ?? null;
    });
  }

  // Bind the session to the tenant that created it (first writer wins; a second
  // init from a different tenant is ignored so a sid can't be hijacked).
  async init(tid: string, name: string): Promise<void> {
    if (this.ownerTid === null) {
      this.ownerTid = tid;
      await this.ctx.storage.put("owner", tid);
    }
    if (name) this.sessionName = name;
  }
  async getName(): Promise<string> {
    // Don't leak the app name for a killed session (the /v page falls back to a
    // generic title).
    return this.revoked ? "" : this.sessionName;
  }

  // Kill this session: drop viewers, close the producer, and reject everything
  // afterwards so the old share link is dead. Only the owning tenant may revoke
  // (the worker passes its resolved tid); returns false if it doesn't own this.
  async revoke(tid?: string): Promise<boolean> {
    if (this.ownerTid !== null && tid !== undefined && tid !== this.ownerTid) return false;
    this.revoked = true;
    await this.ctx.storage.put("revoked", true);
    for (const w of Array.from(this.viewers)) this.dropViewer(w);
    if (this.producer) {
      try {
        this.producer.close(1000, "revoked");
      } catch {
        /* noop */
      }
      this.producer = null;
    }
    return true;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/ingest") return this.handleIngest(url.searchParams.get("tid"));
    if (url.pathname === "/sse") return this.handleViewer();
    if (url.pathname === "/dev") return this.proxyDevice(url.searchParams.get("path") || "");
    return new Response("not found", { status: 404 });
  }

  // --- producer (app) WebSocket ---
  private handleIngest(tid: string | null): Response {
    // Tenant isolation: a producer may only ingest into a session its own key
    // created. (sids are unguessable, so this is defense-in-depth.)
    if (this.revoked) return new Response("session ended", { status: 410 });
    if (this.ownerTid !== null && tid !== this.ownerTid) {
      return new Response("forbidden", { status: 403 });
    }
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    if (this.producer) {
      try {
        this.producer.close(1000, "replaced");
      } catch {
        /* noop */
      }
    }
    this.producer = server;
    this.ensureAlarm();

    server.addEventListener("message", (evt) => {
      if (typeof evt.data === "string") this.onProducerMessage(evt.data);
    });
    const drop = () => {
      if (this.producer === server) this.producer = null;
    };
    server.addEventListener("close", drop);
    server.addEventListener("error", drop);
    return new Response(null, { status: 101, webSocket: client });
  }

  private onProducerMessage(raw: string): void {
    if (raw === "ka" || raw === "") return;
    // Bound a single frame: device-pull responses carry base64 screenshots /
    // hierarchies (the largest legit payload ~ a few MB); anything past this is
    // dropped so a buggy/hostile producer can't balloon DO memory or the replay
    // buffer. 8 MB covers a full-screen PNG + headroom.
    if (raw.length > 8 * 1024 * 1024) return;
    let msg: any;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    // Device response to a pull request.
    if (msg && msg.rt === "res" && typeof msg.id === "string") {
      const p = this.pending.get(msg.id);
      if (p) {
        clearTimeout(p.timer);
        this.pending.delete(msg.id);
        p.resolve({ status: msg.status ?? 200, ct: msg.ct, b64: msg.b64 });
      }
      return;
    }
    // Streamed event frame.
    if (!msg || !(msg.t in SSE_EVENT)) return;
    const json = JSON.stringify(msg.d ?? null);
    const buf = this.buffers[msg.t as EventType];
    buf.push({ type: msg.t, json });
    if (buf.length > CAP[msg.t as EventType]) buf.shift();
    this.broadcast(this.sseChunk(msg.t, json));
  }

  // --- device pull proxy ---
  private async proxyDevice(path: string): Promise<Response> {
    if (this.revoked) return new Response("session ended", { status: 410 });
    const producer = this.producer;
    if (!producer || !path) {
      return new Response("device offline", { status: 503 });
    }
    const id = randomId();
    const result = await new Promise<DeviceResponse>((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve({ status: 504 });
      }, 8000);
      this.pending.set(id, { resolve, timer });
      try {
        producer.send(JSON.stringify({ rt: "req", id, path }));
      } catch {
        clearTimeout(timer);
        this.pending.delete(id);
        resolve({ status: 503 });
      }
    });
    if (result.status !== 200 || !result.b64) {
      return new Response(null, { status: result.status });
    }
    return new Response(b64ToBytes(result.b64), {
      status: 200,
      headers: {
        "Content-Type": result.ct || "application/octet-stream",
        "Cache-Control": "no-store",
      },
    });
  }

  // --- viewer (browser) SSE ---
  private handleViewer(): Response {
    if (this.revoked) return new Response("session ended", { status: 410 });
    const { readable, writable } = new TransformStream();
    const writer = writable.getWriter();
    this.viewers.add(writer);
    this.ensureAlarm();

    const order: EventType[] = ["log", "net", "leak", "nav"];
    let preamble = ":connected\n\n";
    for (const t of order) for (const ev of this.buffers[t]) preamble += this.sseChunk(t, ev.json);
    writer.write(this.encoder.encode(preamble)).catch(() => this.dropViewer(writer));

    return new Response(readable, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
        // No `Access-Control-Allow-Origin: *` here: the stream is token-authed
        // and consumed first-party (same origin as /v/). Leaving it open would
        // let any web origin read a leaked-token stream cross-origin.
        "X-Accel-Buffering": "no",
      },
    });
  }

  private sseChunk(type: EventType, json: string): string {
    const name = SSE_EVENT[type];
    return name ? `event: ${name}\ndata: ${json}\n\n` : `data: ${json}\n\n`;
  }
  private broadcast(text: string): void {
    const bytes = this.encoder.encode(text);
    for (const w of this.viewers) w.write(bytes).catch(() => this.dropViewer(w));
  }
  private dropViewer(w: WritableStreamDefaultWriter): void {
    this.viewers.delete(w);
    try {
      w.close();
    } catch {
      /* noop */
    }
  }

  private ensureAlarm(): void {
    this.ctx.storage.getAlarm().then((a) => {
      if (a === null) this.ctx.storage.setAlarm(Date.now() + 15_000);
    });
  }
  async alarm(): Promise<void> {
    this.broadcast(":ka\n\n");
    if (this.producer !== null || this.viewers.size > 0) {
      await this.ctx.storage.setAlarm(Date.now() + 15_000);
    }
  }
}

// ----- Durable Object: tenant key registry (single global instance) ----------
//
// Maps a SHA-256 hash of each issued ingest key → its tenant id. Only the hash
// is stored, so a registry dump never leaks usable keys. A single instance
// (addressed by the fixed name "_root") serialises issuance and lookups.

interface KeyRecord {
  tid: string;
  label: string;
  createdAt: number;
}
interface RateRecord {
  count: number;
  resetAt: number;
}

export class XPKeyRegistry extends DurableObject<Env> {
  // Open (no ADMIN_KEY) issuance budget per IP, to bound abuse.
  private static readonly RL_MAX = 10;
  private static readonly RL_WINDOW_MS = 60 * 60 * 1000;

  private gen(prefix: string, bytes: number): string {
    const b = new Uint8Array(bytes);
    crypto.getRandomValues(b);
    return prefix + b64urlEncode(b);
  }

  /** Mint a new key + tenant. In open mode, enforce a per-IP rate limit.
   *  Returns null when rate-limited. The raw key is returned ONCE. */
  async issue(label: string, ip: string, open: boolean): Promise<{ ingestKey: string; tenantId: string; createdAt: number } | null> {
    const now = Date.now();
    if (open) {
      const rlKey = `rl:${ip}`;
      const rl = (await this.ctx.storage.get<RateRecord>(rlKey)) ?? { count: 0, resetAt: now + XPKeyRegistry.RL_WINDOW_MS };
      if (now > rl.resetAt) {
        rl.count = 0;
        rl.resetAt = now + XPKeyRegistry.RL_WINDOW_MS;
      }
      if (rl.count >= XPKeyRegistry.RL_MAX) return null;
      rl.count += 1;
      await this.ctx.storage.put(rlKey, rl);
    }
    const ingestKey = this.gen("xpk_", 24);
    const tenantId = this.gen("t_", 12);
    const hash = b64urlEncode(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ingestKey)));
    const rec: KeyRecord = { tid: tenantId, label, createdAt: now };
    await this.ctx.storage.put(`k:${hash}`, rec);
    return { ingestKey, tenantId, createdAt: now };
  }

  /** Resolve a key hash → tenant id (or null if unknown/revoked). */
  async lookupTenant(keyHash: string): Promise<string | null> {
    const rec = await this.ctx.storage.get<KeyRecord>(`k:${keyHash}`);
    return rec ? rec.tid : null;
  }

  /** Revoke a key by hash. Returns whether it existed. */
  async revokeKey(keyHash: string): Promise<boolean> {
    return this.ctx.storage.delete(`k:${keyHash}`);
  }
}
