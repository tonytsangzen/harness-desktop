// E2E smoke test for the mobile relay (protocol spec docs/mobile-relay-protocol.md).
// Simulates: Host register -> pair -> Device connect -> rpc round-trip -> sse flow.
// Requires Node >= 22 (global WebSocket) and the relay on :8443.
const BASE = "ws://127.0.0.1:8443/relay/v1";
const HTTP = "http://127.0.0.1:8443/relay/v1";

// --- 0. Health ---
const hz = await fetch("http://127.0.0.1:8443/relay/healthz");
ok(hz.status === 200 && (await hz.text()) === "ok", "relay/healthz ok");


function fail(msg) {
  console.error("FAIL:", msg);
  process.exit(1);
}
const ok = (cond, msg) => { if (!cond) fail(msg); console.log("  ok:", msg); };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- 1. Host register ---
const hostWs = new WebSocket(`${BASE}/host`);
const hostFrames = [];
let hostOpen = new Promise((res) => { hostWs.onopen = res; });
await hostOpen;
hostWs.onmessage = (e) => hostFrames.push(JSON.parse(e.data));

hostWs.send(JSON.stringify({
  v: 1, type: "control", kind: "register",
  body: { hostId: "1234567890123", hostName: "Test-Mac", dshVersion: "0.0.0-test" },
}));

let registered;
for (let i = 0; i < 50 && !registered; i++) {
  await sleep(50);
  registered = hostFrames.find((f) => f.type === "control" && f.kind === "registered");
}
ok(!!registered, "host registered, got hostId+pin");
const { hostToken, pin, hostId } = registered.body;
ok(hostId === "1234567890123", "hostId honors the shell-provided device ID");
ok(!("pairToken" in registered.body), "no pairToken in registered (pair uses deviceId)");

// --- 2. Pair (HTTP) ---
// Wrong PIN must fail with pair-invalid (before the ticket is consumed).
const badRes = await fetch(`${HTTP}/pair`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ deviceId: hostId, pin: "000000" }),
});
const badBody = await badRes.json();
ok(badRes.status === 409 && badBody.error?.code === "pair-invalid", `bad PIN -> ${badBody.error?.code}`);

const pairRes = await fetch(`${HTTP}/pair`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ deviceId: hostId, pin }),
});
ok(pairRes.status === 200, `pair HTTP ${pairRes.status}`);
const pair = await pairRes.json();
ok(pair.sessionToken && pair.deviceId, "session token issued");

// Correct PIN again: same host pair ticket now used once.
const reuseRes = await fetch(`${HTTP}/pair`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ deviceId: hostId, pin }),
});
const reuseBody = await reuseRes.json();
ok(reuseRes.status === 409 && reuseBody.error?.code === "pair-used", "pair ticket single-use");

// --- 3. Device connect + rpc round trip ---
const devWs = new WebSocket(`${BASE}/device`, { headers: { Authorization: `Bearer ${pair.sessionToken}` } });
const devFrames = [];
await new Promise((res, rej) => { devWs.onopen = res; devWs.onerror = (e) => rej(new Error("device ws error")); });
devWs.onmessage = (e) => devFrames.push(JSON.parse(e.data));

const ch = "ch_e2e1", rpcId = "rpc_e2e1";
devWs.send(JSON.stringify({
  v: 1, type: "rpc", channel: ch, rpcId,
  path: "/api/session.list", body: { rpcId, type: "request", payload: {} },
}));

// Host side should receive the rpc frame.
let hostGotRpc;
for (let i = 0; i < 50 && !hostGotRpc; i++) {
  await sleep(50);
  hostGotRpc = hostFrames.find((f) => f.type === "rpc" && f.rpcId === rpcId);
}
ok(!!hostGotRpc, "host received rpc frame");
ok(hostGotRpc.path === "/api/session.list", "rpc path preserved");

// Host replies (simulating dsh web).
hostWs.send(JSON.stringify({
  v: 1, type: "rpc-reply", channel: ch, rpcId,
  body: { result: { items: [{ sessionId: "s_1", running: true, updatedAt: 1 }] } },
}));

let devGotReply;
for (let i = 0; i < 50 && !devGotReply; i++) {
  await sleep(50);
  devGotReply = devFrames.find((f) => f.type === "rpc-reply" && f.rpcId === rpcId);
}
ok(!!devGotReply, "device received rpc-reply");
ok(devGotReply.body.result.items[0].running === true, "reply payload intact");

// --- 4. SSE flow ---
const sseCh = "ch_e2e2";
devWs.send(JSON.stringify({ v: 1, type: "sse-open", channel: sseCh, path: "/api/events.mux", body: {} }));
let hostGotSse;
for (let i = 0; i < 50 && !hostGotSse; i++) {
  await sleep(50);
  hostGotSse = hostFrames.find((f) => f.type === "sse-open" && f.channel === sseCh);
}
ok(!!hostGotSse, "host received sse-open");

hostWs.send(JSON.stringify({
  v: 1, type: "sse-frame", channel: sseCh,
  body: { event: "session/event", data: JSON.stringify({ type: "step/start", data: {} }) },
}));
let devGotSse;
for (let i = 0; i < 50 && !devGotSse; i++) {
  await sleep(50);
  devGotSse = devFrames.find((f) => f.type === "sse-frame" && f.channel === sseCh);
}
ok(!!devGotSse, "device received sse-frame");

// --- 5. Ping/pong keeps alive ---
const pongSeen = new Promise((res) => {
  const t = setInterval(() => {
    const p = devFrames.find((f) => f.type === "pong");
    if (p) { clearInterval(t); res(true); }
  }, 50);
});
setTimeout(() => devWs.send(JSON.stringify({ v: 1, type: "ping" })), 100);
ok(await pongSeen, "ping/pong");

// --- 6. Device auth: bad token rejected ---
const badDev = new WebSocket(`${BASE}/device`, { headers: { Authorization: "Bearer nope" } });
let badStatus = 0;
await new Promise((res) => {
  badDev.onerror = res; badDev.onclose = (e) => { badStatus = e.code; res(); };
  setTimeout(res, 1500);
});
ok(badStatus !== 0, `bad token rejected (close ${badStatus})`);

hostWs.close();
devWs.close();
console.log("\nE2E PASS");
process.exit(0);
