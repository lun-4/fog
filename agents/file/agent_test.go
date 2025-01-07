package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

type TestServer struct {
	*httptest.Server
	ConnectedClients map[*websocket.Conn]bool
	ReceivedLogs     []LogData
	ClientsLock      sync.Mutex
	LogsLock         sync.Mutex

	// Channel for tests to receive messages
	Messages chan Message
}

func NewTestServer(t *testing.T) *TestServer {
	ts := &TestServer{
		ConnectedClients: make(map[*websocket.Conn]bool),
		ReceivedLogs:     make([]LogData, 0),
		Messages:         make(chan Message, 100), // Buffered channel to prevent blocking
	}

	ts.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api/v1/agent/ws") {
			t.Errorf("unexpected path: %s", r.URL.Path)
			http.Error(w, "not found", http.StatusNotFound)
			return
		}

		token := r.URL.Query().Get("token")
		if token != "test-token" {
			t.Errorf("unexpected token: %s", token)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("websocket upgrade error: %v", err)
			return
		}

		ts.ClientsLock.Lock()
		ts.ConnectedClients[conn] = true
		ts.ClientsLock.Unlock()

		// Send HELLO message
		err = conn.WriteJSON(Message{Op: "hello"})
		if err != nil {
			t.Errorf("failed to send hello: %v", err)
			return
		}

		// Handle messages from this client
		go ts.handleClient(t, conn)
	}))

	return ts
}

func (ts *TestServer) handleClient(t *testing.T, conn *websocket.Conn) {
	defer func() {
		ts.ClientsLock.Lock()
		delete(ts.ConnectedClients, conn)
		ts.ClientsLock.Unlock()
		conn.Close()
	}()

	for {
		var msg Message
		err := conn.ReadJSON(&msg)
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseNormalClosure) {
				t.Logf("websocket error: %v", err)
			}
			return
		}

		// Send message to channel for test consumption
		ts.Messages <- msg

		// Handle default behaviors
		switch msg.Op {
		case "send":
			if data, ok := msg.Data.(map[string]interface{}); ok {
				logData := LogData{
					Key0: data["key0"].(string),
					Key1: data["key1"].(string),
					Data: data["data"].(string),
				}
				ts.LogsLock.Lock()
				ts.ReceivedLogs = append(ts.ReceivedLogs, logData)
				ts.LogsLock.Unlock()
			}
		case "heartbeat":
			err := conn.WriteJSON(Message{Op: "heartbeat_ack"})
			if err != nil {
				t.Errorf("failed to send heartbeat ack: %v", err)
				return
			}
		}
	}
}

func (ts *TestServer) Close() error {
	err := ts.CloseClients()
	if err != nil {
		return fmt.Errorf("error closing clients: %w", err)
	}
	ts.Server.Close()
	close(ts.Messages)
	return nil
}

func (ts *TestServer) CloseClients() error {
	ts.ClientsLock.Lock()
	defer ts.ClientsLock.Unlock()

	for conn := range ts.ConnectedClients {
		d := websocket.FormatCloseMessage(websocket.CloseNormalClosure, "closing test server")
		err := conn.WriteControl(websocket.CloseMessage, d, time.Now().Add(1*time.Second))
		if err != nil {
			return fmt.Errorf("error sending close frame: %w", err)
		}

		err = conn.Close()
		if err != nil {
			return fmt.Errorf("error closing client: %w", err)
		}
	}

	ts.ConnectedClients = make(map[*websocket.Conn]bool)
	return nil
}

func (ts *TestServer) GetClientCount() int {
	ts.ClientsLock.Lock()
	defer ts.ClientsLock.Unlock()
	return len(ts.ConnectedClients)
}

func (ts *TestServer) GetReceivedLogs() []LogData {
	ts.LogsLock.Lock()
	defer ts.LogsLock.Unlock()
	return append([]LogData{}, ts.ReceivedLogs...)
}

func TestAgentConnection(t *testing.T) {
	ts := NewTestServer(t)
	defer ts.Close()

	wsURL := strings.Replace(ts.URL, "http", "ws", 1)
	agent := NewAgent(wsURL, "test-token", "testlog.txt", "test-host", "test-service")

	err := agent.connect()
	require.NoError(t, err)
	defer agent.disconnect()

	assert.True(t, agent.isConnected)
	assert.Equal(t, 1, ts.GetClientCount())
}

func (ts *TestServer) FetchOneMessage(t *testing.T, maybeTimeout *time.Duration) Message {
	timeout := 5 * time.Second
	if maybeTimeout != nil {
		timeout = *maybeTimeout
	}
	select {
	case msg := <-ts.Messages:
		return msg
	case <-time.After(timeout):
		require.FailNow(t, "timeout waiting for message")
		return Message{}
	}
}

func TestAgentReconnection(t *testing.T) {
	ts := NewTestServer(t)
	defer ts.Close()

	tmpDir := t.TempDir()
	logFile := filepath.Join(tmpDir, "test.log")
	err := os.WriteFile(logFile, []byte(""), 0644)
	require.NoError(t, err)

	wsURL := strings.Replace(ts.URL, "http", "ws", 1)
	agent := NewAgent(wsURL, "test-token", logFile, "test-host", "test-service")
	agent.heartbeatPeriod = 200 * time.Millisecond

	// Initial connection
	err = agent.connect()
	require.NoError(t, err)
	require.NoError(t, agent.Setup())

	// Force disconnect
	require.NoError(t, ts.CloseClients())
	agent.sendChan <- Message{}

	// Test reconnection
	// go agent.handleWebSocket()

	// Wait for heartbeat message after reconnection
	dur := 1 * time.Second
	msg := ts.FetchOneMessage(t, &dur)
	require.Equal(t, "heartbeat", msg.Op)

	require.True(t, agent.isConnected)
	require.Equal(t, 1, ts.GetClientCount())
}

func TestLogSending(t *testing.T) {
	ts := NewTestServer(t)
	defer ts.Close()

	// Create temporary log file
	tmpDir := t.TempDir()
	logFile := filepath.Join(tmpDir, "test.log")
	err := os.WriteFile(logFile, []byte(""), 0644)
	require.NoError(t, err)

	wsURL := strings.Replace(ts.URL, "http", "ws", 1)
	agent := NewAgent(wsURL, "test-token", logFile, "test-host", "test-service")

	// Connect and start handlers
	err = agent.connect()
	require.NoError(t, err)
	defer agent.disconnect()

	require.NoError(t, agent.Setup())

	// Write to log file and wait for the message
	testLog := "test log entry"
	err = os.WriteFile(logFile, []byte(testLog+"\n"), 0644)
	require.NoError(t, err)

	// Wait for the send message
	msg := ts.FetchOneMessage(t, nil)
	require.Equal(t, "send", msg.Op)
	data := msg.Data.(map[string]interface{})
	require.Equal(t, testLog, data["data"])

	// Verify log was received
	logs := ts.GetReceivedLogs()
	require.Len(t, logs, 1)
	assert.Equal(t, "test-host", logs[0].Key0)
	assert.Equal(t, "test-service", logs[0].Key1)
	assert.Equal(t, testLog, logs[0].Data)
}

func TestHeartbeat(t *testing.T) {
	ts := NewTestServer(t)
	defer ts.Close()

	wsURL := strings.Replace(ts.URL, "http", "ws", 1)
	agent := NewAgent(wsURL, "test-token", "testlog.txt", "test-host", "test-service")

	err := agent.connect()
	require.NoError(t, err)
	defer agent.disconnect()

	// Send heartbeat
	err = agent.conn.WriteJSON(Message{Op: "heartbeat"})
	require.NoError(t, err)

	// Wait for heartbeat ack
	msg := ts.FetchOneMessage(t, nil)
	require.Equal(t, "heartbeat_ack", msg.Op)
}

func TestInvalidToken(t *testing.T) {
	ts := NewTestServer(t)
	defer ts.Close()

	wsURL := strings.Replace(ts.URL, "http", "ws", 1)
	agent := NewAgent(wsURL, "invalid-token", "testlog.txt", "test-host", "test-service")

	err := agent.connect()
	assert.Error(t, err)
	assert.False(t, agent.isConnected)
}
