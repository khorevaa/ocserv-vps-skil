//go:build linux

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"
)

type fakeRunner struct {
	passwordPath  string
	failPassword  bool
	failReload    bool
	failTerminate bool
	calls         [][]string
	inputs        []string
}

func (f *fakeRunner) Run(argv []string, stdin string) (string, error) {
	f.calls = append(f.calls, append([]string(nil), argv...))
	f.inputs = append(f.inputs, stdin)
	if strings.Contains(filepath.Base(argv[0]), "ocpasswd") {
		if f.failPassword {
			return "", controlFailure(503, "backend_error", "rejected")
		}
		lines := strings.Split(strings.TrimSpace(stdin), "\n")
		if len(lines) != 2 || lines[0] == "" || lines[0] != lines[1] {
			return "", errors.New("bad password input")
		}
		username := argv[len(argv)-1]
		content, _ := os.ReadFile(f.passwordPath)
		output := []string{}
		for _, line := range strings.Split(strings.TrimSpace(string(content)), "\n") {
			if line != "" && !strings.HasPrefix(line, username+":") {
				output = append(output, line)
			}
		}
		output = append(output, username+":*:newhash")
		if err := os.WriteFile(f.passwordPath, []byte(strings.Join(output, "\n")+"\n"), 0o600); err != nil {
			return "", err
		}
		return "", nil
	}
	command := argv[4:]
	switch {
	case reflect.DeepEqual(command, []string{"show", "status"}):
		return `{"Status":"online","uptime":1234,"Active sessions":2,"Private backend detail":"must-not-leak"}`, nil
	case reflect.DeepEqual(command, []string{"show", "users"}):
		return `[{"ID":41,"Username":"alice","Remote IP":"192.0.2.1","IPv4":"10.66.0.8","raw_connected_at":1783850400},{"ID":42,"Username":"alice","Remote IP":"192.0.2.2","IPv4":"10.66.0.9","raw_connected_at":1783850460}]`, nil
	case reflect.DeepEqual(command, []string{"reload"}):
		if f.failReload {
			return "", controlFailure(503, "backend_error", "rejected")
		}
		return `{}`, nil
	case len(command) == 3 && command[0] == "terminate" && command[1] == "user":
		if f.failTerminate {
			return "", controlFailure(503, "backend_error", "rejected")
		}
		return `{}`, nil
	case reflect.DeepEqual(command, []string{"disconnect", "id", "41"}):
		return `{}`, nil
	default:
		return "", errors.New("unexpected command: " + strings.Join(command, " "))
	}
}

func testService(t *testing.T) (*controlService, *fakeRunner, config) {
	t.Helper()
	root := t.TempDir()
	password := filepath.Join(root, "config", "ocpasswd")
	if err := os.MkdirAll(filepath.Dir(password), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(password, []byte("alice:*:oldhash\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(root, "state")
	stateBody := strings.Join([]string{
		"current_version=1.5.0",
		"current_image=ghcr.io/khorevaa/ocserv-vps:1.5.0",
		"domain=vpn.example.com",
		"vpn_network=10.66.0.0/24",
		"vpn_port=443",
		"openconnect_checked_at=2026-07-12T10:37:48Z",
		"updated_at=2026-07-12T10:38:00Z",
		"last_backup=/must/not/leak",
	}, "\n") + "\n"
	if err := os.WriteFile(state, []byte(stateBody), 0o640); err != nil {
		t.Fatal(err)
	}
	cfg := defaultConfig()
	cfg.SocketPath = filepath.Join(root, "control.sock")
	cfg.AllowedUID = uint32(os.Getuid())
	cfg.StatePath = state
	cfg.PasswordPath = password
	cfg.CertificatePath = filepath.Join(root, "fullchain.pem")
	cfg.JournalPath = filepath.Join(root, "vpn-events.jsonl")
	cfg.OCCTLSocket = filepath.Join(root, "occtl.sock")
	cfg.OperationLock = filepath.Join(root, "locks", "operation.lock")
	cfg.OCPasswordBin = filepath.Join(root, "ocpasswd")
	cfg.OCCTLBin = filepath.Join(root, "occtl")
	runner := &fakeRunner{passwordPath: password}
	return newControlService(cfg, runner), runner, cfg
}

func TestConnectionsDisconnectAndVPNJournalAreAllowlisted(t *testing.T) {
	service, runner, cfg := testService(t)
	service.now = func() time.Time { return time.Unix(1783850520, 0).UTC() }
	connections, err := service.listConnections()
	if err != nil {
		t.Fatal(err)
	}
	rows := connections["connections"].([]map[string]any)
	if len(rows) != 2 || rows[0]["id"] != 41 || rows[0]["duration_seconds"] != 120 || rows[0]["client_ip"] != "192.0.2.1" {
		t.Fatalf("unexpected connections: %#v", rows)
	}
	encoded, _ := json.Marshal(rows)
	if strings.Contains(string(encoded), "raw_connected_at") {
		t.Fatalf("raw backend field leaked: %s", encoded)
	}
	if _, err = service.disconnectConnection(41); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(runner.calls[len(runner.calls)-1][4:], []string{"disconnect", "id", "41"}) {
		t.Fatalf("unsafe disconnect command: %#v", runner.calls)
	}
	journal := strings.Join([]string{
		`{"occurred_at":1783850400,"event":"connected","username":"alice","remote_ip":"192.0.2.1","vpn_ip":"10.66.0.8","duration_seconds":0,"bytes_in":0,"bytes_out":0}`,
		`{"occurred_at":1783850520,"event":"disconnected","username":"alice","remote_ip":"192.0.2.1","vpn_ip":"10.66.0.8","duration_seconds":120,"bytes_in":1000,"bytes_out":2000}`,
		`{"occurred_at":1783850521,"event":"invalid","username":"alice","remote_ip":"192.0.2.1","vpn_ip":"10.66.0.8","secret":"must-not-leak"}`,
	}, "\n") + "\n"
	if err = os.WriteFile(cfg.JournalPath, []byte(journal), 0o640); err != nil {
		t.Fatal(err)
	}
	listed, err := service.listJournal()
	if err != nil {
		t.Fatal(err)
	}
	events := listed["events"].([]map[string]any)
	if len(events) != 2 || events[0]["event"] != "disconnected" || events[0]["bytes_out"] != int64(2000) {
		t.Fatalf("unexpected journal: %#v", events)
	}
	encoded, _ = json.Marshal(events)
	if strings.Contains(string(encoded), "must-not-leak") {
		t.Fatalf("journal leaked unapproved fields: %s", encoded)
	}
}

func TestOverviewAndUsersAreAllowlisted(t *testing.T) {
	service, _, _ := testService(t)
	overview, err := service.overview()
	if err != nil {
		t.Fatal(err)
	}
	serviceData := overview["service"].(map[string]any)
	if serviceData["status"] != "online" || serviceData["uptime_seconds"] != 1234 || serviceData["active_sessions"] != 2 {
		t.Fatalf("unexpected service data: %#v", serviceData)
	}
	encoded, _ := json.Marshal(overview)
	if strings.Contains(string(encoded), "last_backup") || strings.Contains(string(encoded), "Private backend detail") {
		t.Fatalf("private fields leaked: %s", encoded)
	}
	users, err := service.listUsers()
	if err != nil {
		t.Fatal(err)
	}
	listed := users["users"].([]map[string]any)
	if len(listed) != 1 || listed[0]["username"] != "alice" || listed[0]["active_sessions"] != 2 {
		t.Fatalf("unexpected users: %#v", users)
	}
	encoded, _ = json.Marshal(users)
	if strings.Contains(string(encoded), "192.0.2.1") {
		t.Fatal("remote IP leaked")
	}
}

func TestAddUserReturnsOneTimePasswordAndConflicts(t *testing.T) {
	service, runner, cfg := testService(t)
	result, err := service.addUser("bob")
	if err != nil {
		t.Fatal(err)
	}
	password := result["password"].(string)
	if result["username"] != "bob" || len(password) < 32 {
		t.Fatalf("unexpected result: %#v", result)
	}
	content, _ := os.ReadFile(cfg.PasswordPath)
	if !strings.Contains(string(content), "bob:*:newhash") {
		t.Fatal("password file was not updated")
	}
	for _, call := range runner.calls {
		if strings.Contains(strings.Join(call, " "), password) {
			t.Fatal("password leaked into argv")
		}
	}
	_, err = service.addUser("bob")
	assertControlError(t, err, 409, "user_exists")
}

func TestRotateMissingUserReturns404WithoutBackendCall(t *testing.T) {
	service, runner, _ := testService(t)
	_, err := service.rotatePassword("missing", true)
	assertControlError(t, err, 404, "user_not_found")
	if len(runner.calls) != 0 {
		t.Fatalf("backend was called: %#v", runner.calls)
	}
}

func TestPasswordFailureRollsBack(t *testing.T) {
	service, runner, cfg := testService(t)
	original, _ := os.ReadFile(cfg.PasswordPath)
	runner.failPassword = true
	_, err := service.rotatePassword("alice", false)
	if err == nil {
		t.Fatal("expected failure")
	}
	assertPasswordRestored(t, cfg, original)
}

func TestReloadFailureRollsBack(t *testing.T) {
	service, runner, cfg := testService(t)
	original, _ := os.ReadFile(cfg.PasswordPath)
	runner.failReload = true
	_, err := service.rotatePassword("alice", false)
	if err == nil {
		t.Fatal("expected failure")
	}
	assertPasswordRestored(t, cfg, original)
}

func TestTerminateFailureKeepsPasswordAndReturnsWarning(t *testing.T) {
	service, runner, cfg := testService(t)
	runner.failTerminate = true
	result, err := service.rotatePassword("alice", true)
	if err != nil {
		t.Fatal(err)
	}
	if result["sessions_terminated"] != false || result["warning"] != "session_termination_failed" {
		t.Fatalf("unexpected result: %#v", result)
	}
	content, _ := os.ReadFile(cfg.PasswordPath)
	if !strings.Contains(string(content), "alice:*:newhash") {
		t.Fatal("new password was not kept")
	}
}

func TestProtocolValidationAndErrorMapping(t *testing.T) {
	service, _, _ := testService(t)
	response := processRequest(service, map[string]any{"request_id": "req-1", "action": "add_user", "username": "alice"})
	if response.OK || response.Error == nil || response.Error.Status != 409 || response.RequestID != "req-1" {
		t.Fatalf("unexpected conflict response: %#v", response)
	}
	response = processRequest(service, map[string]any{"request_id": "req-2", "action": "rotate_password", "username": "../bad"})
	if response.Error.Code != "invalid_username" {
		t.Fatalf("unexpected invalid username response: %#v", response)
	}
	response = processRequest(service, map[string]any{"request_id": "3", "action": "overview", "path": "/etc/shadow"})
	if response.Error.Code != "unexpected_field" {
		t.Fatalf("unexpected extra field response: %#v", response)
	}
	response = processRequest(service, map[string]any{"request_id": "4", "action": "disconnect_connection", "id": "../bad"})
	if response.Error.Code != "invalid_connection_id" {
		t.Fatalf("unexpected invalid connection response: %#v", response)
	}
	response = processRequest(service, []any{"overview"})
	if response.Error.Code != "invalid_request" {
		t.Fatalf("unexpected non-object response: %#v", response)
	}
}

func TestBusyOperationLockPreventsMutation(t *testing.T) {
	service, runner, cfg := testService(t)
	if err := os.MkdirAll(filepath.Dir(cfg.OperationLock), 0o750); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(cfg.OperationLock, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	defer syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	_, err = service.addUser("bob")
	assertControlError(t, err, 409, "operation_busy")
	if len(runner.calls) != 0 {
		t.Fatal("backend was called while lock was held")
	}
}

func TestBackendFailuresAreNotRenderedAsZero(t *testing.T) {
	service, runner, _ := testService(t)
	runner.calls = nil
	runner.failReload = false
	failing := errorRunner{}
	service.runner = failing
	if _, err := service.overview(); err == nil {
		t.Fatal("overview must fail")
	}
	if _, err := service.listUsers(); err == nil {
		t.Fatal("list users must fail")
	}
}

type errorRunner struct{}

func (errorRunner) Run([]string, string) (string, error) {
	return "", controlFailure(503, "backend_unavailable", "unavailable")
}

func TestCertificateValidation(t *testing.T) {
	service, _, cfg := testService(t)
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	service.now = func() time.Time { return now }
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "vpn.example.com"},
		DNSNames: []string{"vpn.example.com"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(48 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	if err = os.WriteFile(cfg.CertificatePath, certificate, 0o640); err != nil {
		t.Fatal(err)
	}
	info := service.certificateInfo("vpn.example.com")
	if info["valid"] != true || info["days_remaining"] != 2 {
		t.Fatalf("unexpected certificate info: %#v", info)
	}
	if service.certificateInfo("wrong.example.com")["valid"] != false {
		t.Fatal("wrong domain accepted")
	}
}

func assertControlError(t *testing.T, err error, status int, code string) {
	t.Helper()
	var control *controlError
	if !errors.As(err, &control) || control.Status != status || control.Code != code {
		t.Fatalf("unexpected error: %#v", err)
	}
}

func assertPasswordRestored(t *testing.T, cfg config, original []byte) {
	t.Helper()
	content, _ := os.ReadFile(cfg.PasswordPath)
	if string(content) != string(original) {
		t.Fatalf("password file was not restored: %q", content)
	}
	backups, _ := filepath.Glob(filepath.Join(filepath.Dir(cfg.PasswordPath), ".ocpasswd.backup.*"))
	if len(backups) != 0 {
		t.Fatalf("backup artifacts remain: %#v", backups)
	}
}
