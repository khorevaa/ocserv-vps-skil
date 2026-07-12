//go:build linux

package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

type config struct {
	SocketPath      string
	AllowedUID      uint32
	StatePath       string
	PasswordPath    string
	CertificatePath string
	JournalPath     string
	OCCTLSocket     string
	OperationLock   string
	OCPasswordBin   string
	OCCTLBin        string
	CommandTimeout  time.Duration
}

func defaultConfig() config {
	return config{
		SocketPath:      "/run/ocserv-ui/control.sock",
		AllowedUID:      10001,
		StatePath:       "/opt/ocserv-vps/ui-public/state",
		PasswordPath:    "/opt/ocserv-vps/config/ocpasswd",
		CertificatePath: "/opt/ocserv-vps/ui-public/fullchain.pem",
		JournalPath:     "/opt/ocserv-vps/logs/vpn-events.jsonl",
		OCCTLSocket:     "/run/ocserv-control/occtl.sock",
		OperationLock:   "/opt/ocserv-vps/locks/operation.lock",
		OCPasswordBin:   "/usr/local/bin/ocpasswd",
		OCCTLBin:        "/usr/local/bin/occtl",
		CommandTimeout:  8 * time.Second,
	}
}

func configFromEnvironment() (config, error) {
	cfg := defaultConfig()
	path := func(name, current string) string {
		if value := os.Getenv(name); value != "" {
			return value
		}
		return current
	}
	cfg.SocketPath = path("OCSERV_UI_CONTROL_SOCKET", cfg.SocketPath)
	cfg.StatePath = path("OCSERV_UI_STATE_FILE", cfg.StatePath)
	cfg.PasswordPath = path("OCSERV_UI_OCPASSWD_FILE", cfg.PasswordPath)
	cfg.CertificatePath = path("OCSERV_UI_CERTIFICATE_FILE", cfg.CertificatePath)
	cfg.JournalPath = path("OCSERV_UI_JOURNAL_FILE", cfg.JournalPath)
	cfg.OCCTLSocket = path("OCSERV_UI_OCCTL_SOCKET", cfg.OCCTLSocket)
	cfg.OperationLock = path("OCSERV_UI_OPERATION_LOCK", cfg.OperationLock)
	cfg.OCPasswordBin = path("OCSERV_UI_OCPASSWD_BIN", cfg.OCPasswordBin)
	cfg.OCCTLBin = path("OCSERV_UI_OCCTL_BIN", cfg.OCCTLBin)

	if value := os.Getenv("OCSERV_UI_ALLOWED_UID"); value != "" {
		parsed, err := strconv.ParseUint(value, 10, 31)
		if err != nil {
			return config{}, fmt.Errorf("invalid OCSERV_UI_ALLOWED_UID")
		}
		cfg.AllowedUID = uint32(parsed)
	}
	if value := os.Getenv("OCSERV_UI_COMMAND_TIMEOUT"); value != "" {
		seconds, err := strconv.ParseFloat(value, 64)
		if err != nil || seconds < 0.1 || seconds > 60 {
			return config{}, fmt.Errorf("OCSERV_UI_COMMAND_TIMEOUT must be between 0.1 and 60 seconds")
		}
		cfg.CommandTimeout = time.Duration(seconds * float64(time.Second))
	}
	return cfg, nil
}
