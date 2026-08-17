// Package store keeps the relay's in-memory state: hosts, pair tickets,
// devices, and sessions. Tokens are stored as SHA-256 hashes only.
package store

import (
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
// RegisterHost creates/updates a host. When fixedPin is non-empty it becomes
// the host's long-lived pairing PIN (returned unchanged on every register);
// otherwise a fresh short-lived Pair PIN is generated.
func (s *Store) RegisterHost(id, name, dshVersion, fixedPin string) (*Host, string, string, int64) {
	s.mu.Lock()
	defer s.mu.Unlock()

	host := s.hosts[id]
	if host == nil {
		if id == "" {
			id = RandomToken("h_")
		}
		host = &Host{ID: id, Devices: map[string]bool{}}
		s.hosts[id] = host
	}
	host.Name = name
	host.DshVersion = dshVersion

	hostToken := RandomToken("ht_")
	host.TokenHash = Hash(hostToken)
	s.hostByToken[host.TokenHash] = host.ID

	if fixedPin != "" {
		// Shell-provided PIN: stable across registrations, no expiry.
		host.FixedPin = fixedPin
		host.Pair = nil
		return host, hostToken, host.FixedPin, 0
	}
	if host.FixedPin != "" {
		// Re-register without a PIN keeps the stable one.
		return host, hostToken, host.FixedPin, 0
	}
	pin := randomPin()
	now := time.Now()
	host.Pair = &Pair{
		HostID:    host.ID,
		Pin:       pin,
		ExpiresAt: now.Add(PinTTL).UnixMilli(),
	}
	return host, hostToken, pin, host.Pair.ExpiresAt
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

// RefreshSession rotates a session token from a refresh token.
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
