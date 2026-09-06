// Package store keeps the relay's in-memory state: hosts, pair tickets,
// devices, and sessions. Tokens are stored as SHA-256 hashes only.
package store

import (
	"crypto/subtle"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"sync"
	"time"
)

const (
	PinTTL          = 10 * time.Minute
	PinMaxFailures  = 5
	PinLockDuration = 15 * time.Minute
	SessionTTL      = 24 * time.Hour
	RefreshTTL      = 30 * 24 * time.Hour
	MaxDevices      = 64
	DeviceStaleAfter = 90 * 24 * time.Hour // GC drops devices idle this long
)

type Host struct {
	ID          string
	Name        string
	DshVersion  string
	TokenHash   string
	Online      bool
	Pair        *Pair
	FixedPin    string          // long-lived pairing PIN set by the shell ("" = use Pair)
	PinFails    int             // consecutive wrong fixed-PIN attempts
	Devices     map[string]bool // deviceId -> bound
	LockedUntil int64           // unix ms while pair locked
	LastSeen    int64           // last register (unix ms), for GC of dead hosts
}

type Pair struct {
	HostID    string
	Pin       string
	ExpiresAt int64
	Used      bool
	FailCount int
}

type Device struct {
	ID        string
	HostID    string
	CreatedAt int64
	LastSeen  int64 // last tunnel connection (unix ms); GC drops stale devices
}

type Session struct {
	DeviceID  string
	HostID    string
	TokenHash string
	ExpiresAt int64
}

type Store struct {
	mu sync.RWMutex

	hosts       map[string]*Host
	hostByToken map[string]string // token hash -> hostID
	devices     map[string]*Device
	sessions    map[string]*Session // session token hash -> session
	refresh     map[string]string   // refresh token hash -> session token hash
}

func New() *Store {
	return &Store{
		hosts:       map[string]*Host{},
		hostByToken: map[string]string{},
		devices:     map[string]*Device{},
		sessions:    map[string]*Session{},
		refresh:     map[string]string{},
	}
}

func RandomToken(prefix string) string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return prefix + hex.EncodeToString(b)
}

func Hash(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

// RegisterHost creates or updates a host and a fresh pair ticket. When id is
// non-empty it is honored: an existing host keeps its id (new hostToken + pair
// ticket), an unknown id creates the host under it. Returns the host and the
// plaintext hostToken (shown once; only the hash is stored).
//
// Security: re-registering an EXISTING hostId requires a valid hostToken
// (regToken) or the host's current fixed PIN. Without one of them the request
// is refused — otherwise anyone who learns a hostId (QR code, logs) could
// hijack the host, kick the real bridge and intercept all device traffic. The
// PIN escape hatch exists because a client can otherwise lose its token with
// no way back (app reinstall, id-scheme change): knowing the fixed PIN proves
// the same ownership a successful pair would. A brand-new hostId (first
// registration) is always allowed; the bridge persists its hostToken so a
// restart reconnects with the token instead of re-registering anonymously.
func (s *Store) RegisterHost(id, name, dshVersion, fixedPin, regToken string) (*Host, string, string, int64, bool, string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if WeakPin(fixedPin) {
		return nil, "", "", 0, false, "weak-pin"
	}

	host := s.hosts[id]
	if host != nil {
		tokenOK := regToken != "" && s.tokenMatchesHost(regToken, host)
		pinOK := fixedPin != "" && host.FixedPin != "" &&
			subtle.ConstantTimeCompare([]byte(fixedPin), []byte(host.FixedPin)) == 1
		if !tokenOK && !pinOK {
			return nil, "", "", 0, false, "host-conflict"
		}
	} else {
		if id == "" {
			id = RandomToken("h_")
		}
		host = &Host{ID: id, Devices: map[string]bool{}}
		s.hosts[id] = host
	}
	host.Name = name
	host.DshVersion = dshVersion
	host.LastSeen = time.Now().UnixMilli()

	hostToken := RandomToken("ht_")
	host.TokenHash = Hash(hostToken)
	s.hostByToken[host.TokenHash] = host.ID

	if fixedPin != "" {
		// Shell-provided PIN: stable across registrations, no expiry.
		host.FixedPin = fixedPin
		host.Pair = nil
		return host, hostToken, host.FixedPin, 0, true, ""
	}
	if host.FixedPin != "" {
		// Re-register without a PIN keeps the stable one.
		return host, hostToken, host.FixedPin, 0, true, ""
	}
	pin := randomPin()
	now := time.Now()
	host.Pair = &Pair{
		HostID:    host.ID,
		Pin:       pin,
		ExpiresAt: now.Add(PinTTL).UnixMilli(),
	}
	return host, hostToken, pin, host.Pair.ExpiresAt, true, ""
}

// tokenMatchesHost reports whether token is the current hostToken of host.
func (s *Store) tokenMatchesHost(token string, host *Host) bool {
	return host.TokenHash != "" && host.TokenHash == Hash(token)
}

// WeakPin rejects trivially guessable fixed PINs (all-same digits, ascending /
// descending runs, common defaults). Returns false for empty (no fixed PIN).
func WeakPin(pin string) bool {
	if pin == "" {
		return false
	}
	if len(pin) != 6 {
		return true
	}
	for _, c := range pin {
		if c < '0' || c > '9' {
			return true
		}
	}
	// All same digit, e.g. 000000 / 999999.
	allSame := true
	for i := 1; i < len(pin); i++ {
		if pin[i] != pin[0] {
			allSame = false
			break
		}
	}
	if allSame {
		return true
	}
	// Ascending / descending runs, e.g. 123456 / 654321.
	asc, desc := true, true
	for i := 1; i < len(pin); i++ {
		if pin[i] != pin[i-1]+1 {
			asc = false
		}
		if pin[i] != pin[i-1]-1 {
			desc = false
		}
	}
	if asc || desc {
		return true
	}
	switch pin {
	case "123123", "112233", "121212", "111222", "000001", "123321":
		return true
	}
	return false
}

// HostByToken resolves a host from its hostToken (reconnect path).
func (s *Store) HostByToken(token string) *Host {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.hostByToken[Hash(token)]
	if !ok {
		return nil
	}
	return s.hosts[id]
}

func (s *Store) SetHostOnline(id string, online bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if h, ok := s.hosts[id]; ok {
		h.Online = online
	}
}

func (s *Store) Host(id string) *Host {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.hosts[id]
}

// DevicesByHost returns the devices paired to a host (with pairedAt).
func (s *Store) DevicesByHost(hostID string) []*Device {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []*Device
	for _, d := range s.devices {
		if d.HostID == hostID {
			out = append(out, d)
		}
	}
	return out
}

// PairDevice validates deviceId(hostID)+pin, creates a device and session.
// Returns (device, sessionToken, refreshToken, ok, code).
func (s *Store) PairDevice(hostID, pin string) (*Device, string, string, bool, string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	host := s.hosts[hostID]
	if host == nil || (host.Pair == nil && host.FixedPin == "") {
		return nil, "", "", false, "pair-expired"
	}
	if host.LockedUntil > time.Now().UnixMilli() {
		return nil, "", "", false, "pair-locked"
	}
	if host.FixedPin != "" {
		// Stable PIN mode: valid until changed via Settings, still rate-limited.
		if pin != host.FixedPin {
			host.PinFails++
			if host.PinFails >= PinMaxFailures {
				host.LockedUntil = time.Now().Add(PinLockDuration).UnixMilli()
				host.PinFails = 0
				return nil, "", "", false, "pair-locked"
			}
			return nil, "", "", false, "pair-invalid"
		}
		host.PinFails = 0
	} else {
		p := host.Pair
		if now := time.Now().UnixMilli(); now > p.ExpiresAt {
			return nil, "", "", false, "pair-expired"
		}
		if p.Used {
			return nil, "", "", false, "pair-used"
		}
		if pin != p.Pin {
			p.FailCount++
			if p.FailCount >= PinMaxFailures {
				host.LockedUntil = time.Now().Add(PinLockDuration).UnixMilli()
				return nil, "", "", false, "pair-locked"
			}
			return nil, "", "", false, "pair-invalid"
		}
		p.Used = true
	}
	if len(host.Devices) >= MaxDevices {
		return nil, "", "", false, "device-limit"
	}
	dev := &Device{ID: RandomToken("d_"), HostID: host.ID, CreatedAt: time.Now().UnixMilli()}
	s.devices[dev.ID] = dev
	host.Devices[dev.ID] = true

	sessionToken := RandomToken("st_")
	refreshToken := RandomToken("rt_")
	expires := time.Now().Add(SessionTTL).UnixMilli()
	s.sessions[Hash(sessionToken)] = &Session{
		DeviceID: dev.ID, HostID: host.ID,
		TokenHash: Hash(sessionToken), ExpiresAt: expires,
	}
	s.refresh[Hash(refreshToken)] = Hash(sessionToken)

	return dev, sessionToken, refreshToken, true, ""
}

// SessionByToken validates a session token; ok=false when missing/expired/revoked.
func (s *Store) SessionByToken(token string) (*Session, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sess, ok := s.sessions[Hash(token)]
	if !ok {
		return nil, false
	}
	if time.Now().UnixMilli() > sess.ExpiresAt {
		return nil, false
	}
	return sess, true
}

// RefreshSession rotates a session token from a refresh token. The old session
// token is invalidated at the same time so a leaked token has no extra window.
func (s *Store) RefreshSession(refreshToken string) (string, string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sessHash, ok := s.refresh[Hash(refreshToken)]
	if !ok {
		return "", "", false
	}
	sess, ok := s.sessions[sessHash]
	if !ok {
		return "", "", false
	}
	delete(s.refresh, Hash(refreshToken)) // single-use
	delete(s.sessions, sessHash)          // invalidate the old session token

	newToken := RandomToken("st_")
	newHash := Hash(newToken)
	newRefresh := RandomToken("rt_")
	s.sessions[newHash] = &Session{
		DeviceID: sess.DeviceID, HostID: sess.HostID,
		TokenHash: newHash, ExpiresAt: time.Now().Add(SessionTTL).UnixMilli(),
	}
	s.refresh[Hash(newRefresh)] = newHash
	return newToken, newRefresh, true
}

// TouchDevice records the last time a device had a live tunnel, so GC can
// free stale device slots.
func (s *Store) TouchDevice(deviceID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if d, ok := s.devices[deviceID]; ok {
		d.LastSeen = time.Now().UnixMilli()
	}
}

// GC drops expired sessions, stale devices (no tunnel in DeviceStaleAfter)
// and hosts that are gone entirely. Runs on a timer from main.
func (s *Store) GC(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()

	nowMs := now.UnixMilli()
	for h, sess := range s.sessions {
		if nowMs > sess.ExpiresAt {
			delete(s.sessions, h)
		}
	}
	for rtHash, stHash := range s.refresh {
		if _, ok := s.sessions[stHash]; !ok {
			delete(s.refresh, rtHash)
		}
	}
	for dID, d := range s.devices {
		if nowMs-d.LastSeen > int64(DeviceStaleAfter/time.Millisecond) {
			delete(s.devices, dID)
			if h, ok := s.hosts[d.HostID]; ok {
				delete(h.Devices, dID)
			}
		}
	}
	for hID, h := range s.hosts {
		if len(h.Devices) == 0 && h.TokenHash != "" && nowMs-h.LastSeen > int64(DeviceStaleAfter/time.Millisecond) {
			delete(s.hosts, hID)
		}
	}
}

// RevokeSession drops a session token (and its refresh token).
func (s *Store) RevokeSession(token string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.sessions, Hash(token))
	for rtHash, stHash := range s.refresh {
		if stHash == Hash(token) {
			delete(s.refresh, rtHash)
		}
	}
}

// randomPin returns a 6-digit decimal PIN (000000-999999).
func randomPin() string {
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	n := binary.BigEndian.Uint32(b) % 1000000
	return fmt.Sprintf("%06d", n)
}
