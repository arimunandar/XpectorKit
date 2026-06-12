# Xpector Relay

Ephemeral, **DEBUG-only** live debug-stream relay on Cloudflare Workers + Durable Objects.

It gives a browser anywhere **full parity** with the on-device LAN viewer when the
device is **not** on the same LAN (remote tester, shared session) — every tab,
including Current (screen) and Layers. NAT-friendly: the app dials **out** to the
relay over a WebSocket. One Durable Object per session fans out streamed events
**and** proxies on-demand pull requests back to the device. Nothing is persisted —
when the session ends the DO evaporates.

```
 App  ──WSS  /ingest/<sid>  (Authorization: Bearer INGEST_KEY)──►  Worker ──► DO (session)
 Browser  ──GET /v/<sid>#t=<token>   (serves the real LAN viewer HTML; sets session cookie)
          ──SSE /stream                       (streamed events: log/net/leak/nav)
          ──GET /screen|/hierarchy|/node/*    (proxied to the device over the WS)
```

**Same UI as local.** The viewer page IS the LAN viewer's HTML (`src/viewer.html`,
generated from the running `XPHttpLogServer` page) with two tiny patches: an
app-name placeholder and a cookie-setter that reads the `#t=` token so its
same-origin requests are authed. Streamed events use the same names/fields
(`XPLogEntry` / `net` / `leak` / `nav`); pull endpoints round-trip to the device.

### Device proxy (bidirectional RPC over the WS)
`/screen`, `/hierarchy`, `/node/<id>`, `/node/<id>/image` aren't streamed — the DO
sends `{rt:"req",id,path}` to the app, which answers with
`{rt:"res",id,status,ct,b64}` (base64 body). `XPCloudRelayClient` dispatches these
to the *same* providers `XPHttpLogServer` uses, so responses are byte-identical to
LAN. 8s timeout; returns 503 if the device is offline.

## Layout

| File | Purpose |
|------|---------|
| `src/index.ts` | Worker router + `XPSessionRelay` Durable Object |
| `src/viewer.ts` | Self-contained browser viewer (HTML/JS) |
| `wrangler.jsonc` | Config, DO binding, custom-domain route |
| `smoke.mjs` | End-to-end test against `wrangler dev` |

## Develop

```bash
cd cloud
npm install
# .dev.vars holds local secrets (gitignored) — already present for local dev
npm run dev                 # http://127.0.0.1:8787
node smoke.mjs              # end-to-end: mint → ingest WS → SSE replay + live
npm run typecheck
```

## Deploy

1. Set the two secrets (never commit them):
   ```bash
   wrangler secret put INGEST_KEY      # dev API key baked into DEBUG app builds ONLY
   wrangler secret put TOKEN_SECRET    # HMAC key for signing viewer tokens (random, long)
   ```
   Generate strong values, e.g. `openssl rand -hex 32`.

2. Pick the hostname. `wrangler.jsonc` defaults to `relay.xpector.cloud` as a Cloudflare
   **custom domain** (Wrangler creates the DNS record automatically on first deploy, since
   `xpector.cloud` is on this account). Change `routes[].pattern` and `vars.PUBLIC_BASE`
   together if you want a different subdomain.

3. Deploy:
   ```bash
   npm run deploy
   wrangler tail        # live logs
   ```

## HTTP API

### `POST /api/session`  — app mints a session
Auth: `Authorization: Bearer <INGEST_KEY>`. Optional JSON body `{ "name": "iPhone 15 · QA" }`.

Response:
```json
{
  "sessionId": "TYGpaVF1VidTZAfSgwJuFg",
  "ingestUrl": "wss://relay.xpector.cloud/ingest/TYGpaVF1VidTZAfSgwJuFg",
  "viewerUrl": "https://relay.xpector.cloud/v/TYGpaVF1VidTZAfSgwJuFg#t=<token>",
  "viewerToken": "<token>",
  "expiresAt": 1781170511
}
```
`viewerUrl` is the link to hand to a teammate / show as a QR. The token lives in the URL
**fragment** (`#t=`), so it isn't sent on page navigation; the page reads it and uses it
for the SSE request. Token is HMAC-signed, bound to the session, and expires
(`VIEWER_TTL_SECONDS`, default 30 min).

### `POST /api/revoke`  — app kills a session
Auth: `Authorization: Bearer <INGEST_KEY>`. Body `{ "sessionId": "<sid>" }`. Marks the
session revoked (persisted in the DO): current viewers are dropped and all later
`/stream` / `/screen` / `/hierarchy` / `/node/*` requests return **410**. Used by the
"Regenerate" button — the app mints a fresh session and revokes the old one, so the
previous share link stops working immediately.

### `WSS /ingest/<sid>`  — app pushes events
Auth: `Authorization: Bearer <INGEST_KEY>`. Each WS text message is one JSON frame:
```json
{ "t": "log" | "net" | "leak" | "nav", "d": <same payload as the LAN SSE data line> }
```
Send `"ka"` periodically as a keepalive (keeps the WS + DO alive). Only one producer per
session; a new connection replaces a stale one.

### `GET /v/<sid>`  — viewer HTML (token in `#t=` fragment)
### `GET /sse/<sid>?t=<token>`  — SSE stream (replay buffer, then live)
### `GET /healthz`  — health check

## Swift client (XpectorKit side — implemented)

Implemented in `Sources/XpectorServer/XPCloudRelayClient.swift`, wired into
`XpectorServer` alongside the LAN server. DEBUG-only: creation is `#if DEBUG`-gated
so the ingest key and the relay never exist in a Release build.

Enable it from the host app's DEBUG start path:

```swift
#if DEBUG
var config = XPConfiguration()
config.enableCloudRelay = true
config.cloudRelayBaseURL = "https://relay.xpector.cloud"
config.cloudRelayIngestKey = "<INGEST_KEY>"   // never ship in Release
XpectorServer.shared.start(config: config)
#endif
```

Then share the link:

```swift
XpectorServer.shared.cloudViewerURL()            // URL? once the session connects
XpectorServer.shared.presentCloudViewer()        // QR + link sheet (reuses the LAN sheet)
```

Behaviour: on start it `POST /api/session` (Bearer key) → opens a
`URLSessionWebSocketTask` to `ingestUrl` (Bearer key header) → mirrors the four LAN
push sites (`push`/`pushNetwork`/`pushLeak`/`pushNav`) as `{t,d}` frames using the
same `.millisecondsSince1970` encoding. Sends `"ka"` every 15 s; reconnects with
exponential backoff (re-joining the same session to keep the share link + replay).
Network entries get extra header redaction (`Authorization`/`Cookie`/`Set-Cookie`/
`x-api-key`) before leaving the device.

## Security model

- **DEBUG-only**, like `XPHttpLogServer`. `INGEST_KEY` never ships in Release.
- Session IDs are random 128-bit (not enumerable).
- Viewer access requires a short-lived **HMAC-signed token** bound to the session;
  links auto-expire. No accounts, no persistence.
- This is live-debug tooling, **not** a production logging backend.
