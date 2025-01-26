package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
	"github.com/gorilla/websocket"
)

type Message struct {
	Op   string      `json:"op"`
	Data interface{} `json:"data,omitempty"`
}

type LogData struct {
	Key0      string `json:"key0"`
	Key1      string `json:"key1"`
	Data      string `json:"data"`
	Timestamp int64  `json:"timestamp"`
}

type Agent struct {
	serverURL       string
	token           string
	logFile         string
	key0            string
	key1            string
	conn            *websocket.Conn
	sendChan        chan Message
	done            chan struct{}
	reconnectMux    sync.Mutex
	isConnected     bool
	setupFileWatch  chan error
	heartbeatPeriod time.Duration
	DebugMode       bool
	TraceMode       bool
}

func NewAgent(serverURL, token, logFile, key0, key1 string) *Agent {
	return &Agent{
		serverURL:       serverURL,
		token:           token,
		logFile:         logFile,
		key0:            key0,
		key1:            key1,
		sendChan:        make(chan Message, 100),
		done:            make(chan struct{}),
		setupFileWatch:  make(chan error, 1),
		heartbeatPeriod: 5 * time.Second,
		DebugMode:       false,
	}
}

func (a *Agent) Debug(fmt string, args ...any) {
	if a.DebugMode {
		log.Printf(fmt, args...)
	}
}
func (a *Agent) Trace(fmt string, args ...any) {
	if a.TraceMode {
		log.Printf(fmt, args...)
	}
}

// TODO support log rotation on the file agent is watching
func (a *Agent) connect() error {
	a.reconnectMux.Lock()
	defer a.reconnectMux.Unlock()

	if a.isConnected {
		return nil
	}
	log.Println("connecting...")

	wsURL := fmt.Sprintf("%s/api/v1/agent/ws?token=%s", a.serverURL, a.token)
	a.Debug("connecting to %s", wsURL)
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return fmt.Errorf("dial error: %v", err)
	}

	// Wait for HELLO message
	var msg Message
	err = conn.ReadJSON(&msg)
	if err != nil {
		conn.Close()
		return fmt.Errorf("read hello error: %v", err)
	}
	if msg.Op != "hello" {
		conn.Close()
		return fmt.Errorf("expected hello message, got: %s", msg.Op)
	}

	a.Debug("received hello data: %v", msg)
	log.Println("connected!")
	a.conn = conn
	a.isConnected = true
	return nil
}

func (a *Agent) disconnect() {
	a.reconnectMux.Lock()
	defer a.reconnectMux.Unlock()

	log.Println("disconnecting")

	if a.conn != nil {
		err := a.conn.Close()
		if err != nil {
			log.Printf("Disconnect failed (ignoring error): %v", err)
		}
		a.conn = nil
	}
	a.isConnected = false
}

func (a *Agent) reconnect() {
	log.Println("reconnecting..")
	for {
		err := a.connect()
		if err == nil {
			log.Println("Successfully reconnected")
			return
		}
		log.Printf("Reconnect failed: %v, retrying in 5 seconds...", err)
		time.Sleep(5 * time.Second)
	}
}

func (a *Agent) handleWebSocket() {
	ticker := time.NewTicker(a.heartbeatPeriod)
	defer ticker.Stop()

	for {
		select {
		case <-a.done:
			log.Println("websocket handling function exit")
			return

		case msg := <-a.sendChan:
			a.Trace("sending data: %v", msg)
			if !a.isConnected {
				a.reconnect()
			}
			err := a.conn.WriteJSON(msg)
			if err != nil {
				log.Printf("Write error: %v", err)
				a.disconnect()
				a.reconnect()
			}

		case <-ticker.C:
			if !a.isConnected {
				a.reconnect()
				continue
			}

			a.Debug("sending heartbeat")
			err := a.conn.WriteJSON(Message{Op: "heartbeat"})
			if err != nil {
				log.Printf("Heartbeat write error: %v", err)
				a.disconnect()
				a.reconnect()
				continue
			}
		}
	}
}

func (a *Agent) Setup() error {
	go a.handleWebSocket()
	go a.handleServerMessages()
	go func() {
		err := a.watchFile(false)
		a.setupFileWatch <- err
	}()
	select {
	case err := <-a.setupFileWatch:
		return err
	case <-time.After(5 * time.Second):
		panic("Agent setup possibly failed")
	}
}

func (a *Agent) handleServerMessages() {
	for {
		select {
		case <-a.done:
			return
		default:
			if !a.isConnected {
				log.Println("waiting for reconnection...")
				time.Sleep(time.Second)
				continue
			}

			var msg Message
			err := a.conn.ReadJSON(&msg)
			if err != nil {
				log.Printf("Read error, disconnecting: %v", err)
				a.disconnect()
				continue
			}

			a.Trace("received message %v", msg)
			switch msg.Op {
			case "heartbeat":
				err := a.conn.WriteJSON(Message{Op: "heartbeat_ack"})
				if err != nil {
					log.Printf("Heartbeat ack write error: %v", err)
					a.disconnect()
				}
			case "heartbeat_ack":
				// Expected response to our heartbeat
			case "send_ack":
				// Expected response to our send
			default:
				log.Printf("Received unknown message type: %s", msg.Op)
			}
		}
	}
}

func (a *Agent) watchFile(readFromBeginning bool) error {
	a.Debug("setting up watchFile on %v", a.logFile)
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("new watcher error: %v", err)
	}
	defer watcher.Close()

	err = watcher.Add(a.logFile)
	if err != nil {
		return fmt.Errorf("add watcher error: %v", err)
	}

	// Open file for initial reading
	file, err := os.Open(a.logFile)
	if err != nil {
		return fmt.Errorf("open file error: %v", err)
	}
	defer file.Close()

	// Seek to end of file
	if readFromBeginning {
		_, err = file.Seek(0, 0)
		if err != nil {
			return fmt.Errorf("seek error: %v", err)
		}
	} else {
		_, err = file.Seek(0, 2)
		if err != nil {
			return fmt.Errorf("seek error: %v", err)
		}
	}

	// Create a buffered reader for line-by-line reading
	reader := bufio.NewReader(file)

	log.Println("setup file watch on", a.logFile)
	a.setupFileWatch <- nil

	if readFromBeginning {
		a.Debug("readFromBeginning is set! reading everything from %v", a.logFile)
		a.readAndSend(reader)
	}

	for {
		select {
		case <-a.done:
			return nil

		case event := <-watcher.Events:
			a.Trace("got event from fsnotify: %v", event)
			if event.Has(fsnotify.Write) {
				a.readAndSend(reader)
			} else if event.Has(fsnotify.Rename) {
				log.Println("currently watched file was renamed, finishing current file then switching to path again")
				// finish reading from current file
				a.readAndSend(reader)
				// spawn another goroutine so it sets itself up on path
				go func() {
					err := a.watchFile(true)
					if err != nil {
						log.Panicf("File watch error: %v", err)
					}
				}()
				// stop ourselves
				return nil
			}
		case err := <-watcher.Errors:
			log.Printf("Watcher error: %v", err)
		}
	}
}

func (a *Agent) readAndSend(reader *bufio.Reader) {
	for {
		// Read until next newline
		line, err := reader.ReadString('\n')
		if err == io.EOF {
			break
		}
		if err != nil {
			log.Printf("Read error: %v", err)
			break
		}

		// Remove trailing newline if present
		line = strings.TrimRight(line, "\r\n")

		// Send the complete line
		a.sendChan <- Message{
			Op: "send",
			Data: LogData{
				Key0:      a.key0,
				Key1:      a.key1,
				Data:      line,
				Timestamp: time.Now().UnixMilli(),
			},
		}
	}
}

func main() {
	// Command line flags
	serverURL := flag.String("server", "", "WebSocket server URL")
	token := flag.String("token", "", "Authentication token")
	logFile := flag.String("file", "", "File to tail")
	key0 := flag.String("key0", "", "Key0 identifier")
	key1 := flag.String("key1", "", "Key1 identifier")
	flag.Parse()

	if *serverURL == "" || *token == "" || *logFile == "" || *key0 == "" || *key1 == "" {
		log.Fatal("All flags are required: -server, -token, -file, -key0, -key1")
	}

	agent := NewAgent(*serverURL, *token, *logFile, *key0, *key1)
	if os.Getenv("DEBUG") == "1" {
		agent.DebugMode = true
	}
	if os.Getenv("TRACE") == "1" {
		agent.TraceMode = true
	}
	if agent.TraceMode {
		agent.DebugMode = true
	}

	// Initial connection
	err := agent.connect()
	if err != nil {
		log.Fatal("Initial connection failed:", err)
	}

	err = agent.Setup()
	if err != nil {
		log.Panicf("agent setup error: %v", err)
	}

	// Wait for interrupt
	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, os.Interrupt)
	<-interrupt

	log.Println("Shutting down...")
	close(agent.done)
	if agent.conn != nil {
		agent.conn.WriteMessage(
			websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
		)
		agent.conn.Close()
	}
}
