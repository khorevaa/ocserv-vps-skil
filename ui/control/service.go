//go:build linux

package main

import (
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
)

const (
	maxStateBytes        = 64 * 1024
	maxPasswordFileBytes = 8 * 1024 * 1024
	maxCertificateBytes  = 1024 * 1024
	maxJournalBytes      = 8 * 1024 * 1024
	maxJournalRows       = 500
)

var (
	usernamePattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$`)
	versionPattern   = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$`)
	imagePattern     = regexp.MustCompile(`^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`)
	domainPattern    = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$`)
	timestampPattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`)
)

type controlService struct {
	config config
	runner commandRunner
	now    func() time.Time
}

func newControlService(cfg config, runner commandRunner) *controlService {
	if runner == nil {
		runner = execRunner{timeout: cfg.CommandTimeout}
	}
	return &controlService{config: cfg, runner: runner, now: time.Now}
}

func (s *controlService) dispatch(request map[string]any) (any, error) {
	if safeRequestID(request) == nil {
		return nil, controlFailure(400, "invalid_request_id", "A valid request_id is required.")
	}
	action, ok := request["action"].(string)
	if !ok {
		return nil, controlFailure(400, "invalid_action", "A valid action is required.")
	}
	allowed := map[string]map[string]bool{
		"healthcheck":           {"request_id": true, "action": true},
		"overview":              {"request_id": true, "action": true},
		"list_users":            {"request_id": true, "action": true},
		"list_connections":      {"request_id": true, "action": true},
		"list_journal":          {"request_id": true, "action": true},
		"disconnect_connection": {"request_id": true, "action": true, "id": true},
		"add_user":              {"request_id": true, "action": true, "username": true},
		"rotate_password":       {"request_id": true, "action": true, "username": true, "terminate_sessions": true},
	}
	keys, known := allowed[action]
	if !known {
		return nil, controlFailure(400, "unknown_action", "The requested action is not supported.")
	}
	for key := range request {
		if !keys[key] {
			return nil, controlFailure(400, "unexpected_field", "The request contains unsupported fields.")
		}
	}
	switch action {
	case "healthcheck":
		return s.backendHealth()
	case "overview":
		return s.overview()
	case "list_users":
		return s.listUsers()
	case "list_connections":
		return s.listConnections()
	case "list_journal":
		return s.listJournal()
	case "disconnect_connection":
		id := safePositiveInt(request["id"])
		if id == 0 {
			return nil, controlFailure(400, "invalid_connection_id", "The connection ID is invalid.")
		}
		return s.disconnectConnection(id)
	}
	username, ok := request["username"].(string)
	if !ok || !usernamePattern.MatchString(username) {
		return nil, controlFailure(400, "invalid_username", "The VPN username is invalid.")
	}
	if action == "add_user" {
		return s.addUser(username)
	}
	terminate := true
	if value, exists := request["terminate_sessions"]; exists {
		var valid bool
		terminate, valid = value.(bool)
		if !valid {
			return nil, controlFailure(400, "invalid_terminate_sessions", "terminate_sessions must be boolean.")
		}
	}
	return s.rotatePassword(username, terminate)
}

func (s *controlService) listConnections() (map[string]any, error) {
	data, err := s.occtlJSON("show", "users")
	if err != nil {
		return nil, err
	}
	connections := normalizedConnections(data, s.now().UTC())
	return map[string]any{"connections": connections, "total": len(connections)}, nil
}

func (s *controlService) disconnectConnection(id int) (map[string]any, error) {
	lock, err := acquireFileLock(s.config.OperationLock)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if _, err = s.runOCCTL("disconnect", "id", strconv.Itoa(id)); err != nil {
		return nil, err
	}
	return map[string]any{"id": id, "disconnected": true}, nil
}

func (s *controlService) listJournal() (map[string]any, error) {
	content, missing, err := readRegularFile(s.config.JournalPath, maxJournalBytes)
	if missing {
		return map[string]any{"events": []map[string]any{}, "total": 0}, nil
	}
	if err != nil {
		return nil, controlFailure(500, "invalid_journal", "The VPN journal is unreadable.")
	}
	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) > maxJournalRows {
		lines = lines[len(lines)-maxJournalRows:]
	}
	events := make([]map[string]any, 0, len(lines))
	for _, line := range lines {
		if line == "" || len(line) > 4096 {
			continue
		}
		decoder := json.NewDecoder(strings.NewReader(line))
		decoder.UseNumber()
		var raw map[string]any
		if decoder.Decode(&raw) != nil {
			continue
		}
		var trailing any
		if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
			continue
		}
		if event := normalizedJournalEvent(raw); event != nil {
			events = append(events, event)
		}
	}
	for left, right := 0, len(events)-1; left < right; left, right = left+1, right-1 {
		events[left], events[right] = events[right], events[left]
	}
	return map[string]any{"events": events, "total": len(events)}, nil
}

func (s *controlService) backendHealth() (map[string]string, error) {
	info, err := os.Lstat(s.config.PasswordPath)
	if err != nil || !info.Mode().IsRegular() {
		return nil, controlFailure(503, "backend_unavailable", "The ocserv password database is unavailable.")
	}
	status, err := s.occtlJSON("show", "status")
	if err != nil {
		return nil, err
	}
	raw := findValue(status, "status")
	value, ok := raw.(string)
	if !ok || !strings.EqualFold(value, "online") {
		return nil, controlFailure(503, "backend_unavailable", "The ocserv backend is not online.")
	}
	if _, err = s.readUsernames(); err != nil {
		return nil, err
	}
	return map[string]string{"status": "ok"}, nil
}

func (s *controlService) overview() (map[string]any, error) {
	state, err := s.readState()
	if err != nil {
		return nil, err
	}
	statusData, err := s.occtlJSON("show", "status")
	if err != nil {
		return nil, err
	}
	status := "unknown"
	if raw, ok := findValue(statusData, "status").(string); ok {
		status = strings.ToLower(raw)
	}
	if status != "online" && status != "offline" {
		status = "unknown"
	}
	users, err := s.readUsernames()
	if err != nil {
		return nil, err
	}
	domain := safeDomain(state["domain"])
	return map[string]any{
		"service": map[string]any{
			"status":          status,
			"uptime_seconds":  safeNonnegativeInt(findValue(statusData, "uptime"), 0),
			"active_sessions": safeNonnegativeInt(findValue(statusData, "active sessions"), 0),
		},
		"server": map[string]any{
			"version":                safeVersion(state["current_version"]),
			"image":                  safeImage(state["current_image"]),
			"domain":                 domain,
			"vpn_network":            safeNetwork(state["vpn_network"]),
			"vpn_port":               safePort(state["vpn_port"]),
			"openconnect_checked_at": safeTimestamp(state["openconnect_checked_at"]),
			"updated_at":             safeTimestamp(state["updated_at"]),
		},
		"certificate": s.certificateInfo(domain),
		"users_total": len(users),
	}, nil
}

func (s *controlService) listUsers() (map[string]any, error) {
	usernames, err := s.readUsernames()
	if err != nil {
		return nil, err
	}
	data, err := s.occtlJSON("show", "users")
	if err != nil {
		return nil, err
	}
	counts := map[string]int{}
	for _, username := range activeUsernames(data) {
		counts[username]++
	}
	users := make([]map[string]any, 0, len(usernames))
	for _, username := range usernames {
		users = append(users, map[string]any{"username": username, "active_sessions": counts[username]})
	}
	return map[string]any{"users": users, "total": len(users)}, nil
}

func (s *controlService) addUser(username string) (map[string]any, error) {
	lock, err := acquireFileLock(s.config.OperationLock)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	users, err := s.readUsernames()
	if err != nil {
		return nil, err
	}
	if contains(users, username) {
		return nil, controlFailure(409, "user_exists", "The VPN user already exists.")
	}
	return s.changePassword(username)
}

func (s *controlService) rotatePassword(username string, terminate bool) (map[string]any, error) {
	lock, err := acquireFileLock(s.config.OperationLock)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	users, err := s.readUsernames()
	if err != nil {
		return nil, err
	}
	if !contains(users, username) {
		return nil, controlFailure(404, "user_not_found", "The VPN user does not exist.")
	}
	result, err := s.changePassword(username)
	if err != nil {
		return nil, err
	}
	result["sessions_terminated"] = false
	if terminate {
		if _, terminateErr := s.runOCCTL("terminate", "user", username); terminateErr != nil {
			result["warning"] = "session_termination_failed"
		} else {
			result["sessions_terminated"] = true
		}
	}
	return result, nil
}

func (s *controlService) changePassword(username string) (map[string]any, error) {
	password, err := randomPassword()
	if err != nil {
		return nil, controlFailure(500, "random_failed", "A secure password could not be generated.")
	}
	snapshot, err := capturePasswordSnapshot(s.config.PasswordPath)
	if err != nil {
		return nil, err
	}
	mutationErr := func() error {
		_, runErr := s.runner.Run([]string{s.config.OCPasswordBin, "-c", s.config.PasswordPath, "--", username}, password+"\n"+password+"\n")
		if runErr != nil {
			return runErr
		}
		if chmodErr := os.Chmod(s.config.PasswordPath, 0o600); chmodErr != nil {
			return controlFailure(503, "backend_error", "The password database permissions could not be secured.")
		}
		users, readErr := s.readUsernames()
		if readErr != nil {
			return readErr
		}
		if !contains(users, username) {
			return controlFailure(503, "backend_error", "The password database was not updated.")
		}
		_, reloadErr := s.runOCCTL("reload")
		return reloadErr
	}()
	if mutationErr != nil {
		if rollbackErr := snapshot.Rollback(); rollbackErr != nil {
			return nil, controlFailure(500, "rollback_failed", "The password database could not be restored safely.")
		}
		_, _ = s.runOCCTL("reload")
		return nil, mutationErr
	}
	if err = snapshot.Commit(); err != nil {
		return nil, controlFailure(500, "snapshot_cleanup_failed", "The password snapshot could not be removed safely.")
	}
	return map[string]any{"username": username, "password": password}, nil
}

func (s *controlService) runOCCTL(arguments ...string) (string, error) {
	argv := []string{s.config.OCCTLBin, "-j", "-s", s.config.OCCTLSocket}
	argv = append(argv, arguments...)
	return s.runner.Run(argv, "")
}

func (s *controlService) occtlJSON(arguments ...string) (any, error) {
	raw, err := s.runOCCTL(arguments...)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err = decoder.Decode(&value); err != nil {
		return nil, controlFailure(503, "backend_error", "The ocserv backend returned invalid data.")
	}
	var trailing any
	if err = decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return nil, controlFailure(503, "backend_error", "The ocserv backend returned invalid data.")
	}
	return value, nil
}

func (s *controlService) readState() (map[string]string, error) {
	allowed := map[string]bool{
		"current_version": true, "current_image": true, "domain": true,
		"vpn_network": true, "vpn_port": true, "openconnect_checked_at": true, "updated_at": true,
	}
	content, missing, err := readRegularFile(s.config.StatePath, maxStateBytes)
	if missing {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, controlFailure(500, "invalid_state", "The managed state file is unreadable.")
	}
	result := map[string]string{}
	for _, line := range strings.Split(string(content), "\n") {
		key, value, found := strings.Cut(line, "=")
		if found && allowed[key] {
			result[key] = value
		}
	}
	return result, nil
}

func (s *controlService) readUsernames() ([]string, error) {
	content, missing, err := readRegularFile(s.config.PasswordPath, maxPasswordFileBytes)
	if missing {
		return []string{}, nil
	}
	if err != nil {
		return nil, controlFailure(500, "invalid_password_file", "The password database is unreadable.")
	}
	unique := map[string]bool{}
	for _, line := range strings.Split(string(content), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		username, _, _ := strings.Cut(line, ":")
		if usernamePattern.MatchString(username) {
			unique[username] = true
		}
	}
	result := make([]string, 0, len(unique))
	for username := range unique {
		result = append(result, username)
	}
	sort.Slice(result, func(i, j int) bool {
		left, right := strings.ToLower(result[i]), strings.ToLower(result[j])
		if left == right {
			return result[i] < result[j]
		}
		return left < right
	})
	return result, nil
}

func (s *controlService) certificateInfo(domain any) map[string]any {
	empty := map[string]any{"expires_at": nil, "days_remaining": nil, "valid": false}
	domainName, ok := domain.(string)
	if !ok {
		return empty
	}
	content, missing, err := readRegularFile(s.config.CertificatePath, maxCertificateBytes)
	if err != nil || missing {
		return empty
	}
	block, _ := pem.Decode(content)
	if block == nil || block.Type != "CERTIFICATE" {
		return empty
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return empty
	}
	now := s.now().UTC()
	remainingDays := int(math.Floor(certificate.NotAfter.Sub(now).Hours() / 24))
	valid := !now.Before(certificate.NotBefore) && now.Before(certificate.NotAfter) && certificate.VerifyHostname(domainName) == nil
	return map[string]any{
		"expires_at":     certificate.NotAfter.UTC().Truncate(time.Second).Format(time.RFC3339),
		"days_remaining": remainingDays,
		"valid":          valid,
	}
}

func readRegularFile(path string, maximum int64) ([]byte, bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, true, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Size() > maximum {
		return nil, false, fmt.Errorf("unsafe file")
	}
	content, err := os.ReadFile(path)
	if err != nil || int64(len(content)) > maximum {
		return nil, false, fmt.Errorf("unreadable file")
	}
	return content, false, nil
}

func randomPassword() (string, error) {
	buffer := make([]byte, 24)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buffer), nil
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func normalizeKey(value string) string {
	var builder strings.Builder
	for _, character := range strings.ToLower(value) {
		if unicode.IsLetter(character) || unicode.IsDigit(character) {
			builder.WriteRune(character)
		}
	}
	return builder.String()
}

func findValue(data any, wanted string) any {
	normalized := normalizeKey(wanted)
	switch value := data.(type) {
	case map[string]any:
		for key, nested := range value {
			if normalizeKey(key) == normalized {
				return nested
			}
		}
		for _, nested := range value {
			if found := findValue(nested, wanted); found != nil {
				return found
			}
		}
	case []any:
		for _, nested := range value {
			if found := findValue(nested, wanted); found != nil {
				return found
			}
		}
	}
	return nil
}

func activeUsernames(data any) []string {
	result := []string{}
	switch value := data.(type) {
	case map[string]any:
		for key, nested := range value {
			if normalizeKey(key) == "username" {
				if username, ok := nested.(string); ok && usernamePattern.MatchString(username) {
					result = append(result, username)
				}
				break
			}
		}
		for _, nested := range value {
			result = append(result, activeUsernames(nested)...)
		}
	case []any:
		for _, nested := range value {
			result = append(result, activeUsernames(nested)...)
		}
	}
	return result
}

func normalizedConnections(data any, now time.Time) []map[string]any {
	rows, ok := data.([]any)
	if !ok {
		return []map[string]any{}
	}
	connections := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		object, ok := row.(map[string]any)
		if !ok {
			continue
		}
		id := safePositiveInt(findValue(object, "ID"))
		username, usernameOK := safeUsername(findValue(object, "Username"))
		remoteIP := safeIPAddress(firstValue(object, "Remote IP", "Remote IP address", "IP Real"))
		vpnIP := safeIPAddress(firstValue(object, "VPN IP", "IPv4", "IP", "IP Remote"))
		if id == 0 || !usernameOK || remoteIP == nil || vpnIP == nil {
			continue
		}
		connectedAt, duration := connectionTime(object, now)
		connections = append(connections, map[string]any{
			"id": id, "username": username, "client_ip": remoteIP, "vpn_ip": vpnIP,
			"protocol": "OpenConnect", "connected_at": connectedAt, "duration_seconds": duration,
		})
	}
	sort.Slice(connections, func(i, j int) bool {
		left, _ := connections[i]["duration_seconds"].(int)
		right, _ := connections[j]["duration_seconds"].(int)
		if left == right {
			return connections[i]["id"].(int) < connections[j]["id"].(int)
		}
		return left > right
	})
	return connections
}

func connectionTime(object map[string]any, now time.Time) (any, int) {
	raw := safePositiveInt(firstValue(object, "raw_connected_at", "raw connected at", "raw_since"))
	if raw > 0 {
		connected := time.Unix(int64(raw), 0).UTC()
		if !connected.After(now.Add(time.Minute)) {
			duration := int(now.Sub(connected).Seconds())
			if duration < 0 {
				duration = 0
			}
			return connected.Format(time.RFC3339), duration
		}
	}
	value, ok := firstValue(object, "Connected at", "Session started at", "Since").(string)
	if !ok {
		return nil, 0
	}
	for _, layout := range []string{"2006-01-02 15:04", "2006-01-02 15:04:05", time.RFC3339} {
		if parsed, err := time.ParseInLocation(layout, value, time.UTC); err == nil {
			parsed = parsed.UTC()
			duration := int(now.Sub(parsed).Seconds())
			if duration < 0 {
				duration = 0
			}
			return parsed.Format(time.RFC3339), duration
		}
	}
	return nil, 0
}

func normalizedJournalEvent(raw map[string]any) map[string]any {
	occurred := safeNonnegativeInt64(raw["occurred_at"], 0)
	if occurred < 1 {
		return nil
	}
	event, eventOK := raw["event"].(string)
	if !eventOK || (event != "connected" && event != "disconnected") {
		return nil
	}
	username, usernameOK := safeUsername(raw["username"])
	if !usernameOK {
		return nil
	}
	remoteIP := safeIPAddress(raw["remote_ip"])
	vpnIP := safeIPAddress(raw["vpn_ip"])
	if remoteIP == nil || vpnIP == nil {
		return nil
	}
	return map[string]any{
		"occurred_at": time.Unix(occurred, 0).UTC().Format(time.RFC3339),
		"event":       event, "username": username, "client_ip": remoteIP, "vpn_ip": vpnIP,
		"protocol":         "OpenConnect",
		"duration_seconds": safeNonnegativeInt(raw["duration_seconds"], 0),
		"bytes_in":         safeNonnegativeInt64(raw["bytes_in"], 0),
		"bytes_out":        safeNonnegativeInt64(raw["bytes_out"], 0),
	}
}

func firstValue(object map[string]any, names ...string) any {
	for _, name := range names {
		if value := findValue(object, name); value != nil {
			return value
		}
	}
	return nil
}

func safeUsername(value any) (string, bool) {
	username, ok := value.(string)
	return username, ok && usernamePattern.MatchString(username)
}

func safeIPAddress(value any) any {
	text, ok := value.(string)
	if !ok || len(text) > 64 {
		return nil
	}
	if host, _, err := net.SplitHostPort(text); err == nil {
		text = host
	}
	parsed := net.ParseIP(strings.Trim(text, "[]"))
	if parsed == nil {
		return nil
	}
	return parsed.String()
}

func safePositiveInt(value any) int {
	parsed := safeNonnegativeInt(value, 0)
	if parsed < 1 {
		return 0
	}
	return parsed
}

func safeNonnegativeInt(value any, fallback int) int {
	var parsed int64
	var err error
	switch number := value.(type) {
	case json.Number:
		parsed, err = number.Int64()
	case float64:
		if math.Trunc(number) != number {
			return fallback
		}
		parsed = int64(number)
	case int:
		parsed = int64(number)
	case int64:
		parsed = number
	case string:
		parsed, err = strconv.ParseInt(number, 10, 32)
	default:
		return fallback
	}
	if err != nil || parsed < 0 || parsed > 2147483647 {
		return fallback
	}
	return int(parsed)
}

func safeNonnegativeInt64(value any, fallback int64) int64 {
	var parsed int64
	var err error
	switch number := value.(type) {
	case json.Number:
		parsed, err = number.Int64()
	case float64:
		if math.Trunc(number) != number || number > 9007199254740991 {
			return fallback
		}
		parsed = int64(number)
	case int:
		parsed = int64(number)
	case int64:
		parsed = number
	case string:
		parsed, err = strconv.ParseInt(number, 10, 64)
	default:
		return fallback
	}
	if err != nil || parsed < 0 || parsed > 9007199254740991 {
		return fallback
	}
	return parsed
}

func safeVersion(value string) any {
	if versionPattern.MatchString(value) {
		return value
	}
	return nil
}

func safeImage(value string) any {
	if imagePattern.MatchString(value) {
		return value
	}
	return nil
}

func safeDomain(value string) any {
	if value == "" || !strings.Contains(value, ".") || !domainPattern.MatchString(value) || strings.Contains(value, "..") {
		return nil
	}
	for _, label := range strings.Split(value, ".") {
		if label == "" || len(label) > 63 {
			return nil
		}
	}
	return strings.ToLower(value)
}

func safeNetwork(value string) any {
	ip, network, err := net.ParseCIDR(value)
	if err != nil || ip.To4() == nil || !ip.Equal(network.IP) || network.String() != value {
		return nil
	}
	return network.String()
}

func safePort(value string) any {
	port, err := strconv.Atoi(value)
	if err != nil || port < 1 || port > 65535 {
		return nil
	}
	return port
}

func safeTimestamp(value string) any {
	if !timestampPattern.MatchString(value) {
		return nil
	}
	parsed, err := time.Parse("2006-01-02T15:04:05Z", value)
	if err != nil || parsed.Format("2006-01-02T15:04:05Z") != value {
		return nil
	}
	return value
}
