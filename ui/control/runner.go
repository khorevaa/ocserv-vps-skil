//go:build linux

package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os/exec"
	"strings"
	"time"
)

const maxCommandOutputBytes = 1024 * 1024

var safeCommandEnvironment = []string{
	"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
	"LANG=C.UTF-8",
	"LC_ALL=C.UTF-8",
}

type commandRunner interface {
	Run(argv []string, stdin string) (string, error)
}

type execRunner struct{ timeout time.Duration }

func (r execRunner) Run(argv []string, stdin string) (string, error) {
	if len(argv) == 0 {
		return "", backendUnavailable(errors.New("empty command"))
	}
	ctx, cancel := context.WithTimeout(context.Background(), r.timeout)
	defer cancel()
	command := exec.CommandContext(ctx, argv[0], argv[1:]...)
	command.Env = safeCommandEnvironment
	if stdin != "" {
		command.Stdin = strings.NewReader(stdin)
	}
	var stdout bytes.Buffer
	command.Stdout = &limitedBuffer{buffer: &stdout, remaining: maxCommandOutputBytes + 1}
	command.Stderr = &limitedBuffer{buffer: &bytes.Buffer{}, remaining: 64 * 1024}
	if err := command.Run(); err != nil {
		if ctx.Err() != nil || errors.Is(err, exec.ErrNotFound) {
			return "", backendUnavailable(err)
		}
		return "", controlFailure(503, "backend_error", "The ocserv backend rejected the operation.")
	}
	if stdout.Len() > maxCommandOutputBytes {
		return "", controlFailure(503, "backend_error", "The ocserv backend returned too much data.")
	}
	return stdout.String(), nil
}

type limitedBuffer struct {
	buffer    *bytes.Buffer
	remaining int
}

func (w *limitedBuffer) Write(value []byte) (int, error) {
	original := len(value)
	if w.remaining > 0 {
		part := value
		if len(part) > w.remaining {
			part = part[:w.remaining]
		}
		_, _ = w.buffer.Write(part)
		w.remaining -= len(part)
	}
	return original, nil
}

var _ io.Writer = (*limitedBuffer)(nil)
