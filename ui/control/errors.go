//go:build linux

package main

import "fmt"

type controlError struct {
	Status  int
	Code    string
	Message string
}

func (e *controlError) Error() string { return e.Message }

func controlFailure(status int, code, message string) error {
	return &controlError{Status: status, Code: code, Message: message}
}

func backendUnavailable(err error) error {
	return fmt.Errorf("%w: %v", controlFailure(503, "backend_unavailable", "The ocserv backend is unavailable."), err)
}
