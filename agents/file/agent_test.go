package main

import (
	"fmt"
	"log"
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
			http.Error(w, "not found", http.StatusNotFound)
			return
		}

		token := r.URL.Query().Get("token")
		if token != "test-token" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			http.Error(w, "upgrade error", http.StatusInternalServerError)
			return
		}

		ts.ClientsLock.Lock()
		ts.ConnectedClients[conn] = true
		ts.ClientsLock.Unlock()

		// Send HELLO message
		err = conn.WriteJSON(Message{Op: "hello"})
		if err != nil {
			http.Error(w, "failed to send hello", http.StatusInternalServerError)
			return
		}

		// Handle messages from this client
		go ts.handleClient(t, conn)
	}))

	return ts
}

func (ts *TestServer) Debug(format string, args ...interface{}) {
	log.Printf("[DEBUG] "+format, args...)
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
		ts.Debug("received from agent: %v", msg)
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
	ts.Debug("waiting for message...")
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

	// agent should be reconnecting immediately, and due to heartbeat period configured to 200ms
	// that means we should get a heartbeat practically immediately as well

	// Wait for heartbeat message after reconnection
	dur := 800 * time.Millisecond
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

	// Create temporary log file
	tmpDir := t.TempDir()
	logFile := filepath.Join(tmpDir, "test.log")
	err := os.WriteFile(logFile, []byte(""), 0644)
	require.NoError(t, err)

	wsURL := strings.Replace(ts.URL, "http", "ws", 1)
	agent := NewAgent(wsURL, "test-token", logFile, "test-host", "test-service")
	agent.heartbeatPeriod = 10 * time.Millisecond

	// Connect and start handlers
	err = agent.connect()
	require.NoError(t, err)
	defer agent.disconnect()

	require.NoError(t, agent.Setup())

	msg := ts.FetchOneMessage(t, nil)
	require.Equal(t, "heartbeat", msg.Op)
}

func TestInvalidToken(t *testing.T) {
	ts := NewTestServer(t)
	defer ts.Close()

	wsURL := strings.Replace(ts.URL, "http", "ws", 1)
	agent := NewAgent(wsURL, "invalid-token", "testlog.txt", "test-host", "test-service")

	err := agent.connect()
	require.Error(t, err)
	require.False(t, agent.isConnected)
}

func TestLogRotation(t *testing.T) {
	ts := NewTestServer(t)
	defer ts.Close()

	// Create temporary log file
	tmpDir := t.TempDir()
	logFile := filepath.Join(tmpDir, "test.log")
	fd, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	require.NoError(t, err)
	defer fd.Close()

	_, err = fd.Write([]byte("initial\n"))
	require.NoError(t, err)

	wsURL := strings.Replace(ts.URL, "http", "ws", 1)
	agent := NewAgent(wsURL, "test-token", logFile, "test-host", "test-service")
	agent.TraceMode = true

	// Connect and start handlers
	err = agent.connect()
	require.NoError(t, err)
	defer agent.disconnect()

	require.NoError(t, agent.Setup())

	_, err = fd.Write([]byte("initial log entry\n"))
	require.NoError(t, err)

	// Wait for initial log entry to be sent
	msg := ts.FetchOneMessage(t, nil)
	require.Equal(t, "send", msg.Op)
	data := msg.Data.(map[string]interface{})
	require.Equal(t, "initial log entry", data["data"])

	// Write some content to be caught in rotation
	_, err = fd.Write([]byte("last entry before rotation\n"))
	require.NoError(t, err)

	// Wait for the last entry to be sent
	msg = ts.FetchOneMessage(t, nil)
	require.Equal(t, "send", msg.Op)
	data = msg.Data.(map[string]interface{})
	require.Equal(t, "last entry before rotation", data["data"])

	// Perform log rotation
	now := time.Now()
	rotatedName := filepath.Join(tmpDir, fmt.Sprintf("test-%d-%02d-%02d.log",
		now.Year(), now.Month(), now.Day()))

	err = os.Rename(logFile, rotatedName)
	require.NoError(t, err)

	// Create new log file
	rotatedFd, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	require.NoError(t, err)
	defer rotatedFd.Close()
	_, err = rotatedFd.Write([]byte("first entry after rotation\n"))
	require.NoError(t, err)

	// Wait for the first entry in new file to be sent
	msg = ts.FetchOneMessage(t, nil)
	require.Equal(t, "send", msg.Op)
	data = msg.Data.(map[string]interface{})
	require.Equal(t, "first entry after rotation", data["data"])

	// Verify all logs were received in order
	logs := ts.GetReceivedLogs()
	require.Len(t, logs, 3)

	assert.Equal(t, "initial log entry", logs[0].Data)
	assert.Equal(t, "last entry before rotation", logs[1].Data)
	assert.Equal(t, "first entry after rotation", logs[2].Data)

	// Verify all logs have correct metadata
	for _, log := range logs {
		assert.Equal(t, "test-host", log.Key0)
		assert.Equal(t, "test-service", log.Key1)
	}
}
