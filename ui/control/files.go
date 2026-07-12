//go:build linux

package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

type fileLock struct{ file *os.File }

func acquireFileLock(path string) (*fileLock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return nil, controlFailure(500, "lock_failed", "The ocserv operation lock is unavailable.")
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, controlFailure(500, "lock_failed", "The ocserv operation lock is unavailable.")
	}
	if err = file.Chmod(0o600); err != nil {
		_ = file.Close()
		return nil, controlFailure(500, "lock_failed", "The ocserv operation lock is unavailable.")
	}
	if err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, controlFailure(409, "operation_busy", "Another ocserv operation is already running.")
		}
		return nil, controlFailure(500, "lock_failed", "The ocserv operation lock is unavailable.")
	}
	return &fileLock{file: file}, nil
}

func (l *fileLock) Close() {
	if l == nil || l.file == nil {
		return
	}
	_ = syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN)
	_ = l.file.Close()
}

type passwordSnapshot struct {
	target   string
	backup   string
	existed  bool
	mode     os.FileMode
	uid, gid int
}

func capturePasswordSnapshot(target string) (*passwordSnapshot, error) {
	snapshot := &passwordSnapshot{target: target, uid: -1, gid: -1}
	if err := os.MkdirAll(filepath.Dir(target), 0o750); err != nil {
		return nil, controlFailure(500, "unsafe_password_file", "The password database cannot be protected.")
	}
	info, err := os.Lstat(target)
	if errors.Is(err, os.ErrNotExist) {
		file, createErr := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if createErr != nil {
			return nil, controlFailure(500, "unsafe_password_file", "The password database cannot be created safely.")
		}
		if closeErr := file.Close(); closeErr != nil {
			_ = os.Remove(target)
			return nil, controlFailure(500, "unsafe_password_file", "The password database cannot be created safely.")
		}
		return snapshot, nil
	}
	if err != nil || !info.Mode().IsRegular() {
		return nil, controlFailure(500, "unsafe_password_file", "The password database is not a regular file.")
	}
	snapshot.existed = true
	snapshot.mode = info.Mode().Perm()
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		snapshot.uid, snapshot.gid = int(stat.Uid), int(stat.Gid)
	}

	input, err := os.Open(target)
	if err != nil {
		return nil, controlFailure(500, "unsafe_password_file", "The password database cannot be protected.")
	}
	defer input.Close()
	output, err := os.CreateTemp(filepath.Dir(target), ".ocpasswd.backup.*")
	if err != nil {
		return nil, controlFailure(500, "unsafe_password_file", "The password database cannot be protected.")
	}
	snapshot.backup = output.Name()
	cleanup := func() {
		_ = output.Close()
		_ = os.Remove(snapshot.backup)
		snapshot.backup = ""
	}
	if err = output.Chmod(0o600); err != nil {
		cleanup()
		return nil, controlFailure(500, "unsafe_password_file", "The password database cannot be protected.")
	}
	if _, err = io.Copy(output, input); err != nil {
		cleanup()
		return nil, controlFailure(500, "unsafe_password_file", "The password database cannot be protected.")
	}
	if err = output.Sync(); err != nil {
		cleanup()
		return nil, controlFailure(500, "unsafe_password_file", "The password database cannot be protected.")
	}
	if err = output.Close(); err != nil {
		_ = os.Remove(snapshot.backup)
		snapshot.backup = ""
		return nil, controlFailure(500, "unsafe_password_file", "The password database cannot be protected.")
	}
	return snapshot, nil
}

func (s *passwordSnapshot) Rollback() error {
	if !s.existed {
		return os.Remove(s.target)
	}
	if s.backup == "" {
		return fmt.Errorf("password snapshot is incomplete")
	}
	if err := os.Rename(s.backup, s.target); err != nil {
		return err
	}
	s.backup = ""
	if err := os.Chmod(s.target, s.mode); err != nil {
		return err
	}
	if s.uid >= 0 && s.gid >= 0 {
		if err := os.Chown(s.target, s.uid, s.gid); err != nil && !errors.Is(err, syscall.EPERM) {
			return err
		}
	}
	return nil
}

func (s *passwordSnapshot) Commit() error {
	if s.backup == "" {
		return nil
	}
	err := os.Remove(s.backup)
	if err == nil || errors.Is(err, os.ErrNotExist) {
		s.backup = ""
		return nil
	}
	return err
}
