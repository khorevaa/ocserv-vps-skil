package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testOrigin = "http://ocserv-0123456789abcdef0123456789abcdef.localhost:8765"

func writeTestSecret(t *testing.T, path, value string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(value+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func startFakeControl(t *testing.T, path string) {
	t.Helper()
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer connection.Close()
				line, err := bufio.NewReader(connection).ReadBytes('\n')
				if err != nil {
					return
				}
				var request map[string]any
				if json.Unmarshal(line, &request) != nil {
					return
				}
				action, _ := request["action"].(string)
				var result any
				switch action {
				case "overview":
					result = map[string]any{"service": map[string]any{"status": "running", "active_sessions": 1, "uptime_seconds": 90}, "server": map[string]any{"version": "1.5.0", "image": "ghcr.io/khorevaa/ocserv-vps:1.5.0", "domain": "vpn.test", "vpn_network": "10.66.0.0/24", "vpn_port": 443, "openconnect_checked_at": "2026-07-12T10:00:00Z", "updated_at": "2026-07-12T10:00:00Z"}, "certificate": map[string]any{"expires_at": "2026-10-10T00:00:00Z", "days_remaining": 90, "valid": true}, "users_total": 1}
				case "list_users":
					result = map[string]any{"users": []any{map[string]any{"username": "vpn_user", "active_sessions": 1}}, "total": 1}
				case "list_connections":
					result = map[string]any{"connections": []any{map[string]any{"id": 7, "username": "vpn_user", "client_ip": "192.0.2.5", "vpn_ip": "10.66.0.7", "protocol": "OpenConnect", "connected_at": "2026-07-12T10:00:00Z", "duration_seconds": 90}}, "total": 1}
				case "list_journal":
					result = map[string]any{"events": []any{map[string]any{"occurred_at": "2026-07-12T10:01:30Z", "event": "disconnected", "username": "vpn_user", "client_ip": "192.0.2.5", "vpn_ip": "10.66.0.7", "protocol": "OpenConnect", "duration_seconds": 90, "bytes_in": 1000, "bytes_out": 2000}}, "total": 1}
				case "disconnect_connection":
					result = map[string]any{"id": request["id"], "disconnected": true}
				case "add_user":
					result = map[string]any{"username": request["username"], "password": "Generated!Pass1"}
				case "rotate_password":
					result = map[string]any{"username": request["username"], "password": "Generated!Pass2", "sessions_terminated": request["terminate_sessions"]}
				default:
					return
				}
				_ = json.NewEncoder(connection).Encode(map[string]any{"request_id": request["request_id"], "ok": true, "result": result})
			}()
		}
	}()
}

func testApplication(t *testing.T, accessSecret string) (*application, config) {
	t.Helper()
	root := t.TempDir()
	sessionKey := filepath.Join(root, "session-key")
	access := filepath.Join(root, "access-secret")
	control := filepath.Join(root, "control.sock")
	writeTestSecret(t, sessionKey, "test-session-key-with-at-least-32-bytes!")
	writeTestSecret(t, access, accessSecret)
	startFakeControl(t, control)
	cfg := config{DataFile: filepath.Join(root, "state.json"), ControlSocket: control, WebSocket: filepath.Join(root, "web.sock"), SessionKeyFile: sessionKey, AccessSecretFile: access, UIImage: "ghcr.io/khorevaa/ocserv-vps-ui:0.4.5", AllowedOrigin: testOrigin, AllowedHost: strings.TrimPrefix(testOrigin, "http://"), SessionTTLSeconds: 3600, AuditRetentionSeconds: 3600, AuditMaxRows: 20, ControlTimeoutSeconds: 1, MaxRequestBytes: 16384, RequireRootSecrets: false}
	app, err := newApplication(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return app, cfg
}

func perform(app http.Handler, method, path, body string, cookie *http.Cookie, csrf string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, "http://"+strings.TrimPrefix(testOrigin, "http://")+path, strings.NewReader(body))
	request.Host = strings.TrimPrefix(testOrigin, "http://")
	if method != http.MethodGet {
		request.Header.Set("Origin", testOrigin)
		request.Header.Set("Content-Type", "application/json")
	}
	if cookie != nil {
		request.AddCookie(cookie)
	}
	if csrf != "" {
		request.Header.Set("X-CSRF-Token", csrf)
	}
	recorder := httptest.NewRecorder()
	app.ServeHTTP(recorder, request)
	return recorder
}

func decodeBody(t *testing.T, recorder *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var value map[string]any
	if json.Unmarshal(recorder.Body.Bytes(), &value) != nil {
		t.Fatalf("invalid JSON: %s", recorder.Body.String())
	}
	return value
}

func TestSecretOnlyFlowAndEmbeddedUI(t *testing.T) {
	secret := strings.Repeat("A", 64)
	app, _ := testApplication(t, secret)
	locked := perform(app, "GET", "/api/v1/overview", "", nil, "")
	if locked.Code != 404 || locked.Header().Get("X-OCSERV-UI-Access") != "required" {
		t.Fatalf("locked status=%d", locked.Code)
	}
	root := perform(app, "GET", "/", "", nil, "")
	if !strings.Contains(root.Body.String(), "access-secret") {
		t.Fatal("access form missing")
	}
	invalid := perform(app, "POST", "/api/v1/access", `{"secret":"`+strings.Repeat("B", 64)+`"}`, nil, "")
	if invalid.Code != 404 || strings.Contains(invalid.Body.String(), secret) {
		t.Fatal("invalid secret response")
	}
	access := perform(app, "POST", "/api/v1/access", `{"secret":"`+secret+`"}`, nil, "")
	if access.Code != 200 {
		t.Fatalf("access=%d %s", access.Code, access.Body.String())
	}
	cookies := access.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].Secure || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatal("unsafe session cookie")
	}
	payload := decodeBody(t, access)
	csrf, _ := payload["csrf_token"].(string)
	if csrf == "" {
		t.Fatal("missing csrf")
	}
	index := perform(app, "GET", "/", "", cookies[0], "")
	html := index.Body.String()
	for _, forbidden := range []string{"login-form", "operator-name", "Управление доступом", ">Обзор<"} {
		if strings.Contains(html, forbidden) {
			t.Fatalf("legacy UI artifact remains: %s", forbidden)
		}
	}
	for _, required := range []string{"Состояние системы", "Подключения", "Журнал", "Пользователи", "Как в системе", "Тёмная"} {
		if !strings.Contains(html, required) {
			t.Fatalf("missing UI label %s", required)
		}
	}
	me := perform(app, "GET", "/api/v1/auth/me", "", cookies[0], "")
	if me.Code != 200 {
		t.Fatalf("me=%d", me.Code)
	}
	denied := perform(app, "POST", "/api/v1/users", `{"username":"alice"}`, cookies[0], "")
	if denied.Code != 403 {
		t.Fatalf("csrf denial=%d", denied.Code)
	}
	created := perform(app, "POST", "/api/v1/users", `{"username":"alice"}`, cookies[0], csrf)
	if created.Code != 201 || !strings.Contains(created.Body.String(), "Generated!Pass1") {
		t.Fatalf("create=%d %s", created.Code, created.Body.String())
	}
	stateData, err := os.ReadFile(app.store.path)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{secret, cookies[0].Value, csrf, "Generated!Pass1"} {
		if strings.Contains(string(stateData), forbidden) {
			t.Fatalf("secret leaked to JSON state")
		}
	}
}

func TestConnectionsJournalAndDisconnect(t *testing.T) {
	app, _ := testApplication(t, strings.Repeat("A", 64))
	access := perform(app, "POST", "/api/v1/access", `{"secret":"`+strings.Repeat("A", 64)+`"}`, nil, "")
	cookie := access.Result().Cookies()[0]
	csrf, _ := decodeBody(t, access)["csrf_token"].(string)
	connections := perform(app, "GET", "/api/v1/connections", "", cookie, "")
	if connections.Code != 200 || !strings.Contains(connections.Body.String(), `"client_ip":"192.0.2.5"`) {
		t.Fatalf("connections=%d %s", connections.Code, connections.Body.String())
	}
	journal := perform(app, "GET", "/api/v1/journal", "", cookie, "")
	if journal.Code != 200 || !strings.Contains(journal.Body.String(), `"event":"disconnected"`) {
		t.Fatalf("journal=%d %s", journal.Code, journal.Body.String())
	}
	withoutCSRF := perform(app, "DELETE", "/api/v1/connections/7", "", cookie, "")
	if withoutCSRF.Code != 403 {
		t.Fatalf("disconnect without CSRF=%d", withoutCSRF.Code)
	}
	disconnected := perform(app, "DELETE", "/api/v1/connections/7", "", cookie, csrf)
	if disconnected.Code != 200 || !strings.Contains(disconnected.Body.String(), `"disconnected":true`) {
		t.Fatalf("disconnect=%d %s", disconnected.Code, disconnected.Body.String())
	}
}

func TestHostOriginAndRemovedLogin(t *testing.T) {
	app, _ := testApplication(t, strings.Repeat("A", 64))
	request := httptest.NewRequest("GET", testOrigin+"/", nil)
	request.Host = "localhost:8765"
	response := httptest.NewRecorder()
	app.ServeHTTP(response, request)
	if response.Code != 400 {
		t.Fatalf("host=%d", response.Code)
	}
	missingOrigin := httptest.NewRequest("POST", testOrigin+"/api/v1/access", strings.NewReader(`{"secret":"`+strings.Repeat("A", 64)+`"}`))
	missingOrigin.Host = strings.TrimPrefix(testOrigin, "http://")
	response = httptest.NewRecorder()
	app.ServeHTTP(response, missingOrigin)
	if response.Code != 403 {
		t.Fatalf("origin=%d", response.Code)
	}
	login := perform(app, "POST", "/api/v1/auth/login", `{}`, nil, "")
	if login.Code != 404 {
		t.Fatalf("removed login=%d", login.Code)
	}
}

func TestControlResponseIsAllowlisted(t *testing.T) {
	app, _ := testApplication(t, strings.Repeat("A", 64))
	access := perform(app, "POST", "/api/v1/access", `{"secret":"`+strings.Repeat("A", 64)+`"}`, nil, "")
	cookie := access.Result().Cookies()[0]
	overview := perform(app, "GET", "/api/v1/overview", "", cookie, "")
	if overview.Code != 200 {
		t.Fatalf("overview=%d %s", overview.Code, overview.Body.String())
	}
	body, _ := io.ReadAll(overview.Result().Body)
	if strings.Contains(string(body), "active_sessions") || !strings.Contains(string(body), "active_connections") {
		t.Fatalf("overview contract: %s", body)
	}
}

func TestUIInfoMasksAccessSecret(t *testing.T) {
	app, _ := testApplication(t, strings.Repeat("A", 64))
	access := perform(app, "POST", "/api/v1/access", `{"secret":"`+strings.Repeat("A", 64)+`"}`, nil, "")
	cookie := access.Result().Cookies()[0]
	response := perform(app, "GET", "/api/v1/ui", "", cookie, "")
	if response.Code != 200 || !strings.Contains(response.Body.String(), "ocserv-vps-ui:0.4.5") || strings.Contains(response.Body.String(), strings.Repeat("A", 64)) {
		t.Fatalf("ui info=%d %s", response.Code, response.Body.String())
	}
}
