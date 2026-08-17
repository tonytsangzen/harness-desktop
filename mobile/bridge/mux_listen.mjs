import WebSocket from "ws";
let hits = { a: 0, b: 0 };
const msgA = [], msgB = [];
function mk(label, arr) {
  const ws = new WebSocket("ws://127.0.0.1:3080/api/events.mux");
  ws.on("message", (d) => {
    const s = String(d);
    if (s.includes("assistant/message") || s.includes("session/event")) {
      arr.push({ t: new Date().toISOString().slice(11, 19), s: s.slice(0, 140) });
      hits[label]++;
    }
  });
  return ws;
}
const a = mk("A", msgA), b = mk("B", msgB);
console.log("LISTENING: two WS on events.mux. Please send a chat message on the phone OR desktop now.");
setTimeout(() => {
  console.log("A hits=" + hits.a, "B hits=" + hits.b);
  console.log("A samples:", JSON.stringify(msgA.slice(-3)));
  console.log("B samples:", JSON.stringify(msgB.slice(-3)));
  a.close(); b.close();
  const okA = hits.a > 0, okB = hits.b > 0;
  console.log(okA && okB ? "RESULT: BROADCAST_OK" : (hits.a + hits.b > 0 ? "RESULT: ONE_SIDE_ONLY" : "RESULT: NO_MESSAGE"));
  process.exit(0);
}, 45000);
