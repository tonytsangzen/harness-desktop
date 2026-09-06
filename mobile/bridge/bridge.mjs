#!/usr/bin/env node
// dsh-mobile-bridge: authenticated opaque TCP port bridge.
// The relay only transports stream frames. This process connects each remote
// stream to the configured local TCP port without parsing dsh traffic.
import { createConnection, createServer } from "node:net";
import { hostname } from "node:os";
import { parseArgs } from "node:util";
import { execFileSync } from "node:child_process";
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

function emit(event, extra = {}) { console.log(JSON.stringify({ event, ...extra })); }
function isOpen() { return ws && ws.readyState === WebSocket.OPEN; }
function send(frame) { if (isOpen()) ws.send(JSON.stringify(frame)); }

try {
  const out = execFileSync("pgrep", ["-f", `bridge\\.mjs.*--device-id ${deviceId}`], { encoding: "utf8" });
  for (const value of out.trim().split(/\s+/)) {
    const pid = Number(value);
    if (pid && pid !== process.pid) { try { process.kill(pid, "SIGKILL"); } catch {} }
  }
} catch {}

function closeStream(id, reason = "closed") {
  const socket = streams.get(id);
  if (!socket) return;
  streams.delete(id);
  socket.destroy();
  send({ v: 1, type: "stream-close", streamId: id, reason });
}

function handleStreamOpen(frame) {
  if (!frame.streamId || frame.port !== dshPort) {
    send({ v: 1, type: "stream-close", streamId: frame.streamId || "", reason: "port-not-exposed" });
    return;
  }
  const socket = createConnection({ host: dshHost, port: dshPort });
  streams.set(frame.streamId, socket);
  socket.on("connect", () => emit("stream-open", { streamId: frame.streamId }));
  socket.on("data", (data) => send({ v: 1, type: "stream-data", streamId: frame.streamId, data: Buffer.from(data).toString("base64") }));
  socket.on("end", () => closeStream(frame.streamId, "eof"));
  socket.on("close", () => { if (streams.get(frame.streamId) === socket) closeStream(frame.streamId, "closed"); });
  socket.on("error", (error) => closeStream(frame.streamId, String(error.code || "connect-error")));
}

function handleFrame(frame) {
  switch (frame.type) {
    case "ping": send({ v: 1, type: "pong" }); break;
    case "stream-open": handleStreamOpen(frame); break;
    case "stream-data": {
      const socket = streams.get(frame.streamId);
      if (socket && frame.data) socket.write(Buffer.from(frame.data, "base64"));
      break;
    }
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
