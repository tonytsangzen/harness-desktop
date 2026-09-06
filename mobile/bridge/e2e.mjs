// Bridge E2E: the bridge forwards arbitrary TCP bytes to a local port.
import { createServer, connect } from "node:net";
import { execFile, execFileSync, spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const relayPort = 18446;
const dshPort = 18447;
const lanPort = 18448;
const deviceId = `77${Date.now().toString().slice(-11)}`;
const base = `ws://127.0.0.1:${relayPort}/relay/v1`;
const http = `http://127.0.0.1:${relayPort}/relay/v1`;
const health = `http://127.0.0.1:${relayPort}/relay/healthz`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ok = (value, message) => {
  if (!value) { console.error("FAIL:", message); process.exit(1); }
  console.log("  ok:", message);
};
const bytes = Buffer.from([0, 1, 2, 3, 127, 128, 254, 255]);

const dsh = createServer((socket) => socket.on("data", (data) => socket.write(data)));
await new Promise((resolve) => dsh.listen(dshPort, "127.0.0.1", resolve));
const relayBin = join(mkdtempSync(join(tmpdir(), "relay-bridge-e2e-")), "relay");
execFileSync("go", ["build", "-o", relayBin, "."], { cwd: join(here, "../relay") });
const relay = spawn(relayBin, [], { env: { ...process.env, RELAY_ADDR: `:${relayPort}` } });
for (let i = 0; i < 50; i++) {
  try { if ((await fetch(health)).status === 200) break; } catch {}
  await sleep(100);
}

const bridge = execFile("node", [join(here, "bridge.mjs"), "--relay", `ws://127.0.0.1:${relayPort}`,
  "--dsh-port", String(dshPort), "--device-id", deviceId, "--host-name", "bridge-e2e",
  "--lan-port", String(lanPort)]);
let pin;
bridge.stdout.on("data", (data) => {
  for (const line of data.toString().split("\n")) {
    try { const event = JSON.parse(line); if (event.event === "registered") pin = event.pin; } catch {}
  }
});
for (let i = 0; i < 60 && !pin; i++) await sleep(50);
ok(!!pin, "bridge registered");
const pairResponse = await fetch(`${http}/pair`, {
  method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({ deviceId, pin }),
});
const pair = await pairResponse.json();
ok(pairResponse.status === 200, "device paired");
const device = new WebSocket(`${base}/device`, {
  headers: { Authorization: `Bearer ${pair.sessionToken}` },
});
const frames = [];
await new Promise((resolve, reject) => { device.onopen = resolve; device.onerror = reject; });
device.onmessage = (event) => frames.push(JSON.parse(event.data));

const id = "bridge-stream";
device.send(JSON.stringify({ v: 1, type: "stream-open", streamId: id, port: dshPort }));
device.send(JSON.stringify({ v: 1, type: "stream-data", streamId: id, data: bytes.toString("base64") }));
for (let i = 0; i < 100 && !frames.find((f) => f.type === "stream-data"); i++) await sleep(20);
const response = frames.find((f) => f.type === "stream-data");
ok(!!response, "remote stream reached local TCP port");
ok(Buffer.from(response.data, "base64").equals(bytes), "local TCP response preserved bytes");

const lan = await new Promise((resolve, reject) => {
  const socket = connect(lanPort, "127.0.0.1");
  const chunks = [];
  socket.on("connect", () => socket.write(bytes));
  socket.on("data", (data) => {
    chunks.push(data);
    socket.destroy();
    resolve(Buffer.concat(chunks));
  });
  socket.on("error", reject);
  setTimeout(() => reject(new Error("LAN echo timeout")), 2000);
});
ok(lan.equals(bytes), "LAN port uses the same opaque forwarder");

device.close(); bridge.kill(); relay.kill(); dsh.close();
console.log("\nBRIDGE OPAQUE TCP E2E PASS");
