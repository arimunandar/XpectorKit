// Zero-dependency WebSocket test server for exercising Xpector's Sockets tab.
//
// Hand-rolls the WebSocket upgrade + framing on Node's built-in `http`/`crypto`
// so it runs with a bare `node server.mjs` — no `npm install`. Two modes,
// selected by the connection path:
//
//   ws://127.0.0.1:8080/text       — JSON text frames (echo + periodic push)
//   ws://127.0.0.1:8080/protobuf   — real protobuf binary frames (echo + push)
//   ws://127.0.0.1:8080/           — both (alternates text + protobuf pushes)
//
// The protobuf frames are encoded by a tiny varint + length-delimited writer
// (below), so Xpector's schema-less decoder has genuine wire data to render.

import http from "node:http";
import crypto from "node:crypto";

const PORT = process.env.PORT ? parseInt(process.env.PORT, 10) : 8080;
const WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// ---- minimal protobuf encoder (no dependency) ------------------------------

function varint(nValue) {
  const out = [];
  let v = BigInt(nValue);
  do {
    let b = Number(v & 0x7fn);
    v >>= 7n;
    if (v > 0n) b |= 0x80;
    out.push(b);
  } while (v > 0n);
  return Buffer.from(out);
}
function tag(field, wire) {
  return varint((field << 3) | wire);
}
function pVarint(field, n) {
  return Buffer.concat([tag(field, 0), varint(n)]);
}
function pString(field, s) {
  const b = Buffer.from(s, "utf8");
  return Buffer.concat([tag(field, 2), varint(b.length), b]);
}
function pMessage(field, msgBuf) {
  return Buffer.concat([tag(field, 2), varint(msgBuf.length), msgBuf]);
}

// Builds a representative protobuf message: a counter, a label, a repeated
// string, and a nested sub-message — enough to show the field tree, repeated
// arrays, and recursion in the viewer.
function buildProtobuf(counter) {
  const inner = Buffer.concat([
    pVarint(1, counter * 7),
    pString(2, "nested-" + counter),
  ]);
  return Buffer.concat([
    pVarint(1, counter),                         // #1 varint
    pString(2, "xpector"),                        // #2 string
    pString(3, "tag-a"),                          // #3 repeated string
    pString(3, "tag-b"),
    pMessage(4, inner),                           // #4 nested message
  ]);
}

// ---- WebSocket framing ------------------------------------------------------

function encodeFrame(opcode, payload) {
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x80 | opcode, len]);
  } else if (len < 65536) {
    header = Buffer.from([0x80 | opcode, 126, (len >> 8) & 0xff, len & 0xff]);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}

function sendText(socket, s) { socket.write(encodeFrame(0x1, Buffer.from(s, "utf8"))); }
function sendBinary(socket, buf) { socket.write(encodeFrame(0x2, buf)); }
function sendPong(socket, payload) { socket.write(encodeFrame(0xa, payload)); }
function sendClose(socket) { socket.write(encodeFrame(0x8, Buffer.alloc(0))); }

// Parses complete frames out of an accumulating buffer. Calls handlers for each
// decoded message; returns the leftover (incomplete) bytes.
function makeFrameParser(handlers) {
  let buf = Buffer.alloc(0);
  return (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 2) {
      const fin = (buf[0] & 0x80) !== 0;
      const opcode = buf[0] & 0x0f;
      const masked = (buf[1] & 0x80) !== 0;
      let len = buf[1] & 0x7f;
      let offset = 2;
      if (len === 126) {
        if (buf.length < 4) return;
        len = buf.readUInt16BE(2); offset = 4;
      } else if (len === 127) {
        if (buf.length < 10) return;
        len = Number(buf.readBigUInt64BE(2)); offset = 10;
      }
      const maskLen = masked ? 4 : 0;
      if (buf.length < offset + maskLen + len) return;   // wait for more
      const mask = masked ? buf.slice(offset, offset + 4) : null;
      const dataStart = offset + maskLen;
      const payload = Buffer.from(buf.slice(dataStart, dataStart + len));
      if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
      buf = buf.slice(dataStart + len);

      if (opcode === 0x8) { handlers.close(); return; }
      if (opcode === 0x9) { handlers.ping(payload); continue; }
      if (opcode === 0xa) continue;                       // pong, ignore
      if (opcode === 0x1) handlers.text(payload.toString("utf8"), fin);
      else if (opcode === 0x2) handlers.binary(payload, fin);
    }
  };
}

// ---- server -----------------------------------------------------------------

const server = http.createServer((req, res) => {
  res.writeHead(426, { "Content-Type": "text/plain" });
  res.end("Upgrade required — connect over WebSocket.\n");
});

// Push cadence (ms). The SDK is exercised with one frame per second by default.
const PUSH_INTERVAL_MS = process.env.PUSH_MS ? parseInt(process.env.PUSH_MS, 10) : 1000;

server.on("upgrade", (req, socket) => {
  const key = req.headers["sec-websocket-key"];
  if (!key) { socket.destroy(); return; }
  const accept = crypto.createHash("sha1").update(key + WS_MAGIC).digest("base64");
  // Flush the 101 handshake on its own; tune the socket so loopback doesn't
  // coalesce the response with the first WS frame (some strict clients —
  // notably iOS URLSessionWebSocketTask — abort if frame bytes arrive glued to
  // the upgrade response in a single read).
  socket.setNoDelay(true);
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
    "Upgrade: websocket\r\n" +
    "Connection: Upgrade\r\n" +
    "Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
  );

  const path = (req.url || "/").split("?")[0];
  const mode = path === "/text" ? "text" : path === "/protobuf" ? "protobuf" : "both";
  console.log(`[ws] client connected (mode: ${mode}, push every ${PUSH_INTERVAL_MS}ms)`);

  let counter = 0;
  let push = null;

  const tick = () => {
    counter++;
    if (mode === "text") {
      sendText(socket, JSON.stringify({ type: "tick", counter, ts: Date.now() }));
    } else if (mode === "protobuf") {
      sendBinary(socket, buildProtobuf(counter));
    } else {
      if (counter % 2 === 0) sendText(socket, JSON.stringify({ type: "tick", counter, ts: Date.now() }));
      else sendBinary(socket, buildProtobuf(counter));
    }
  };

  // Defer the greeting + start the per-second push only after the handshake
  // has had a tick to settle, so the 101 lands in its own segment.
  setTimeout(() => {
    if (socket.destroyed) return;
    sendText(socket, JSON.stringify({ type: "welcome", mode, accessToken: "secret-should-be-redacted" }));
    push = setInterval(tick, PUSH_INTERVAL_MS);
  }, 150);

  const cleanup = () => { if (push) clearInterval(push); try { socket.destroy(); } catch (_) {} };

  const parse = makeFrameParser({
    text: (s) => { console.log("[ws] ← text:", s.slice(0, 120)); sendText(socket, JSON.stringify({ type: "echo", echo: s })); },
    binary: (b) => { console.log("[ws] ← binary:", b.length, "bytes"); sendBinary(socket, buildProtobuf(++counter)); },
    ping: (p) => sendPong(socket, p),
    close: () => { console.log("[ws] client closed"); sendClose(socket); cleanup(); },
  });

  socket.on("data", parse);
  socket.on("close", () => { console.log("[ws] socket closed"); if (push) clearInterval(push); });
  socket.on("error", cleanup);
});

server.listen(PORT, () => {
  console.log(`Xpector WS test server listening on ws://127.0.0.1:${PORT}`);
  console.log(`  /text      → JSON text frames`);
  console.log(`  /protobuf  → protobuf binary frames`);
  console.log(`  /          → both`);
});
