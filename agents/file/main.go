package main

import (
	"bufio"
	"database/sql"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/fsnotify/fsnotify"
	"github.com/gorilla/websocket"
	_ "github.com/mattn/go-sqlite3"
)

type Config struct {
	ServerURL    string
	APIToken     string
	Hostname     string
	LogFile      string
	DatabasePath string
}

type LogMessage struct {
	Type      string    `json:"type"`
	Timestamp time.Time `json:"timestamp"`
	Message   string    `json:"message"`
	OffsetID  string    `json:"offset_id"`
}

type ServerAck struct {
	Type      string    `json:"type"`
	OffsetID  string    `json:"offset_id"`
	Timestamp time.Time `json:"timestamp"`
	Status    string    `json:"status"`
}

type Agent struct {
	config     Config
	db         *sql.DB
	conn       *websocket.Conn
	watcher    *fsnotify.Watcher
	lastOffset string
}

func NewAgent(config Config) (*Agent, error) {
	db, err := sql.Open("sqlite3", config.DatabasePath)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	// Create tables if they don't exist
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS cursor (
			id INTEGER PRIMARY KEY,
			file_path TEXT NOT NULL,
			offset INTEGER NOT NULL,
			last_timestamp TEXT NOT NULL,
			offset_id TEXT NOT NULL
		)
	`)
	if err != nil {
		return nil, fmt.Errorf("failed to create tables: %w", err)
	}

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, fmt.Errorf("failed to create file watcher: %w", err)
	}

	return &Agent{
		config:  config,
		db:      db,
		watcher: watcher,
	}, nil
}

func (a *Agent) connectWebSocket() error {
	dialer := websocket.Dialer{}
	conn, _, err := dialer.Dial(a.config.ServerURL+"/ws/ship", nil)
	if err != nil {
		return fmt.Errorf("failed to connect websocket: %w", err)
	}

	a.conn = conn
	return nil
}

func (a *Agent) getLastPosition() (int64, string, error) {
	var offset int64
	var offsetID string
	err := a.db.QueryRow(`
		SELECT offset, offset_id FROM cursor 
		WHERE file_path = ? 
		ORDER BY id DESC LIMIT 1`,
		a.config.LogFile,
	).Scan(&offset, &offsetID)

	if err == sql.ErrNoRows {
		return 0, "", nil
	}
	if err != nil {
		return 0, "", fmt.Errorf("failed to get last position: %w", err)
	}

	return offset, offsetID, nil
}

func (a *Agent) updatePosition(offset int64, timestamp time.Time, offsetID string) error {
	_, err := a.db.Exec(`
		INSERT INTO cursor (file_path, offset, last_timestamp, offset_id)
		VALUES (?, ?, ?, ?)`,
		a.config.LogFile, offset, timestamp.Format(time.RFC3339), offsetID,
	)
	return err
}

func (a *Agent) shipLogs() error {
	file, err := os.Open(a.config.LogFile)
	if err != nil {
		return fmt.Errorf("failed to open log file: %w", err)
	}
	defer file.Close()

	offset, _, err := a.getLastPosition()
	if err != nil {
		return err
	}

	// Seek to last known position
	if offset > 0 {
		_, err = file.Seek(offset, 0)
		if err != nil {
			return fmt.Errorf("failed to seek file: %w", err)
		}
	}

	// Start backfill if needed
	if offset == 0 {
		err = a.sendBackfillStart()
		if err != nil {
			return err
		}
	}

	// Read and ship new logs
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		timestamp := time.Now() // In reality, parse from log line
		offsetID := fmt.Sprintf("%s-%d", timestamp.Format("20060102150405"), offset)

		msg := LogMessage{
			Type:      "log",
			Timestamp: timestamp,
			Message:   line,
			OffsetID:  offsetID,
		}

		err = a.conn.WriteJSON(msg)
		if err != nil {
			return fmt.Errorf("failed to send log: %w", err)
		}

		// Wait for acknowledgment
		var ack ServerAck
		err = a.conn.ReadJSON(&ack)
		if err != nil {
			return fmt.Errorf("failed to receive ack: %w", err)
		}

		if ack.Status == "accepted" {
			err = a.updatePosition(offset+int64(len(line)+1), timestamp, offsetID)
			if err != nil {
				return fmt.Errorf("failed to update position: %w", err)
			}
			offset += int64(len(line) + 1)
			a.lastOffset = offsetID
		}
	}

	if offset == 0 {
		err = a.sendBackfillEnd()
		if err != nil {
			return err
		}
	}

	return scanner.Err()
}

func (a *Agent) sendBackfillStart() error {
	msg := map[string]interface{}{
		"type":            "backfill_start",
		"from_timestamp":  time.Now().Add(-24 * time.Hour),
		"estimated_count": 1000, // You'd want to estimate this
	}
	return a.conn.WriteJSON(msg)
}

func (a *Agent) sendBackfillEnd() error {
	msg := map[string]interface{}{
		"type":         "backfill_end",
		"to_timestamp": time.Now(),
		"actual_count": 1000, // You'd want to track this
	}
	return a.conn.WriteJSON(msg)
}

func (a *Agent) handleHeartbeat() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		msg := map[string]interface{}{
			"type":                 "heartbeat_ack",
			"timestamp":            time.Now(),
			"last_received_offset": a.lastOffset,
		}
		err := a.conn.WriteJSON(msg)
		if err != nil {
			log.Printf("Failed to send heartbeat: %v", err)
			return
		}
	}
}

func (a *Agent) Run() error {
	// Connect to WebSocket
	err := a.connectWebSocket()
	if err != nil {
		return err
	}
	defer a.conn.Close()

	// Watch for file changes
	err = a.watcher.Add(a.config.LogFile)
	if err != nil {
		return fmt.Errorf("failed to watch file: %w", err)
	}
	defer a.watcher.Close()

	// Start heartbeat goroutine
	go a.handleHeartbeat()

	// Initial ship of existing logs
	err = a.shipLogs()
	if err != nil {
		return err
	}

	// Watch for file changes
	for event := range a.watcher.Events {
		if event.Op&fsnotify.Write == fsnotify.Write {
			err = a.shipLogs()
			if err != nil {
				log.Printf("Failed to ship logs: %v", err)
			}
		}
	}

	return nil
}

func main() {
	config := Config{
		ServerURL:    "wss://fog-server:4000/api/v1",
		APIToken:     os.Getenv("FOG_API_TOKEN"),
		Hostname:     os.Getenv("HOSTNAME"),
		LogFile:      os.Getenv("LOG_FILE"),
		DatabasePath: os.Getenv("FOG_DB_PATH"),
	}

	agent, err := NewAgent(config)
	if err != nil {
		log.Fatalf("Failed to create agent: %v", err)
	}

	err = agent.Run()
	if err != nil {
		log.Fatalf("Agent failed: %v", err)
	}
}
