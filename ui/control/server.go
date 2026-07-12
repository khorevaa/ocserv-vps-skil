//go:build linux

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

const maxRequestBytes = 64 * 1024

type protocolError struct {
	Status  int    `json:"status"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

type protocolResponse struct {
	RequestID any            `json:"request_id"`
	OK        bool           `json:"ok"`
	Result    any            `json:"result,omitempty"`
	Error     *protocolError `json:"error,omitempty"`
}

func safeRequestID(request map[string]any) any {
	if request == nil {
		return nil
	}
	value, exists := request["request_id"]
	if !exists {
		return nil
	}
	switch id := value.(type) {
	case string:
		if len(id) < 1 || len(id) > 128 || !utf8.ValidString(id) {
			return nil
		}
		for _, character := range id {
			if character < 32 {
				return nil
			}
		}
		return id
	case json.Number:
		integer, err := strconv.ParseInt(string(id), 10, 64)
		if err == nil && integer > -(1<<53) && integer < 1<<53 {
			return id
		}
	}
	return nil
}

func processRequest(service *controlService, request any) protocolResponse {
	object, ok := request.(map[string]any)
	requestID := safeRequestID(object)
	if !ok {
		return failureResponse(nil, controlFailure(400, "invalid_request", "The request must be a JSON object."))
	}
	result, err := service.dispatch(object)
	if err == nil {
		return protocolResponse{RequestID: requestID, OK: true, Result: result}
	}
	return failureResponse(requestID, err)
}

func failureResponse(requestID any, err error) protocolResponse {
	var expected *controlError
	if errors.As(err, &expected) {
		return protocolResponse{
			RequestID: requestID,
			OK:        false,
			Error:     &protocolError{Status: expected.Status, Code: expected.Code, Message: expected.Message},
		}
	}
	log.Printf("unhandled control failure: %v\n%s", err, debug.Stack())
	return protocolResponse{
		RequestID: requestID,
		OK:        false,
		Error: &protocolError{
			Status: 500, Code: "internal_error", Message: "The control service could not complete the operation.",
		},
	}
}

type controlServer struct {
	config   config
	service  *controlService
	listener *net.UnixListener
	wait     sync.WaitGroup
}

func newControlServer(cfg config, service *controlService) (*controlServer, error) {
	if err := os.MkdirAll(filepath.Dir(cfg.SocketPath), 0o750); err != nil {
		return nil, err
	}
	if err := os.Chmod(filepath.Dir(cfg.SocketPath), 0o710); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(cfg.SocketPath); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("refusing to replace non-socket path: %s", cfg.SocketPath)
		}
		if err = os.Remove(cfg.SocketPath); err != nil {
			return nil, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	address := &net.UnixAddr{Name: cfg.SocketPath, Net: "unix"}
	listener, err := net.ListenUnix("unix", address)
	if err != nil {
		return nil, err
	}
	listener.SetUnlinkOnClose(false)
	if err = os.Chmod(cfg.SocketPath, 0o660); err != nil {
		_ = listener.Close()
		_ = os.Remove(cfg.SocketPath)
		return nil, err
	}
	return &controlServer{config: cfg, service: service, listener: listener}, nil
}

func (s *controlServer) serve(ctx context.Context) error {
	go func() {
		<-ctx.Done()
		_ = s.listener.Close()
	}()
	for {
		connection, err := s.listener.AcceptUnix()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				break
			}
			return err
		}
		s.wait.Add(1)
		go func() {
			defer s.wait.Done()
			s.handle(connection)
		}()
	}
	s.wait.Wait()
	return nil
}

func (s *controlServer) close() {
	_ = s.listener.Close()
	s.wait.Wait()
	if info, err := os.Lstat(s.config.SocketPath); err == nil && info.Mode()&os.ModeSocket != 0 {
		_ = os.Remove(s.config.SocketPath)
	}
}

func (s *controlServer) handle(connection *net.UnixConn) {
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(10 * time.Second))
	uid, err := peerUID(connection)
	if err != nil || (uid != 0 && uid != s.config.AllowedUID) {
		s.send(connection, failureResponse(nil, controlFailure(403, "peer_forbidden", "The peer is not authorized.")))
		return
	}
	reader := bufio.NewReaderSize(connection, maxRequestBytes+1)
	line, err := reader.ReadBytes('\n')
	if len(line) > maxRequestBytes {
		s.send(connection, failureResponse(nil, controlFailure(413, "request_too_large", "The request is too large.")))
		return
	}
	if err != nil && !errors.Is(err, io.EOF) {
		return
	}
	decoder := json.NewDecoder(strings.NewReader(string(line)))
	decoder.UseNumber()
	var request any
	if err = decoder.Decode(&request); err != nil {
		s.send(connection, failureResponse(nil, controlFailure(400, "invalid_json", "The request is not valid JSON.")))
		return
	}
	var trailing any
	if err = decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		s.send(connection, failureResponse(nil, controlFailure(400, "invalid_json", "The request is not valid JSON.")))
		return
	}
	object, _ := request.(map[string]any)
	if uid != s.config.AllowedUID {
		action, _ := object["action"].(string)
		if action != "healthcheck" {
			s.send(connection, failureResponse(safeRequestID(object), controlFailure(403, "peer_forbidden", "The peer is not authorized.")))
			return
		}
	}
	s.send(connection, processRequest(s.service, request))
}

func (s *controlServer) send(connection *net.UnixConn, response protocolResponse) {
	encoded, err := json.Marshal(response)
	if err != nil {
		encoded = []byte(`{"request_id":null,"ok":false,"error":{"status":500,"code":"internal_error","message":"The control service could not complete the operation."}}`)
	}
	encoded = append(encoded, '\n')
	_, _ = connection.Write(encoded)
}

func peerUID(connection *net.UnixConn) (uint32, error) {
	raw, err := connection.SyscallConn()
	if err != nil {
		return 0, err
	}
	var credentials *syscall.Ucred
	var socketErr error
	if err = raw.Control(func(fileDescriptor uintptr) {
		credentials, socketErr = syscall.GetsockoptUcred(int(fileDescriptor), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	}); err != nil {
		return 0, err
	}
	if socketErr != nil || credentials == nil {
		return 0, socketErr
	}
	return credentials.Uid, nil
}

func healthcheck(cfg config) error {
	connection, err := net.DialTimeout("unix", cfg.SocketPath, 2*time.Second)
	if err != nil {
		return err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err = io.WriteString(connection, `{"request_id":"healthcheck","action":"healthcheck"}`+"\n"); err != nil {
		return err
	}
	var response protocolResponse
	decoder := json.NewDecoder(io.LimitReader(connection, 4097))
	if err = decoder.Decode(&response); err != nil {
		return err
	}
	result, ok := response.Result.(map[string]any)
	if !response.OK || !ok || result["status"] != "ok" {
		return fmt.Errorf("control healthcheck failed")
	}
	return nil
}
