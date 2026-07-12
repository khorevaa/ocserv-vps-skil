package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

var version = "dev"

func validateRuntimeDirectory(socketPath string) error {
	if !filepath.IsAbs(socketPath) || filepath.Base(socketPath) == "." {
		return fmt.Errorf("web socket path must be absolute")
	}
	parent := filepath.Dir(socketPath)
	resolved, err := filepath.EvalSymlinks(parent)
	if err != nil || resolved != parent {
		return fmt.Errorf("web socket parent cannot contain symlinks")
	}
	info, err := os.Lstat(parent)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o700 {
		return fmt.Errorf("web socket parent must be a real mode 0700 directory")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) || stat.Gid != uint32(os.Getegid()) {
		return fmt.Errorf("web socket parent ownership is unsafe")
	}
	return nil
}

func listenUnixSafely(path string) (*net.UnixListener, error) {
	if err := validateRuntimeDirectory(path); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(path); err == nil {
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0o600 || stat.Uid != uint32(os.Geteuid()) || stat.Gid != uint32(os.Getegid()) {
			return nil, fmt.Errorf("refusing to replace unsafe web socket")
		}
		connection, dialErr := net.DialTimeout("unix", path, 200*time.Millisecond)
		if dialErr == nil {
			_ = connection.Close()
			return nil, fmt.Errorf("web socket is already accepting connections")
		}
		if !errors.Is(dialErr, syscall.ECONNREFUSED) && !errors.Is(dialErr, syscall.ENOENT) {
			return nil, fmt.Errorf("cannot prove existing web socket is stale: %w", dialErr)
		}
		if err = os.Remove(path); err != nil {
			return nil, err
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	oldMask := syscall.Umask(0o177)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	syscall.Umask(oldMask)
	if err != nil {
		return nil, err
	}
	listener.SetUnlinkOnClose(false)
	if err = os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		return nil, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		_ = listener.Close()
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0o600 || stat.Uid != uint32(os.Geteuid()) || stat.Gid != uint32(os.Getegid()) {
		_ = listener.Close()
		return nil, fmt.Errorf("web socket ownership or mode verification failed")
	}
	return listener, nil
}

func healthcheck(path string) error {
	if err := validateRuntimeDirectory(path); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0o600 {
		return fmt.Errorf("unsafe socket")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) || stat.Gid != uint32(os.Getegid()) {
		return fmt.Errorf("unsafe socket ownership")
	}
	connection, err := net.DialTimeout("unix", path, 2*time.Second)
	if err != nil {
		return err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err = io.WriteString(connection, "GET /api/v1/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"); err != nil {
		return err
	}
	response, err := http.ReadResponse(bufio.NewReader(connection), &http.Request{Method: http.MethodGet})
	if err != nil {
		return err
	}
	defer response.Body.Close()
	var body map[string]string
	if response.StatusCode != 200 || json.NewDecoder(io.LimitReader(response.Body, 8192)).Decode(&body) != nil || body["status"] != "ok" {
		return fmt.Errorf("health response failed")
	}
	return nil
}

func run() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	app, err := newApplication(cfg)
	if err != nil {
		return err
	}
	listener, err := listenUnixSafely(cfg.WebSocket)
	if err != nil {
		return err
	}
	server := &http.Server{Handler: app, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 45 * time.Second, WriteTimeout: 45 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 * 1024}
	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, syscall.SIGINT, syscall.SIGTERM)
	done := make(chan struct{})
	go func() { <-interrupt; _ = listener.Close(); close(done) }()
	err = server.Serve(listener)
	if err != nil && !errors.Is(err, http.ErrServerClosed) && !errors.Is(err, net.ErrClosed) {
		return err
	}
	select {
	case <-done:
	default:
	}
	return nil
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "healthcheck" {
		path := os.Getenv("OCSERV_UI_WEB_SOCKET")
		if path == "" {
			path = "/run/ocserv-ui-web/web.sock"
		}
		if err := healthcheck(path); err != nil {
			log.Printf("healthcheck failed: %v", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) != 1 {
		fmt.Fprintln(os.Stderr, "Usage: ocserv-ui [healthcheck]")
		os.Exit(2)
	}
	if err := run(); err != nil {
		log.Printf("ocserv UI failed: %v", err)
		os.Exit(1)
	}
}
