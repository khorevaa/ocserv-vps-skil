package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestJSONStoreIsAtomicPrivateAndRotationRevokesSessions(t *testing.T) {
	root := t.TempDir()
	cfg := config{DataFile: filepath.Join(root, "state.json"), SessionTTLSeconds: 3600, AuditRetentionSeconds: 3600, AuditMaxRows: 3}
	keyA := deriveSessionKey([]byte("session-key-with-at-least-thirty-two-bytes"), []byte(strings.Repeat("A", 64)))
	store, err := newJSONStore(cfg, keyA)
	if err != nil {
		t.Fatal(err)
	}
	session, err := store.createSession()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := store.lookup(session.Token); !ok {
		t.Fatal("new session not found")
	}
	for index := 0; index < 5; index++ {
		if err = store.audit(auditRecord{Actor: "operator", Action: "test", Target: string(rune('0' + index)), Success: true, Remote: "test"}); err != nil {
			t.Fatal(err)
		}
	}
	info, err := os.Lstat(cfg.DataFile)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 || info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("unsafe JSON mode %o", info.Mode().Perm())
	}
	data, err := os.ReadFile(cfg.DataFile)
	if err != nil {
		t.Fatal(err)
	}
	var state persistedState
	if json.Unmarshal(data, &state) != nil {
		t.Fatal("invalid JSON")
	}
	if len(state.Audit) != 3 {
		t.Fatalf("audit rows=%d", len(state.Audit))
	}
	keyB := deriveSessionKey([]byte("session-key-with-at-least-thirty-two-bytes"), []byte(strings.Repeat("B", 64)))
	rotated, err := newJSONStore(cfg, keyB)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := rotated.lookup(session.Token); ok {
		t.Fatal("old session survived secret rotation")
	}
}

func TestJSONStoreRejectsSymlink(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target.json")
	if err := os.WriteFile(target, []byte(`{"version":1}`), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "state.json")
	if err := os.Symlink(target, path); err != nil {
		t.Skip(err)
	}
	cfg := config{DataFile: path, SessionTTLSeconds: 3600, AuditRetentionSeconds: 3600, AuditMaxRows: 3}
	if _, err := newJSONStore(cfg, []byte(strings.Repeat("K", 32))); err == nil {
		t.Fatal("symlink state accepted")
	}
}
