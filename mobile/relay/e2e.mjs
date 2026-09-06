// E2E smoke test for the mobile relay (protocol spec docs/mobile-relay-protocol.md).
// Simulates: Host register -> pair -> Device connect -> rpc round-trip -> sse flow.
// Requires Node >= 22 (global WebSocket) and the relay on :8443.
const BASE = "ws://127.0.0.1:8443/relay/v1";
const HTTP = "http://127.0.0.1:8443/relay/v1";

function fail(msg) {
  console.error("FAIL:", msg);
  process.exit(1);
}
const ok = (cond, msg) => { if (!cond) fail(msg); console.log("  ok:", msg); };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- 0. Health ---
const hz = await fetch("http://127.0.0.1:8443/relay/healthz");
ok(hz.status === 200 && (await hz.text()) === "ok", "relay/healthz ok");

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
// Error codes are intentionally unified (pair-invalid) so the pair endpoint
// can't be used to probe whether a hostId exists or a ticket is spent.
ok(reuseRes.status === 409 && reuseBody.error?.code === "pair-invalid", "pair ticket single-use");

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
// Node's WebSocket fires only `onerror` (non-101) for a 401 handshake, so
// accept either signal; the point is that no usable tunnel is established.
const badDev = new WebSocket(`${BASE}/device`, { headers: { Authorization: "Bearer nope" } });
let badRejected = false;
let badStatus = 0;
await new Promise((res) => {
  badDev.onerror = () => { badRejected = true; res(); };
  badDev.onclose = (e) => { badRejected = true; badStatus = e.code; res(); };
  setTimeout(res, 1500);
});
ok(badRejected, `bad token rejected (close ${badStatus})`);

// --- 7. Chunked http-reply passes through the relay ---
const httpId = "http_e2e", httpCh = "ch_e2e3";
devWs.send(JSON.stringify({
  v: 1, type: "http", id: httpId, channel: httpCh, method: "GET", path: "/assets/big.js",
  body: {},
}));
let hostGotHttp;
for (let i = 0; i < 50 && !hostGotHttp; i++) {
  await sleep(50);
  hostGotHttp = hostFrames.find((f) => f.type === "http" && f.id === httpId);
}
ok(!!hostGotHttp, "host received http frame");

// Host answers with 3 chunk parts (headers on part 0), like bridge.mjs.
const partData = ["QUFB", "QkJC", "Q0ND"]; // base64("AAA"), ("BBB"), ("CCC")
partData.forEach((b64, i) => {
  hostWs.send(JSON.stringify({
    v: 1, type: "http-reply", channel: httpCh, id: httpId, status: 200,
    body: {
      ...(i === 0 ? { headers: { "content-type": "text/javascript" } } : {}),
      body: b64,
      part: { index: i, total: partData.length },
    },
  }));
});
let devHttpParts = [];
for (let i = 0; i < 100 && devHttpParts.length < 3; i++) {
  await sleep(50);
  devHttpParts = devFrames.filter((f) => f.type === "http-reply" && f.id === httpId);
}
ok(devHttpParts.length === 3, `device received all ${devHttpParts.length}/3 http-reply parts`);
ok(devHttpParts.every((f, i) => f.body?.part?.index === i), "parts arrived in order with index");
ok(devHttpParts[0].status === 200 && devHttpParts[0].body.headers["content-type"] === "text/javascript",
  "part 0 carries status + headers");
ok(Buffer.from(devHttpParts.map((f) => f.body.body).join(""), "base64").toString() === "AAABBBCCC",
  "reassembled body matches");

// --- 8. Zombie host tunnel takeover via persisted token ---
// With RELAY_STALE_HOST_AFTER small, a token-authenticated reconnect takes
// over a tunnel that stopped answering pings instead of being refused for
// DeadAfter (90s) — that stale window showed up as "host offline" flakiness.
await sleep(1600);
let host2Closed = new Promise((res) => { hostWs.onclose = (e) => res(e); });
const hostFramesBefore = hostFrames.length;
const host2 = new WebSocket(`${BASE}/host`, { headers: { Authorization: `Bearer ${hostToken}` } });
await new Promise((res, rej) => { host2.onopen = res; host2.onerror = rej; });
host2.onmessage = (e) => hostFrames.push(JSON.parse(e.data));
const oldClose = await Promise.race([host2Closed, sleep(3000).then(() => null)]);
ok(!!oldClose, `stale host tunnel kicked (code ${oldClose?.code ?? "?"})`);
// Token reconnect restores the tunnel silently — no fresh `registered`.
ok(!hostFrames.slice(hostFramesBefore).some((f) => f.type === "control" && f.kind === "registered"),
  "token reconnect needs no re-register");

// The live host is now host2: device rpc must route to it.
devWs.send(JSON.stringify({
  v: 1, type: "rpc", channel: "ch_e2e4", rpcId: "rpc_e2e2",
  path: "/api/session.list", body: {},
}));
let host2GotRpc;
for (let i = 0; i < 100 && !host2GotRpc; i++) {
  await sleep(50);
  host2GotRpc = hostFrames.find((f) => f.type === "rpc" && f.rpcId === "rpc_e2e2");
}
ok(!!host2GotRpc, "device traffic routes to the takeover connection");

// --- 9. Anonymous re-register with the fixed PIN (token recovery) ---
// A client that loses its hostToken (app reinstall) must be able to reclaim
// its hostId with the fixed PIN — otherwise the host is locked out for the
// whole GC window. Wrong PIN is still refused.
const host3 = new WebSocket(`${BASE}/host`);
await new Promise((res, rej) => { host3.onopen = res; host3.onerror = rej; });
host3.onmessage = (e) => hostFrames.push(JSON.parse(e.data));
host3.send(JSON.stringify({
  v: 1, type: "control", kind: "register",
  body: { hostId: "1234567890999", hostName: "PinHost", dshVersion: "0.0.0-test", pin: "864209" },
}));
let pinHost3;
for (let i = 0; i < 50 && !pinHost3; i++) {
  await sleep(50);
  pinHost3 = hostFrames.find((f) => f.type === "control" && f.kind === "registered");
}
ok(!!pinHost3, "fixed-pin host registered");
const host3Close = new Promise((res) => { host3.onclose = res; });

// Same hostId, correct PIN, no token -> accepted.
const host4 = new WebSocket(`${BASE}/host`);
await new Promise((res, rej) => { host4.onopen = res; host4.onerror = rej; });
host4.onmessage = (e) => hostFrames.push(JSON.parse(e.data));
host4.send(JSON.stringify({
  v: 1, type: "control", kind: "register",
  body: { hostId: "1234567890999", hostName: "PinHost2", dshVersion: "0.0.0-test", pin: "864209" },
}));
let host4Reg;
for (let i = 0; i < 50 && !host4Reg; i++) {
  await sleep(50);
  host4Reg = hostFrames.find((f) => f.type === "control" && f.kind === "registered");
}
ok(!!host4Reg, "re-register with matching PIN accepted");

// Wrong PIN -> refused.
const host5 = new WebSocket(`${BASE}/host`);
await new Promise((res, rej) => { host5.onopen = res; host5.onerror = rej; });
host5.send(JSON.stringify({
  v: 1, type: "control", kind: "register",
  body: { hostId: "1234567890999", hostName: "PinHost3", dshVersion: "0.0.0-test", pin: "918273" },
}));
let host5Denied = false;
host5.onmessage = (e) => {
  const f = JSON.parse(e.data);
  if (f.type === "control" && f.kind === "register-denied") host5Denied = true;
};
host5.onclose = () => { host5Denied = true; };
for (let i = 0; i < 50 && !host5Denied; i++) await sleep(50);
ok(host5Denied, "wrong PIN refused (host-conflict)");

host3.close();
host4.close();
host5.close();
devWs.close();
console.log("\nE2E PASS");
process.exit(0);
