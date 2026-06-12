# Xpector WebSocket test server

A tiny, **zero-dependency** WebSocket server for exercising Xpector's **Sockets**
tab end-to-end. It hand-rolls the WebSocket upgrade + framing on Node's built-in
`http`/`crypto` modules, so it runs with a bare `node server.mjs` — no
`npm install`.

## Run

```bash
node server.mjs            # listens on ws://127.0.0.1:8080
PORT=9001 node server.mjs  # custom port
```

Requires Node 16+ (uses `BigInt` buffer helpers and ES modules).

## Endpoints

| Path         | Frames sent                                              |
|--------------|----------------------------------------------------------|
| `/text`      | JSON **text** frames (a welcome, then a `tick` every 2s) |
| `/protobuf`  | **binary** frames, hand-encoded as real protobuf         |
| `/`          | both (alternates text + protobuf pushes)                 |

Every client message is echoed back:
- a **text** message → a JSON `{type:"echo",…}` text frame,
- a **binary** message → a fresh protobuf binary frame.

The welcome frame deliberately includes an `accessToken` field so you can verify
**redaction** — it shows raw in the on-device inspector but `<redacted>` in the
LAN / cloud viewers.

## Protobuf shape

`buildProtobuf(counter)` emits a message with:

- `#1` varint (a counter)
- `#2` string (`"xpector"`)
- `#3` repeated string (`"tag-a"`, `"tag-b"`)
- `#4` nested message (`#1` varint, `#2` string)

— enough to exercise the schema-less decoder's varint / string / repeated /
nested-message paths and render a real field tree.

## Using it from the simulator

`127.0.0.1` on the iOS Simulator is the host Mac's loopback, so the demo app can
reach this server directly. In the Xpector demo, open the **WebSocket** section
and tap **Connect**, **Send text**, **Send protobuf**, **Disconnect**. The traffic
is captured automatically by the swizzle (no SDK calls in the demo's socket code),
then appears in the Sockets tab of every viewer.
