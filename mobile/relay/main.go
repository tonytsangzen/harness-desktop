// Package main implements the Mobile Relay (protocol spec docs/mobile-relay-protocol.md):
// WSS host/device tunnels + control plane (register/pair/refresh/revoke) with
// channel multiplexed forwarding between a host bridge and phone devices.
package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/tonytsangzen/harness-desktop/mobile/relay/store"
)

// Frame is the wire frame shared by both tunnels (spec §3).
type Frame struct {
	V       int             `json:"v"`
	Type    string          `json:"type"`
	Kind    string          `json:"kind,omitempty"`
	Channel string          `json:"channel,omitempty"`
	RpcID   string          `json:"rpcId,omitempty"`
	ID      string          `json:"id,omitempty"`
	Status  int             `json:"status,omitempty"`
	Method  string          `json:"method,omitempty"`
	Path    string          `json:"path,omitempty"`
	Body    json.RawMessage `json:"body,omitempty"`
}

const (
	PingInterval = 30 * time.Second
	DeadAfter    = 90 * time.Second

	// maxFrameBytes bounds one WebSocket message (base64 chunk frames are a
	// few hundred KB; 8 MiB is generous) so a peer can't balloon our memory.
	maxFrameBytes int64 = 8 << 20
	// writeTimeout bounds each socket write: on a stalled link TCP buffers
	// would otherwise let the write block for minutes while frames pile up.
	writeTimeout = 10 * time.Second
)

// staleHostAfter: a host tunnel that hasn't produced any frame (including
// pong answers) for this long is a zombie (TCP half-open, sleeping laptop).
// A token-authenticated reconnect may take it over immediately instead of
// waiting out DeadAfter. RELAY_STALE_HOST_AFTER overrides it (e2e tests).
var staleHostAfter = 45 * time.Second

func init() {
	if v := os.Getenv("RELAY_STALE_HOST_AFTER"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			staleHostAfter = d
		}
	}
}

type conn struct {
	ws   *websocket.Conn
	send chan []byte

	mu       sync.Mutex
	lastSeen time.Time // last frame received from the peer
}

func (c *conn) touch() {
	c.mu.Lock()
	c.lastSeen = time.Now()
	c.mu.Unlock()
}

func (c *conn) idleFor() time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	return time.Since(c.lastSeen)
}

func (c *conn) writeJSON(v any) bool {
	data, err := json.Marshal(v)
	if err != nil {
		return false
	}
	select {
	case c.send <- data:
		return true
	default:
		// Slow consumer: the send queue is full. Drop the tunnel (not just
		// this frame) — a silently lost frame leaves the peer waiting on a
		// reply that never comes, while a closed socket triggers a clean
		// reconnect on both ends.
		c.ws.Close()
		return false
	}
}

// hub routes frames between host and device tunnels.
type hub struct {
	store *store.Store

	mu          sync.RWMutex
	hostConns   map[string]*conn   // hostID -> conn
	deviceConns map[string]*conn   // deviceID -> conn
	channels    map[string]string  // channel -> deviceID (for host->device routing)
}

func newHub(st *store.Store) *hub {
	return &hub{
		store:       st,
		hostConns:   map[string]*conn{},
		deviceConns: map[string]*conn{},
		channels:    map[string]string{},
	}
}

func (h *hub) attachHost(id string, c *conn) (kicked bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if old, ok := h.hostConns[id]; ok {
		log.Printf("hub: host %q replaced by new connection (kicking old)", id)
		close(old.send) // kick the stale connection (409 host-replaced)
		kicked = true
	}
	h.hostConns[id] = c
	return
}

func (h *hub) detachHost(id string, c *conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.hostConns[id] == c {
		delete(h.hostConns, id)
		h.store.SetHostOnline(id, false)
		log.Printf("hub: host %q detached (connection closed)", id)
	} else {
		log.Printf("hub: host %q detach skipped (not current conn)", id)
	}
}

func (h *hub) attachDevice(id string, c *conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if old, ok := h.deviceConns[id]; ok {
		close(old.send)
	}
	h.deviceConns[id] = c
}

// hostConn returns the live connection for a host, or nil.
func (h *hub) hostConn(id string) *conn {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.hostConns[id]
}

// deviceConn returns the live connection for a device, or nil.
func (h *hub) deviceConn(id string) *conn {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.deviceConns[id]
}

func (h *hub) detachDevice(id string, c *conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.deviceConns[id] == c {
		delete(h.deviceConns, id)
	}
	// Channels owned by the departed device can never be answered; drop them
	// so a reused channel name rebinds to the current owner.
	for ch, dev := range h.channels {
		if dev == id {
			delete(h.channels, ch)
		}
	}
}

// toHost delivers a frame from a device to its host tunnel; returns error code.
func (h *hub) toHost(hostID string, f Frame) string {
	h.mu.RLock()
	c, ok := h.hostConns[hostID]
	h.mu.RUnlock()
	if !ok {
		return "host-offline"
	}
	if !c.writeJSON(f) {
		return "overflow"
	}
	return ""
}

// toDevice delivers a frame from a host to a device (via channel routing).
func (h *hub) toDevice(deviceID string, f Frame) string {
	h.mu.RLock()
	c, ok := h.deviceConns[deviceID]
	h.mu.RUnlock()
	if !ok {
		return "device-offline"
	}
	if !c.writeJSON(f) {
		return "overflow"
	}
	return ""
}

func (h *hub) channelDevice(hostID, ch string) string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	// Channel keys are scoped per host (hostID/channel) so a channel name used
	// by devices of two different hosts can never cross-route replies.
	return h.channels[hostID+"/"+ch]
}

func (h *hub) bindChannel(hostID, ch, deviceID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	// Latest opener wins: a reused channel name belongs to the current device.
	h.channels[hostID+"/"+ch] = deviceID
}

var upgrader = websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}

type server struct {
	store       *store.Store
	hub         *hub
	pairLimiter *rateLimiter // POST /pair per-IP limit
	regLimiter  *rateLimiter // host register per-IP limit
}

// rateLimiter is a minimal per-IP sliding-window counter for sensitive
// endpoints (pair, host register). Prevents brute-force floods; not a full
// anti-DoS (behind nginx in production, which adds its own limits).
type rateLimiter struct {
	mu    sync.Mutex
	limit int
	win   time.Duration
	seen  map[string]*rlWindow
}

type rlWindow struct {
	start time.Time
	count int
}

func newRateLimiter(limit int, win time.Duration) *rateLimiter {
	return &rateLimiter{limit: limit, win: win, seen: map[string]*rlWindow{}}
}

func (r *rateLimiter) allow(ip string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	w, ok := r.seen[ip]
	if !ok || now.Sub(w.start) >= r.win {
		r.seen[ip] = &rlWindow{start: now, count: 1}
		return true
	}
	w.count++
	return w.count <= r.limit
}

// sweep drops windows older than the window so the map can't grow unbounded.
func (r *rateLimiter) sweep() {
	r.mu.Lock()
	defer r.mu.Unlock()
	cutoff := time.Now().Add(-r.win)
	for ip, w := range r.seen {
		if w.start.Before(cutoff) {
			delete(r.seen, ip)
		}
	}
}

// clientIP extracts the peer IP from r.RemoteAddr (host:port).
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func main() {
	st := store.New()
	h := newHub(st)
	srv := &server{
		store:       st,
		hub:         h,
		pairLimiter: newRateLimiter(10, time.Minute),
		regLimiter:  newRateLimiter(10, time.Minute),
	}

	// Periodic GC: drop expired sessions, stale devices and dead hosts so the
	// in-memory tables can't grow without bound (long-running DoS protection).
	go func() {
		ticker := time.NewTicker(10 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			st.GC(time.Now())
			srv.pairLimiter.sweep()
			srv.regLimiter.sweep()
		}
	}()

	mux := http.NewServeMux()
	// Health checks: keep the bare /healthz for container/loopback probes,
	// and expose /relay/healthz so reverse proxies that only forward /relay/
	// (see deploy/nginx.conf, deploy/nginx-http.conf) can reach it too.
	healthz := func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) }
	mux.HandleFunc("/healthz", healthz)
	mux.HandleFunc("/relay/healthz", healthz)
	mux.HandleFunc("/relay/v1/pair", srv.handlePair)
	mux.HandleFunc("/relay/v1/pair/refresh", srv.handleRefresh)
	mux.HandleFunc("/relay/v1/revoke", srv.handleRevoke)
	mux.HandleFunc("/relay/v1/host/devices", srv.handleHostDevices)
	mux.HandleFunc("/relay/v1/host", srv.handleHost)
	mux.HandleFunc("/relay/v1/device", srv.handleDevice)

	// Listen address: default ":8443" (HTTP; TLS/WSS is terminated by nginx
	// in front, see deploy/nginx.conf). Configurable via the RELAY_ADDR
	// environment variable or the -addr flag (flag overrides env).
	addr := ":8443"
	if env := os.Getenv("RELAY_ADDR"); env != "" {
		addr = env
	}
	flag.StringVar(&addr, "addr", addr, "listen address, e.g. \":8443\"")
	flag.Parse()
	log.Printf("relay listening on %s (WSS only behind TLS reverse proxy)", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

// ---- control plane (HTTP) ----

type apiError struct {
	Code string `json:"code"`
	Msg  string `json:"message"`
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{"error": apiError{Code: code, Msg: msg}})
}

func bearer(r *http.Request) string {
	const p = "Bearer "
	h := r.Header.Get("Authorization")
	if len(h) > len(p) && h[:len(p)] == p {
		return h[len(p):]
	}
	return ""
}

// POST /relay/v1/pair  {deviceId, pin}
// deviceId is the 13-digit device ID the shell generated and put in the QR
// code (registered on the relay as the host ID).
func (s *server) handlePair(w http.ResponseWriter, r *http.Request) {
	// CORS for web-based clients (file:// probe pages, future web UI).
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method", "POST required")
		return
	}
	if !s.pairLimiter.allow(clientIP(r)) {
		writeError(w, http.StatusTooManyRequests, "rate-limited", "too many attempts, try later")
		return
	}
	var req struct {
		DeviceID string `json:"deviceId"`
		Pin      string `json:"pin"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad-request", err.Error())
		return
	}
	dev, sessionToken, refreshToken, ok, code := s.store.PairDevice(req.DeviceID, req.Pin)
	if !ok {
		// One uniform error code: distinguishing pair-expired / pair-invalid /
		// pair-locked would let an attacker probe whether a hostId exists.
		log.Printf("pair: deviceId=%s FAILED code=%q", truncate(req.DeviceID, 8), code)
		writeError(w, http.StatusConflict, "pair-invalid", "PIN invalid or expired")
		return
	}
	log.Printf("pair: deviceId=%s OK -> device=%s", truncate(req.DeviceID, 8), truncate(dev.ID, 8))
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"hostId": dev.HostID, "deviceId": dev.ID,
		"sessionToken": sessionToken, "refreshToken": refreshToken,
	})
}

// POST /relay/v1/pair/refresh  {refreshToken}
func (s *server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method", "POST required")
		return
	}
	var req struct {
		RefreshToken string `json:"refreshToken"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad-request", err.Error())
		return
	}
	sessionToken, newRefresh, ok := s.store.RefreshSession(req.RefreshToken)
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", "invalid refresh token")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"sessionToken": sessionToken, "refreshToken": newRefresh})
}

// GET /relay/v1/host/devices  (Bearer hostToken)
// Lets the shell (host side) ask the relay which devices are paired to this
// host and whether each has a live tunnel — instead of guessing whether the
// mobile app is connected.
func (s *server) handleHostDevices(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method", "GET required")
		return
	}
	host := s.store.HostByToken(bearer(r))
	if host == nil {
		writeError(w, http.StatusUnauthorized, "unauthorized", "invalid or expired host token")
		return
	}
	devs := s.store.DevicesByHost(host.ID)
	out := make([]map[string]any, 0, len(devs))
	for _, d := range devs {
		out = append(out, map[string]any{
			"deviceId": d.ID,
			"online":   s.hub.deviceConn(d.ID) != nil,
			"pairedAt": d.CreatedAt,
		})
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"hostId": host.ID, "devices": out})
}

// POST /relay/v1/revoke  (Bearer sessionToken)  {deviceId?}
func (s *server) handleRevoke(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method", "POST required")
		return
	}
	tok := bearer(r)
	if tok == "" {
		writeError(w, http.StatusUnauthorized, "unauthorized", "missing token")
		return
	}
	if sess, ok := s.store.SessionByToken(tok); ok {
		s.store.RevokeSession(tok)
		// Drop the live tunnel.
		s.hub.mu.Lock()
		if c, ok := s.hub.deviceConns[sess.DeviceID]; ok {
			close(c.send)
		}
		s.hub.mu.Unlock()
	} else {
		writeError(w, http.StatusUnauthorized, "unauthorized", "invalid token")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"revoked": true})
}

// ---- tunnels (WSS) ----

// handleHost: first frame must be register (or Bearer hostToken on reconnect).
func (s *server) handleHost(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := &conn{ws: ws, send: make(chan []byte, 1024), lastSeen: time.Now()}
	go pump(c)
	defer ws.Close()

	var hostToken, pin string
	var pinExpires int64

	// Reconnect via hostToken?
	host := s.store.HostByToken(bearer(r))
	register := false
	if host == nil {
		if bearer(r) != "" {
			// Relay lost the host (restart / data reset): tell the bridge to
			// re-register, keeping this connection open for its register frame.
			log.Printf("host: token %q unknown -> ask re-register", truncate(bearer(r), 6))
			c.writeJSON(map[string]any{"v": 1, "type": "control", "kind": "unknown-host"})
		}
		// Wait for the register control frame (5s budget).
		ws.SetReadDeadline(time.Now().Add(5 * time.Second))
		_, raw, err := ws.ReadMessage()
		if err != nil {
			log.Printf("host: no register frame within budget: %v", err)
			ws.Close()
			return
		}
		var f Frame
		if json.Unmarshal(raw, &f) != nil || f.Type != "control" {
			ws.Close()
			return
		}
		var reg struct {
			HostID     string `json:"hostId"`
			HostName   string `json:"hostName"`
			DshVersion string `json:"dshVersion"`
			Pin        string `json:"pin"`
			Token      string `json:"token"` // persisted hostToken from a previous register
		}
		if err := json.Unmarshal(f.Body, &reg); err != nil {
			log.Printf("host register: bad body: %v", err)
			ws.Close()
			return
		}
		if f.Kind != "register" {
			log.Printf("host register: unexpected kind %q", f.Kind)
			ws.Close()
			return
		}
		if !s.regLimiter.allow(clientIP(r)) {
			log.Printf("host register: rate-limited from %s", clientIP(r))
			ws.Close()
			return
		}
		var ok bool
		var code string
		host, hostToken, pin, pinExpires, ok, code = s.store.RegisterHost(reg.HostID, reg.HostName, reg.DshVersion, reg.Pin, reg.Token)
		if !ok {
			// host-conflict / weak-pin: close without revealing anything useful.
			// Write the denial synchronously — the async pump would lose the
			// frame when the socket closes right after.
			log.Printf("host register: rejected hostId=%s code=%q", truncate(reg.HostID, 8), code)
			if msg, err := json.Marshal(map[string]any{
				"v": 1, "type": "control", "kind": "register-denied", "code": code,
			}); err == nil {
				_ = ws.WriteMessage(websocket.TextMessage, msg)
			}
			ws.Close()
			return
		}
		register = true
		ws.SetReadDeadline(time.Time{})
		log.Printf("host register: hostId=%s name=%q", truncate(host.ID, 8), reg.HostName)
	} else {
		// Token-authenticated reconnect. A duplicate bridge process would
		// otherwise kick and re-register each other in an endless loop, so a
		// connection that is still *live* refuses. But after a network blip /
		// laptop sleep the registered tunnel is a zombie (TCP half-open): it
		// stops answering the relay's 30s pings while the socket lingers.
		// Refusing then would leave the host offline for up to DeadAfter —
		// so a reconnect with a valid token takes over a tunnel that has
		// been silent for staleHostAfter. (The token proves identity; the
		// hijack protection on anonymous re-register is unaffected.)
		if old := s.hub.hostConn(host.ID); old != nil {
			if old.idleFor() < staleHostAfter {
				log.Printf("host: hostId=%s already online, refusing duplicate", truncate(host.ID, 8))
				ws.Close()
				return
			}
			log.Printf("host: hostId=%s stale tunnel idle=%s, taking over", truncate(host.ID, 8), old.idleFor().Round(time.Second))
		}
		log.Printf("host reconnect via token: hostId=%s", truncate(host.ID, 8))
	}

	kicked := s.hub.attachHost(host.ID, c)
	s.store.SetHostOnline(host.ID, true)
	defer s.hub.detachHost(host.ID, c)

	// A fresh register that displaces an existing tunnel closes itself: two
	// racing bridge processes then damp their replace-fight (oldest wins).
	// A token takeover must NOT self-close — taking over a stale tunnel is
	// its entire purpose.
	if register && kicked {
		log.Printf("host: hostId=%s replaced by new connection", truncate(host.ID, 8))
		ws.Close()
		return
	}
	if register {
		c.writeJSON(map[string]any{
			"v": 1, "type": "control", "kind": "registered",
			"body": map[string]any{
				"hostId": host.ID, "hostToken": hostToken,
				"pin": pin, "pinExpiresAt": pinExpires,
			},
		})
		log.Printf("host: registered hostId=%s", truncate(host.ID, 8))
	}

	readerLoop(c, func(f Frame) {
		switch f.Type {
		case "ping":
			c.writeJSON(map[string]any{"v": 1, "type": "pong"})
		case "rpc-reply", "sse-frame", "sse-close", "http-reply", "signal":
			// Host -> device: route by channel (scoped to this host).
			dev := s.hub.channelDevice(host.ID, f.Channel)
			if dev != "" {
				if code := s.hub.toDevice(dev, f); code != "" {
					log.Printf("host->device: route failed ch=%q code=%q", truncate(f.Channel, 12), code)
				} else {
					// Summarize rpc-reply bodies so the session list contents
					// are visible without dumping the whole payload.
					summary := ""
					if f.Type == "rpc-reply" {
						var body struct {
							OK    bool `json:"ok"`
							Value struct {
								Items []json.RawMessage `json:"items"`
							} `json:"value"`
							Error *struct {
								Code string `json:"code"`
							} `json:"error"`
						}
						if json.Unmarshal(f.Body, &body) == nil {
							if body.OK {
								summary = fmt.Sprintf(" ok=true items=%d", len(body.Value.Items))
							} else if body.Error != nil {
								summary = fmt.Sprintf(" ok=false code=%q", body.Error.Code)
							}
						}
					}
					log.Printf("host->device: forwarded type=%q ch=%q rpcId=%q%s", f.Type, f.Channel, f.RpcID, summary)
				}
			} else {
				log.Printf("host->device: no device bound to channel %q", f.Channel)
			}
		default:
			// ignore unknown host frames
		}
	})
}

// handleDevice: requires a valid sessionToken; routes device frames to host.
func (s *server) handleDevice(w http.ResponseWriter, r *http.Request) {
	tok := bearer(r)
	sess, ok := s.store.SessionByToken(tok)
	if !ok {
		log.Printf("device: rejected token %q", truncate(tok, 10))
		writeError(w, http.StatusUnauthorized, "unauthorized", "invalid or expired session token")
		return
	}
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := &conn{ws: ws, send: make(chan []byte, 1024), lastSeen: time.Now()}
	go pump(c)
	defer ws.Close()
	s.hub.attachDevice(sess.DeviceID, c)
	defer s.hub.detachDevice(sess.DeviceID, c)
	s.store.TouchDevice(sess.DeviceID)
	log.Printf("device: connected deviceId=%s", truncate(sess.DeviceID, 8))

	readerLoop(c, func(f Frame) {
		switch f.Type {
		case "ping":
			c.writeJSON(map[string]any{"v": 1, "type": "pong"})
		case "rpc", "sse-open", "respond", "http", "signal":
			if f.Channel != "" && f.Type != "sse-close" {
				s.hub.bindChannel(sess.HostID, f.Channel, sess.DeviceID)
			}
			if code := s.hub.toHost(sess.HostID, f); code != "" {
				// Transport-level error reply to the device, shaped by frame type
				// so the bridge resolves its pending request immediately instead
				// of hanging until its own timeout.
				log.Printf("device->host: route failed type=%q ch=%q code=%q",
					f.Type, truncate(f.Channel, 12), code)
				if f.Type == "http" {
					c.writeJSON(map[string]any{
						"v": 1, "type": "http-reply", "id": f.ID, "channel": f.Channel,
						"status": 502,
						"body": map[string]any{
							"headers": map[string]string{"content-type": "text/plain; charset=utf-8"},
							"body":    base64.StdEncoding.EncodeToString([]byte("desktop host offline: " + code)),
						},
					})
				} else {
					c.writeJSON(map[string]any{
						"v": 1, "type": "rpc-reply", "channel": f.Channel, "rpcId": f.RpcID,
						"body": map[string]any{"transport": true, "error": map[string]string{"code": code}},
					})
				}
			} else {
				log.Printf("device->host: forwarded type=%q path=%q ch=%q rpcId=%q",
					f.Type, f.Path, f.Channel, f.RpcID)
			}
		default:
			// ignore
		}
	})
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func pump(c *conn) {
	ticker := time.NewTicker(PingInterval)
	defer func() {
		ticker.Stop()
		c.ws.Close()
	}()
	write := func(data []byte) bool {
		c.ws.SetWriteDeadline(time.Now().Add(writeTimeout))
		if err := c.ws.WriteMessage(websocket.TextMessage, data); err != nil {
			return false
		}
		return true
	}
	for {
		select {
		case data, ok := <-c.send:
			if !ok {
				c.ws.SetWriteDeadline(time.Now().Add(writeTimeout))
				c.ws.WriteMessage(websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.CloseNormalClosure, "replaced"))
				return
			}
			if !write(data) {
				return
			}
		case <-ticker.C:
			if !write([]byte(`{"v":1,"type":"ping"}`)) {
				return
			}
		}
	}
}

// readerLoop reads frames until the socket dies; pings are answered inline.
func readerLoop(c *conn, handle func(Frame)) {
	c.ws.SetReadLimit(maxFrameBytes)
	c.ws.SetReadDeadline(time.Now().Add(DeadAfter))
	c.ws.SetPongHandler(func(string) error {
		c.touch()
		c.ws.SetReadDeadline(time.Now().Add(DeadAfter))
		return nil
	})
	for {
		_, raw, err := c.ws.ReadMessage()
		if err != nil {
			var closeErr *websocket.CloseError
			if errors.As(err, &closeErr) && closeErr.Code == websocket.CloseNormalClosure {
				log.Printf("ws: read loop exit: normal close")
				return
			}
			log.Printf("ws: read loop exit: %v", err)
			return
		}
		c.touch()
		var f Frame
		if json.Unmarshal(raw, &f) != nil {
			continue // corrupt frame: skip, keep stream alive
		}
		if f.Type == "pong" {
			// The bridge answers ping with a TEXT pong frame ({"v":1,"type":"pong"}),
			// not a WebSocket protocol pong — refresh the read deadline either way
			// so a healthy tunnel never times out.
			c.ws.SetReadDeadline(time.Now().Add(DeadAfter))
			continue
		}
		handle(f)
	}
}
