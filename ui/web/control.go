package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"time"
)

type controlError struct {
	Status        int
	Code, Message string
}

func (e *controlError) Error() string { return e.Message }

type controlClient struct {
	socket  string
	timeout time.Duration
}

func requestID() (string, error) {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

func (c controlClient) request(action string, payload map[string]any) (json.RawMessage, error) {
	id, err := requestID()
	if err != nil {
		return nil, err
	}
	request := map[string]any{"request_id": id, "action": action}
	for key, value := range payload {
		request[key] = value
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	connection, err := net.DialTimeout("unix", c.socket, c.timeout)
	if err != nil {
		return nil, &controlError{503, "control_unavailable", "control service is unavailable"}
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(c.timeout))
	if _, err = connection.Write(append(encoded, '\n')); err != nil {
		return nil, &controlError{503, "control_unavailable", "control service is unavailable"}
	}
	reader := bufio.NewReaderSize(connection, 1024*1024+1)
	line, err := reader.ReadBytes('\n')
	if err != nil || len(line) > 1024*1024 || len(line) == 0 {
		return nil, &controlError{503, "control_unavailable", "control service is unavailable"}
	}
	var response struct {
		RequestID string          `json:"request_id"`
		OK        bool            `json:"ok"`
		Result    json.RawMessage `json:"result"`
		Error     *struct {
			Status  int    `json:"status"`
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(line, &response) != nil || response.RequestID != id {
		return nil, &controlError{503, "control_unavailable", "control service is unavailable"}
	}
	if response.OK {
		return response.Result, nil
	}
	if response.Error == nil {
		return nil, &controlError{503, "control_unavailable", "control service is unavailable"}
	}
	status := response.Error.Status
	if status != 400 && status != 403 && status != 404 && status != 409 && status != 422 && status != 500 && status != 503 {
		status = 502
	}
	return nil, &controlError{status, response.Error.Code, response.Error.Message}
}

func asObject(raw json.RawMessage) (map[string]any, error) {
	var value map[string]any
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil || value == nil {
		return nil, fmt.Errorf("invalid control response")
	}
	return value, nil
}

func nested(object map[string]any, key string) map[string]any {
	value, _ := object[key].(map[string]any)
	return value
}

func overviewForWeb(raw json.RawMessage) (map[string]any, error) {
	result, err := asObject(raw)
	if err != nil {
		return nil, err
	}
	service, server, certificate := nested(result, "service"), nested(result, "server"), nested(result, "certificate")
	if service == nil || server == nil || certificate == nil {
		return nil, fmt.Errorf("invalid control response")
	}
	return map[string]any{
		"service":                map[string]any{"status": service["status"], "uptime_seconds": service["uptime_seconds"], "version": server["version"], "image": server["image"]},
		"vpn":                    map[string]any{"domain": server["domain"], "active_connections": service["active_sessions"], "users": result["users_total"], "port": server["vpn_port"], "network": server["vpn_network"]},
		"certificate":            map[string]any{"not_after": certificate["expires_at"], "days_remaining": certificate["days_remaining"], "valid": certificate["valid"]},
		"last_openconnect_check": server["openconnect_checked_at"], "updated_at": server["updated_at"],
	}, nil
}
