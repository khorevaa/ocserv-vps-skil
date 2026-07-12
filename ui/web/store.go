package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

type sessionRecord struct {
	TokenHash string `json:"token_hash"`
	CSRFHash  string `json:"csrf_hash"`
	CreatedAt int64  `json:"created_at"`
	ExpiresAt int64  `json:"expires_at"`
}

type auditRecord struct {
	OccurredAt int64          `json:"occurred_at"`
	Actor      string         `json:"actor,omitempty"`
	Action     string         `json:"action"`
	Target     string         `json:"target,omitempty"`
	Success    bool           `json:"success"`
	Remote     string         `json:"remote"`
	Details    map[string]any `json:"details,omitempty"`
}

type persistedState struct {
	Version  int             `json:"version"`
	KeyID    string          `json:"key_id"`
	Sessions []sessionRecord `json:"sessions"`
	Audit    []auditRecord   `json:"audit"`
}

type session struct {
	Token     string
	CSRFToken string
	ExpiresAt int64
}

type jsonStore struct {
	mu             sync.Mutex
	path           string
	key            []byte
	keyID          string
	ttl            int64
	auditRetention int64
	auditMax       int
	state          persistedState
}

func deriveSessionKey(sessionKey, accessSecret []byte) []byte {
	mac := hmac.New(sha256.New, sessionKey)
	mac.Write([]byte("access-secret\x00"))
	mac.Write(accessSecret)
	return mac.Sum(nil)
}

func newJSONStore(cfg config, key []byte) (*jsonStore, error) {
	keyIDHash := hmac.New(sha256.New, key)
	keyIDHash.Write([]byte("ocserv-ui-json-key-id-v1"))
	store := &jsonStore{
		path: cfg.DataFile, key: append([]byte(nil), key...),
		keyID: hex.EncodeToString(keyIDHash.Sum(nil)[:16]), ttl: cfg.SessionTTLSeconds,
		auditRetention: cfg.AuditRetentionSeconds, auditMax: cfg.AuditMaxRows,
		state: persistedState{Version: 1},
	}
	if err := store.load(); err != nil {
		return nil, err
	}
	return store, nil
}

func (s *jsonStore) hash(purpose, value string) string {
	mac := hmac.New(sha256.New, s.key)
	mac.Write([]byte(purpose))
	mac.Write([]byte{0})
	mac.Write([]byte(value))
	return hex.EncodeToString(mac.Sum(nil))
}

func (s *jsonStore) load() error {
	directory := filepath.Dir(s.path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	resolved, err := filepath.EvalSymlinks(directory)
	if err != nil || resolved != directory {
		return fmt.Errorf("JSON state directory is unsafe")
	}
	directoryInfo, err := os.Lstat(directory)
	if err != nil || !directoryInfo.IsDir() || directoryInfo.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("JSON state directory is unsafe")
	}
	if stat, ok := directoryInfo.Sys().(*syscall.Stat_t); !ok || stat.Uid != uint32(os.Geteuid()) || stat.Gid != uint32(os.Getegid()) {
		return fmt.Errorf("JSON state directory ownership is unsafe")
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(s.path)
	if os.IsNotExist(err) {
		s.state = persistedState{Version: 1, KeyID: s.keyID, Sessions: []sessionRecord{}, Audit: []auditRecord{}}
		return s.persistLocked()
	}
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		return fmt.Errorf("JSON state file is unsafe")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != uint32(os.Geteuid()) || stat.Gid != uint32(os.Getegid()) {
		return fmt.Errorf("JSON state ownership is unsafe")
	}
	fd, err := syscall.Open(s.path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("cannot open JSON state: %w", err)
	}
	file := os.NewFile(uintptr(fd), s.path)
	openedInfo, statErr := file.Stat()
	if statErr != nil || !os.SameFile(info, openedInfo) {
		_ = file.Close()
		return fmt.Errorf("JSON state changed during validation")
	}
	data, readErr := io.ReadAll(io.LimitReader(file, 8*1024*1024+1))
	closeErr := file.Close()
	if readErr != nil {
		return fmt.Errorf("cannot read JSON state: %w", readErr)
	}
	if closeErr != nil {
		return closeErr
	}
	var state persistedState
	if len(data) > 8*1024*1024 || json.Unmarshal(data, &state) != nil || state.Version != 1 {
		return fmt.Errorf("JSON state is invalid")
	}
	if state.KeyID != s.keyID {
		state.KeyID = s.keyID
		state.Sessions = []sessionRecord{}
	}
	s.state = state
	s.pruneLocked(time.Now().Unix())
	return s.persistLocked()
}

func (s *jsonStore) pruneLocked(now int64) {
	sessions := s.state.Sessions[:0]
	for _, item := range s.state.Sessions {
		if item.ExpiresAt > now {
			sessions = append(sessions, item)
		}
	}
	s.state.Sessions = sessions
	cutoff := now - s.auditRetention
	audit := s.state.Audit[:0]
	for _, item := range s.state.Audit {
		if item.OccurredAt > cutoff {
			audit = append(audit, item)
		}
	}
	if len(audit) > s.auditMax {
		audit = audit[len(audit)-s.auditMax:]
	}
	s.state.Audit = audit
}

func (s *jsonStore) persistLocked() error {
	data, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	directory := filepath.Dir(s.path)
	temporary, err := os.CreateTemp(directory, ".state.json.*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if err = temporary.Chmod(0o600); err == nil {
		_, err = temporary.Write(data)
	}
	if err == nil {
		err = temporary.Sync()
	}
	if closeErr := temporary.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(name, s.path); err != nil {
		return err
	}
	dir, err := os.Open(directory)
	if err == nil {
		err = dir.Sync()
		_ = dir.Close()
	}
	return err
}

func randomToken() (string, error) {
	buffer := make([]byte, 32)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buffer), nil
}

func (s *jsonStore) createSession() (session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now().Unix()
	s.pruneLocked(now)
	token, err := randomToken()
	if err != nil {
		return session{}, err
	}
	csrfMAC := hmac.New(sha256.New, s.key)
	csrfMAC.Write([]byte("csrf\x00" + token))
	csrf := base64.RawURLEncoding.EncodeToString(csrfMAC.Sum(nil))
	expires := now + s.ttl
	s.state.Sessions = append(s.state.Sessions, sessionRecord{
		TokenHash: s.hash("session", token), CSRFHash: s.hash("csrf", csrf),
		CreatedAt: now, ExpiresAt: expires,
	})
	if err := s.persistLocked(); err != nil {
		return session{}, err
	}
	return session{Token: token, CSRFToken: csrf, ExpiresAt: expires}, nil
}

func (s *jsonStore) lookup(token string) (sessionRecord, bool) {
	if len(token) < 20 || len(token) > 256 {
		return sessionRecord{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now().Unix()
	wanted := s.hash("session", token)
	for _, item := range s.state.Sessions {
		if item.ExpiresAt > now && hmac.Equal([]byte(item.TokenHash), []byte(wanted)) {
			return item, true
		}
	}
	return sessionRecord{}, false
}

func (s *jsonStore) csrfMatches(record sessionRecord, supplied string) bool {
	if len(supplied) < 20 || len(supplied) > 256 {
		return false
	}
	return hmac.Equal([]byte(record.CSRFHash), []byte(s.hash("csrf", supplied)))
}

func (s *jsonStore) csrfForToken(token string) string {
	mac := hmac.New(sha256.New, s.key)
	mac.Write([]byte("csrf\x00" + token))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (s *jsonStore) deleteSession(token string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	wanted := s.hash("session", token)
	kept := s.state.Sessions[:0]
	for _, item := range s.state.Sessions {
		if !hmac.Equal([]byte(item.TokenHash), []byte(wanted)) {
			kept = append(kept, item)
		}
	}
	s.state.Sessions = kept
	return s.persistLocked()
}

func (s *jsonStore) audit(record auditRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if record.OccurredAt == 0 {
		record.OccurredAt = time.Now().Unix()
	}
	s.state.Audit = append(s.state.Audit, record)
	s.pruneLocked(record.OccurredAt)
	return s.persistLocked()
}
