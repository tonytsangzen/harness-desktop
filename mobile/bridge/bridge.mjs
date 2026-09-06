#!/usr/bin/env node
// dsh-mobile-bridge: authenticated opaque TCP port bridge.
// The relay only transports stream frames. This process connects each remote
// stream to the configured local TCP port without parsing dsh traffic.
//
// End-to-end privacy (optional, --e2e-secret): stream payloads between the
// bridge and the app are sealed with AES-256-GCM under a key derived from a
// secret the pairing QR carries to the phone out-of-band, so the relay only
// ever sees ciphertext, stream ids and sizes. Records also deflate-compress
// and coalesce small TCP reads, and independent streams are aggregated into
// single `stream-batch` frames. Peers negotiate via a HELLO record injected
// as the first payload of every stream; without the secret (or with a legacy
// peer) everything stays byte-for-byte plaintext.
import { createConnection, createServer } from "node:net";
import { hostname } from "node:os";
import { parseArgs } from "node:util";
import { execFileSync } from "node:child_process";
import { createCipheriv, createDecipheriv, hkdfSync } from "node:crypto";
import { deflateRawSync, inflateRawSync } from "node:zlib";
import { WebSocket } from "ws";

const args = parseArgs({ options: {
  relay: { type: "string", required: true },
  "dsh-host": { type: "string", default: "127.0.0.1" },
  "dsh-port": { type: "string", default: "3080" },
  "host-name": { type: "string", default: hostname() },
  "device-id": { type: "string", default: "" },
  pin: { type: "string", default: "" },
  "host-token": { type: "string", default: "" },
  "lan-port": { type: "string", default: "13080" },
  "e2e-secret": { type: "string", default: "" },
} });

const relay = (() => {
  let value = args.values.relay.replace(/\/$/, "");
  if (value.startsWith("https://")) return "wss://" + value.slice(8);
  if (value.startsWith("http://")) return "ws://" + value.slice(7);
  return value.startsWith("ws://") || value.startsWith("wss://") ? value : "wss://" + value;
})();
const dshHost = args.values["dsh-host"];
const dshPort = Number(args.values["dsh-port"]);
const deviceId = args.values["device-id"] || "";
let hostToken = args.values["host-token"] || null;
let ws;
let backoff = 1000;
let registered = false;
const streams = new Map();

// --- E2E record codec -------------------------------------------------------
// record = "E2E1" | flags | nonce(12) | AES-256-GCM ciphertext(+tag 16)
// nonce  = direction(4 BE: 1=bridge->device, 2=device->bridge) | counter(8 BE)
// plaintext = deflate-raw?(raw stream bytes)  (flags bit0)
// AAD = magic | flags. Counters are per direction (connection-scoped).
const MAGIC = Buffer.from([0x45, 0x32, 0x45, 0x31]);
const FLAG_DEFLATE = 1;
const FLAG_BATCH = 2; // peer aggregates into stream-batch frames
const DIR_BRIDGE = 1;
const DIR_DEVICE = 2;

function e2eKey(secret, hostId) {
  return Buffer.from(hkdfSync("sha256", Buffer.from(secret, "base64url"), Buffer.from(hostId, "utf8"), Buffer.from("dsh-e2e-v1", "utf8"), 32));
}
const hasSecret = !!args.values["e2e-secret"];
const e2e = hasSecret ? { key: e2eKey(args.values["e2e-secret"], deviceId) } : null;

function seal(key, dir, seq, plain) {
  const nonce = Buffer.alloc(12);
  nonce.writeUInt32BE(dir, 0);
  nonce.writeBigUInt64BE(BigInt(seq), 4);
  let flags = FLAG_BATCH, body = plain;
  if (plain.length >= 64) {
    const deflated = deflateRawSync(plain);
    if (deflated.length < plain.length) {
      flags |= FLAG_DEFLATE;
      body = deflated;
    }
  }
  const cipher = createCipheriv("aes-256-gcm", key, nonce, { authTagLength: 16 });
  cipher.setAAD(Buffer.concat([MAGIC, Buffer.from([flags])]));
  const ct = Buffer.concat([cipher.update(body), cipher.final(), cipher.getAuthTag()]);
  return Buffer.concat([MAGIC, Buffer.from([flags]), nonce, ct]);
}

function open(key, dir, record) {
  if (record.length < 4 + 1 + 12 + 16 || !record.subarray(0, 4).equals(MAGIC)) return null;
  const flags = record[4];
  const nonce = record.subarray(5, 17);
  const tagged = record.subarray(17);
  const decipher = createDecipheriv("aes-256-gcm", key, nonce, { authTagLength: 16 });
  decipher.setAAD(Buffer.concat([MAGIC, Buffer.from([flags])]));
  decipher.setAuthTag(tagged.subarray(tagged.length - 16));
  let body;
  try {
    body = Buffer.concat([decipher.update(tagged.subarray(0, tagged.length - 16)), decipher.final()]);
  } catch {
    return null; // wrong key / corrupted / replayed record
  }
  if (flags & FLAG_DEFLATE) body = inflateRawSync(body);
  return { flags, body };
}

// --- Per-stream coalescing + cross-stream aggregation -----------------------
const FLUSH_MS = 4;          // coalesce window per stream
const BATCH_MS = 3;          // aggregation window across streams
const FLUSH_BYTES = 48 * 1024;
const BATCH_ITEMS = 24;
let batchItems = [];
let batchTimer = null;

function queueBatchItem(item) {
  batchItems.push(item);
  if (batchItems.length >= BATCH_ITEMS || item.d.length >= FLUSH_BYTES) {
    flushBatch();
    return;
  }
  if (!batchTimer) {
    batchTimer = setTimeout(flushBatch, BATCH_MS);
  }
}

function flushBatch() {
  if (batchTimer) { clearTimeout(batchTimer); batchTimer = null; }
  if (!batchItems.length) return;
  if (batchItems.length === 1) {
    const one = batchItems.pop();
    send({ v: 1, type: "stream-data", streamId: one.id, data: one.d });
    return;
  }
  send({ v: 1, type: "stream-batch", items: batchItems });
  batchItems = [];
}

// A stream's outbound path: dsh bytes -> (coalesce) -> sealed record ->
// batch queue. Inbound: records/batches -> unseal -> dsh socket.
function makeStream(id, socket) {
  const state = {
    id,
    socket,
    txSeq: 0,
    rxSeq: 0,
    mode: "pending", // pending -> enc (we have a secret) | plain (legacy peer)
    pending: [],
    pendingBytes: 0,
    timer: null,
  };

  state.flush = () => {
    if (state.timer) { clearTimeout(state.timer); state.timer = null; }
    if (!state.pending.length) return;
    const body = Buffer.concat(state.pending);
    state.pending = [];
    state.pendingBytes = 0;
    const d = e2e
      ? seal(e2e.key, DIR_BRIDGE, state.txSeq++, body).toString("base64")
      : body.toString("base64");
    queueBatchItem({ id, d });
  };
  state.coalesce = (data) => {
    state.pending.push(data);
    state.pendingBytes += data.length;
    if (state.pendingBytes >= FLUSH_BYTES) {
      state.flush();
      return;
    }
    if (!state.timer) state.timer = setTimeout(state.flush, FLUSH_MS);
  };
  socket.on("data", (data) => {
    if (e2e) {
      state.coalesce(data); // coalesce + seal + aggregate
    } else {
      // Legacy mode stays frame-per-read: old apps know no stream-batch.
      send({ v: 1, type: "stream-data", streamId: id, data: data.toString("base64") });
    }
  });
  return state;
}

function e2eInbound(state, payload) {
  // Returns the plaintext bytes to write to dsh, or null when the payload
  // was consumed (HELLO) or must be dropped.
  const sealed = payload.length >= 17 && payload.subarray(0, 4).equals(MAGIC);
  const decoded = sealed ? open(e2e.key, DIR_DEVICE, payload) : null;
  if (sealed && !decoded) {
    // Sealed but undecryptable: wrong key or tampered — never feed dsh.
    closeStream(state.id, "e2e-broken");
    return null;
  }
  if (decoded) {
    if (state.mode !== "enc") {
      state.mode = "enc";
      // Answer the peer's HELLO exactly once so it learns we understand
      // E2E + batching. Sent directly: already sealed, never re-sealed.
      queueBatchItem({
        id: state.id,
        d: seal(e2e.key, DIR_BRIDGE, state.txSeq++, Buffer.alloc(0)).toString("base64"),
      });
    }
    if (decoded.body.length === 0) return null; // HELLO
    return decoded.body;
  }
  if (state.mode === "enc") {
    closeStream(state.id, "e2e-broken");
    return null;
  }
  if (state.mode === "pending") state.mode = "plain"; // legacy peer
  return payload;
}

function emit(event, extra = {}) { console.log(JSON.stringify({ event, ...extra })); }
function isOpen() { return ws && ws.readyState === WebSocket.OPEN; }
function send(frame) {
  if (frame.type !== "pong") console.log(JSON.stringify({ event: "send", type: frame.type, id: frame.streamId, len: (frame.data || "").length, items: (frame.items || []).length }));
  if (isOpen()) ws.send(JSON.stringify(frame));
}

try {
  const out = execFileSync("pgrep", ["-f", `bridge\\.mjs.*--device-id ${deviceId}`], { encoding: "utf8" });
  for (const value of out.trim().split(/\s+/)) {
    const pid = Number(value);
    if (pid && pid !== process.pid) { try { process.kill(pid, "SIGKILL"); } catch {} }
  }
} catch {}

function closeStream(id, reason = "closed") {
  const state = streams.get(id);
  if (!state) return;
  streams.delete(id);
  state.flush();
  flushBatch();
  state.socket.destroy();
  send({ v: 1, type: "stream-close", streamId: id, reason });
}

function handleInboundPayload(streamId, payload) {
  const state = streams.get(streamId);
  if (!state) return;
  const plain = e2eInbound(state, payload);
  if (plain && plain.length) state.socket.write(plain);
}

function handleStreamOpen(frame) {
  if (!frame.streamId || frame.port !== dshPort) {
    send({ v: 1, type: "stream-close", streamId: frame.streamId || "", reason: "port-not-exposed" });
    return;
  }
  const socket = createConnection({ host: dshHost, port: dshPort });
  const state = makeStream(frame.streamId, socket);
  streams.set(frame.streamId, state);
  if (e2e) {
    // HELLO as the very first payload announces this side's capabilities;
    // the phone strips it before the WebView sees anything. Sent directly —
    // it is already sealed and must not run through the coalescing flush.
    queueBatchItem({
      id: frame.streamId,
      d: seal(e2e.key, DIR_BRIDGE, state.txSeq++, Buffer.alloc(0)).toString("base64"),
    });
  }
  socket.on("connect", () => emit("stream-open", { streamId: frame.streamId }));
  socket.on("end", () => closeStream(frame.streamId, "eof"));
  socket.on("close", () => { if (streams.get(frame.streamId) === state) closeStream(frame.streamId, "closed"); });
  socket.on("error", (error) => closeStream(frame.streamId, String(error.code || "connect-error")));
}

function handleFrame(frame) {
  switch (frame.type) {
    case "ping": send({ v: 1, type: "pong" }); break;
    case "stream-open": handleStreamOpen(frame); break;
    case "stream-data":
      handleInboundPayload(frame.streamId, Buffer.from(frame.data || "", "base64"));
      break;
    case "stream-batch":
      for (const item of frame.items || []) {
        handleInboundPayload(item.id, Buffer.from(item.d || "", "base64"));
      }
      break;
    case "stream-close": closeStream(frame.streamId, frame.reason || "peer-closed"); break;
    case "control":
      if (frame.kind === "registered") {
        hostToken = frame.body?.hostToken || hostToken;
        registered = true;
        emit("registered", frame.body || {});
      } else if (frame.kind === "unknown-host") sendRegister();
      break;
  }
}

function sendRegister() {
  send({ v: 1, type: "control", kind: "register", body: {
    hostId: deviceId, hostName: args.values["host-name"],
    dshVersion: process.env.DSH_VERSION || "unknown",
    ...(args.values.pin ? { pin: args.values.pin } : {}),
    ...(hostToken ? { token: hostToken } : {}),
  }});
}

function connect() {
  ws = new WebSocket(new URL("/relay/v1/host", relay), hostToken ? { headers: { Authorization: `Bearer ${hostToken}` } } : undefined);
  ws.onopen = () => { backoff = 1000; if (hostToken) emit("online"); else sendRegister(); };
  ws.onmessage = (event) => { try { handleFrame(JSON.parse(event.data)); } catch {} };
  ws.onclose = () => {
    for (const id of streams.keys()) closeStream(id, "relay-closed");
    streams.clear();
    if (registered) emit("offline");
    setTimeout(connect, backoff);
    backoff = Math.min(backoff * 2, 10000);
  };
  ws.onerror = () => { if (!registered) emit("relay-unreachable", { relay }); };
}

// LAN exposure uses the same raw TCP forwarder; it does not inspect HTTP or
// WebSocket headers, keeping LAN and relay behavior identical.
const lanPort = Number(args.values["lan-port"]) || 13080;
createServer((socket) => {
  const upstream = createConnection({ host: dshHost, port: dshPort });
  socket.pipe(upstream);
  upstream.pipe(socket);
  socket.on("error", () => upstream.destroy());
  upstream.on("error", () => socket.destroy());
}).listen(lanPort, "0.0.0.0", () => emit("lan-ready", { port: lanPort }))
  .on("error", (error) => emit("lan-port-error", { port: lanPort, error: String(error.code || error) }));

connect();
