// Opaque relay stream E2E: registration/pairing plus byte-for-byte forwarding.
import { createServer } from "node:net";
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const port = 18445;
const base = `ws://127.0.0.1:${port}/relay/v1`;
const http = `http://127.0.0.1:${port}/relay/v1`;
const health = `http://127.0.0.1:${port}/relay/healthz`;
const id = `88${Date.now().toString().slice(-11)}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ok = (value, message) => {
  if (!value) { console.error("FAIL:", message); process.exit(1); }
  console.log("  ok:", message);
};

const binDir = mkdtempSync(join(tmpdir(), "relay-e2e-"));
const bin = join(binDir, "relay");
execFileSync("go", ["build", "-o", bin, "."], { cwd: join(import.meta.dirname, ".") });
const relay = spawn(bin, [], { env: { ...process.env, RELAY_ADDR: `:${port}` } });
for (let i = 0; i < 50; i++) {
  try { if ((await fetch(health)).status === 200) break; } catch {}
  await sleep(100);
}
ok((await fetch(health)).status === 200, "relay healthy");

const host = new WebSocket(`${base}/host`);
const hostFrames = [];
await new Promise((resolve, reject) => { host.onopen = resolve; host.onerror = reject; });
host.onmessage = (event) => hostFrames.push(JSON.parse(event.data));
host.send(JSON.stringify({ v: 1, type: "control", kind: "register", body: {
  hostId: id, hostName: "opaque-e2e", dshVersion: "test", pin: "864209",
} }));
for (let i = 0; i < 50 && !hostFrames.find((f) => f.kind === "registered"); i++) await sleep(20);
const registered = hostFrames.find((f) => f.kind === "registered");
ok(!!registered, "host registered");

const pairResponse = await fetch(`${http}/pair`, {
  method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({ deviceId: id, pin: "864209" }),
});
const pair = await pairResponse.json();
ok(pairResponse.status === 200 && pair.sessionToken, "device paired");

const device = new WebSocket(`${base}/device`, {
  headers: { Authorization: `Bearer ${pair.sessionToken}` },
});
const deviceFrames = [];
await new Promise((resolve, reject) => { device.onopen = resolve; device.onerror = reject; });
device.onmessage = (event) => deviceFrames.push(JSON.parse(event.data));

const streamId = "stream-e2e";
const original = Buffer.from([0, 1, 2, 3, 127, 128, 254, 255]);
device.send(JSON.stringify({ v: 1, type: "stream-open", streamId, port: 3080 }));
device.send(JSON.stringify({ v: 1, type: "stream-data", streamId, data: original.toString("base64") }));
for (let i = 0; i < 50 && !hostFrames.find((f) => f.type === "stream-data"); i++) await sleep(20);
const hostData = hostFrames.find((f) => f.type === "stream-data");
ok(!!hostData, "host received stream data");
ok(Buffer.from(hostData.data, "base64").equals(original), "relay preserved opaque bytes");

host.send(JSON.stringify({ v: 1, type: "stream-data", streamId, data: original.toString("base64") }));
for (let i = 0; i < 50 && !deviceFrames.find((f) => f.type === "stream-data"); i++) await sleep(20);
const deviceData = deviceFrames.find((f) => f.type === "stream-data");
ok(!!deviceData && Buffer.from(deviceData.data, "base64").equals(original), "device received opaque bytes");

device.send(JSON.stringify({ v: 1, type: "stream-close", streamId, reason: "done" }));
for (let i = 0; i < 50 && !hostFrames.find((f) => f.type === "stream-close"); i++) await sleep(20);
ok(!!hostFrames.find((f) => f.type === "stream-close"), "stream close forwarded");
host.close(); device.close(); relay.kill();
console.log("\nRELAY OPAQUE STREAM E2E PASS");
