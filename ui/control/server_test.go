//go:build linux

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"testing"
	"time"
)

func TestUnixSocketProtocolAndHealthcheck(t *testing.T) {
	service, _, cfg := testService(t)
	server, err := newControlServer(cfg, service)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- server.serve(ctx) }()
	defer func() {
		cancel()
		server.close()
		<-done
	}()

	connection, err := net.DialTimeout("unix", cfg.SocketPath, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = connection.Write([]byte(`{"request_id":"socket-1","action":"list_users"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	var response protocolResponse
	if err = json.NewDecoder(bufio.NewReader(connection)).Decode(&response); err != nil {
		t.Fatal(err)
	}
	_ = connection.Close()
	if !response.OK || response.RequestID != "socket-1" {
		t.Fatalf("unexpected response: %#v", response)
	}
	if err = healthcheck(cfg); err != nil {
		t.Fatal(err)
	}
	if info, statErr := os.Stat(cfg.SocketPath); statErr != nil || info.Mode().Perm() != 0o660 {
		t.Fatalf("unsafe socket mode: info=%#v err=%v", info, statErr)
	}
}

func TestServerRejectsOversizedRequest(t *testing.T) {
	service, _, cfg := testService(t)
	server, err := newControlServer(cfg, service)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- server.serve(ctx) }()
	connection, err := net.DialTimeout("unix", cfg.SocketPath, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	request := make([]byte, maxRequestBytes+1)
	for index := range request {
		request[index] = 'a'
	}
	request = append(request, '\n')
	_, _ = connection.Write(request)
	var response protocolResponse
	_ = json.NewDecoder(bufio.NewReader(connection)).Decode(&response)
	_ = connection.Close()
	cancel()
	server.close()
	<-done
	if response.Error == nil || response.Error.Status != 413 || response.Error.Code != "request_too_large" {
		t.Fatalf("unexpected response: %#v", response)
	}
}
