package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type config struct {
	DataFile              string
	ControlSocket         string
	WebSocket             string
	SessionKeyFile        string
	AccessSecretFile      string
	UIImage               string
	AllowedOrigin         string
	AllowedHost           string
	SessionTTLSeconds     int64
	AuditRetentionSeconds int64
	AuditMaxRows          int
	ControlTimeoutSeconds int
	MaxRequestBytes       int64
	RequireRootSecrets    bool
}

func env(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func envInt64(name string, fallback, minimum, maximum int64) (int64, error) {
	value, err := strconv.ParseInt(env(name, strconv.FormatInt(fallback, 10)), 10, 64)
	if err != nil || value < minimum || value > maximum {
		return 0, fmt.Errorf("invalid %s", name)
	}
	return value, nil
}

func loadConfig() (config, error) {
	var result config
	var err error
	result.DataFile = env("OCSERV_UI_JSON", "/var/lib/ocserv-ui/state.json")
	result.ControlSocket = env("OCSERV_UI_CONTROL_SOCKET", "/run/ocserv-ui/control.sock")
	result.WebSocket = env("OCSERV_UI_WEB_SOCKET", "/run/ocserv-ui-web/web.sock")
	result.SessionKeyFile = env("OCSERV_UI_SESSION_KEY_FILE", "/run/secrets/session-key")
	result.AccessSecretFile = env("OCSERV_UI_ACCESS_SECRET_FILE", "/run/secrets/access-secret")
	result.UIImage = strings.TrimSpace(os.Getenv("OCSERV_UI_IMAGE_NAME"))
	result.AllowedOrigin = strings.TrimSpace(os.Getenv("OCSERV_UI_ALLOWED_ORIGIN"))
	if result.AllowedOrigin == "" {
		return result, fmt.Errorf("OCSERV_UI_ALLOWED_ORIGIN is required")
	}
	if !strings.HasPrefix(result.AllowedOrigin, "http://ocserv-") || !strings.Contains(result.AllowedOrigin, ".localhost:") {
		return result, fmt.Errorf("allowed origin must be the isolated localhost forward")
	}
	result.AllowedHost = strings.TrimPrefix(result.AllowedOrigin, "http://")
	if strings.ContainsAny(result.AllowedHost, "/?#@") {
		return result, fmt.Errorf("invalid allowed origin")
	}
	result.SessionTTLSeconds, err = envInt64("OCSERV_UI_SESSION_TTL", 12*60*60, 60, 7*24*60*60)
	if err != nil {
		return result, err
	}
	result.AuditRetentionSeconds, err = envInt64("OCSERV_UI_AUDIT_RETENTION", 90*24*60*60, 60, 3650*24*60*60)
	if err != nil {
		return result, err
	}
	auditRows, err := envInt64("OCSERV_UI_AUDIT_MAX_ROWS", 10000, 1, 1000000)
	if err != nil {
		return result, err
	}
	result.AuditMaxRows = int(auditRows)
	controlTimeout, err := envInt64("OCSERV_UI_CONTROL_TIMEOUT", 35, 1, 120)
	if err != nil {
		return result, err
	}
	result.ControlTimeoutSeconds = int(controlTimeout)
	result.MaxRequestBytes, err = envInt64("OCSERV_UI_MAX_REQUEST_BYTES", 16*1024, 1024, 1024*1024)
	if err != nil {
		return result, err
	}
	requireRoot := strings.ToLower(env("OCSERV_UI_REQUIRE_ROOT_SECRETS", "true"))
	result.RequireRootSecrets = requireRoot != "0" && requireRoot != "false" && requireRoot != "no"
	for _, path := range []string{result.DataFile, result.ControlSocket, result.WebSocket, result.SessionKeyFile, result.AccessSecretFile} {
		if !filepath.IsAbs(path) {
			return result, fmt.Errorf("managed paths must be absolute")
		}
	}
	return result, nil
}
