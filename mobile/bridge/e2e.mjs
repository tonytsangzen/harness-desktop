// E2E test for the relay tunnel's chunked HTTP path, against the REAL
// bridge.mjs: bridge + relay + a fake dsh serving a large bundle.
// Asserts the device receives chunked `http-reply` parts that reassemble to
// byte-identical (gzipped) content.
//
// Run:  node mobile/bridge/e2e.mjs          (requires Go toolchain to build
//                                            the relay into a temp dir)
import { createServer } from "node:http";
import { execFile, execFileSync, spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";

const here = dirname(fileURLToPath(import.meta.url));
const relayDir = join(here, "..", "relay");
const RELAY_PORT = 18445, DSH_PORT = 3807;
const DEVICE_ID = "88" + Date.now().toString().slice(-9); // unique per run
const BASE = `ws://127.0.0.1:${RELAY_PORT}/relay/v1`;
const fail = (m) => { console.error("FAIL:", m); process.exit(1); };
const ok = (c, m) => { if (!c) fail(m); console.log("  ok:", m); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Guard against orphaned bridges from a previous crashed run fighting over
// the registration (the bridge's own single-instance guard does the same).
try { execFileSync("pkill", ["-f", `bridge\\.mjs.*--device-id ${DEVICE_ID}`]); } catch {}

// Fake dsh: a few MB of semi-compressible JS. Pure-random bytes gzip to
// >90% (the bridge rightly skips compression) and pure repeats gzip to one
// tiny chunk; unique random-hex lines gzip to ~50% AND still span several
// 192 KiB chunks, exercising both code paths in one request.
const hexOf = randomBytes(2 << 20).toString("hex"); // ~4 MB unique hex chars
const lines = [];
for (let off = 0; off + 900 < hexOf.length; off += 1024) {
  lines.push(`const mod = "${hexOf.slice(off, off + 900)}";`);
}
const big = Buffer.from(lines.join("\n")).toString("base64");
const dsh = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/javascript" });
  res.end(Buffer.from(big, "base64"));
});
await new Promise((r) => dsh.listen(DSH_PORT, "127.0.0.1", r));

// Build + start the relay (healthz-polled instead of a blind sleep).
const binDir = mkdtempSync(join(tmpdir(), "relay-e2e-"));
const relayBin = join(binDir, "relay");
execFileSync("go", ["build", "-o", relayBin, "."], { cwd: relayDir });
const relay = spawn(relayBin, [], { env: { ...process.env, RELAY_ADDR: `:${RELAY_PORT}` } });
let relayUp = false;
for (let i = 0; i < 50 && !relayUp; i++) {
  try {
    const r = await fetch(`http://127.0.0.1:${RELAY_PORT}/relay/healthz`);
    relayUp = r.status === 200;
  } catch { await sleep(200); }
}
ok(relayUp, "relay healthy");

// The real bridge.
const bridge = execFile("node", [join(here, "bridge.mjs"), "--relay", `ws://127.0.0.1:${RELAY_PORT}`,
  "--dsh-port", String(DSH_PORT), "--device-id", DEVICE_ID, "--host-name", "bridge-e2e",
  // The default 13080 may be taken by a real running app on this machine.
  "--lan-port", "23180"]);
let pin = null;
bridge.stdout.on("data", (d) => {
  for (const line of d.toString().split("\n")) {
    try { const j = JSON.parse(line); if (j.event === "registered") pin = j.pin; } catch {}
  }
});
for (let i = 0; i < 60 && !pin; i++) await sleep(100);
ok(!!pin, "bridge registered, got pin");

// Pair a device and connect.
const pairRes = await fetch(`http://127.0.0.1:${RELAY_PORT}/relay/v1/pair`, {
  method: "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ deviceId: DEVICE_ID, pin }),
});
const pair = await pairRes.json();
ok(!!pair.sessionToken, "paired");

const dev = new WebSocket(`${BASE}/device`, { headers: { Authorization: `Bearer ${pair.sessionToken}` } });
await new Promise((r, j) => { dev.onopen = r; dev.onerror = j; });
const frames = [];
dev.onmessage = (e) => frames.push(JSON.parse(e.data));

// Request the big bundle through the tunnel and collect the reply parts.
dev.send(JSON.stringify({ v: 1, type: "http", id: "big1", channel: "ch1", method: "GET", path: "/assets/big.js", body: {} }));
let parts = [];
for (let i = 0; i < 200; i++) {
  await sleep(50);
  parts = frames.filter((f) => f.type === "http-reply" && f.id === "big1");
  if (parts.length > 0 && parts.length >= (parts[0].body?.part?.total ?? 1)) break;
}
ok(parts.length > 1, `chunked into ${parts.length} parts`);
const total = parts[0].body.part.total;
ok(parts.length === total, "all parts arrived");
ok(parts[0].status === 200 && parts[0].body.headers["content-type"] === "text/javascript",
  "status + content-type ride on part 0");
ok(parts.every((f, i) => f.body.part.index === i), "parts in order");
const wire = Buffer.from(parts.map((f) => f.body.body).join(""), "base64");
// The wire body is the gzipped payload — exactly what the phone's WebView
// receives before it decodes content-encoding itself.
ok(parts[0].body.headers["content-encoding"] === "gzip", "gzip content-encoding preserved");
const orig = (await import("node:zlib")).gunzipSync(wire);
ok(orig.equals(Buffer.from(big, "base64")), `gunzipped ${orig.length} bytes identical to original`);

bridge.kill();
relay.kill();
dsh.close();
console.log("\nBRIDGE-E2E PASS");
process.exit(0);
