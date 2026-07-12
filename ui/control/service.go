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
		"healthcheck":     {"request_id": true, "action": true},
		"overview":        {"request_id": true, "action": true},
		"list_users":      {"request_id": true, "action": true},
		"add_user":        {"request_id": true, "action": true, "username": true},
		"rotate_password": {"request_id": true, "action": true, "username": true, "terminate_sessions": true},
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
