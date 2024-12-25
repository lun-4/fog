package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const (
	defaultServerURL = "https://fog-server:4000/api/v1"
	defaultLimit     = 1000
)

type Config struct {
	ServerURL string
	APIToken  string
}

type LogEntry struct {
	Host      string    `json:"host"`
	Timestamp time.Time `json:"timestamp"`
	Message   string    `json:"message"`
	OffsetID  string    `json:"offset_id"`
}

type QueryResponse struct {
	Logs []LogEntry `json:"logs"`
	Meta struct {
		Total   int  `json:"total"`
		HasMore bool `json:"has_more"`
	} `json:"meta"`
}

func loadConfig() (*Config, error) {
	// TODO: Load from ~/.fog/config.json
	return &Config{
		ServerURL: defaultServerURL,
		APIToken:  os.Getenv("FOG_API_TOKEN"),
	}, nil
}

func main() {
	// Define flags
	hostFlag := flag.String("host", "", "Comma-separated list of hosts to query")
	sinceFlag := flag.String("since", "", "Start time (e.g., 2h, 2024-03-20T15:04:05Z)")
	lastFlag := flag.String("last", "", "Duration to look back (e.g., 30m)")
	grepFlag := flag.String("grep", "", "Text to search for")
	followFlag := flag.Bool("follow", false, "Stream logs in real-time")
	limitFlag := flag.Int("limit", defaultLimit, "Maximum number of logs to return")

	// Parse command-line arguments
	flag.Parse()

	// Handle subcommands
	if len(flag.Args()) > 0 {
		switch flag.Args()[0] {
		case "tail":
			*followFlag = true
		case "today":
			now := time.Now()
			*sinceFlag = now.Format("2006-01-02") + "T00:00:00Z"
		}
	}

	// Load configuration
	config, err := loadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading config: %v\n", err)
		os.Exit(1)
	}

	// Build query parameters
	params := url.Values{}
	if *hostFlag != "" {
		params.Set("host", *hostFlag)
	}
	if *sinceFlag != "" {
		params.Set("since", *sinceFlag)
	}
	if *lastFlag != "" {
		// Convert last duration to since timestamp
		duration, err := time.ParseDuration(*lastFlag)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Invalid duration format: %v\n", err)
			os.Exit(1)
		}
		params.Set("since", time.Now().Add(-duration).Format(time.RFC3339))
	}
	if *grepFlag != "" {
		params.Set("grep", *grepFlag)
	}
	if *followFlag {
		params.Set("follow", "true")
	}
	params.Set("limit", fmt.Sprintf("%d", *limitFlag))

	// Choose endpoint based on follow flag
	endpoint := "/query"
	if *followFlag {
		endpoint = "/stream"
	}

	// Make the request
	client := &http.Client{}
	req, err := http.NewRequest("GET", config.ServerURL+endpoint+"?"+params.Encode(), nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating request: %v\n", err)
		os.Exit(1)
	}

	req.Header.Set("Authorization", "Bearer "+config.APIToken)

	if *followFlag {
		// Handle streaming response
		handleStreamingResponse(client, req)
	} else {
		// Handle regular response
		handleRegularResponse(client, req)
	}
}

func handleRegularResponse(client *http.Client, req *http.Request) {
	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error making request: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		handleErrorResponse(resp)
		os.Exit(1)
	}

	var queryResp QueryResponse
	if err := json.NewDecoder(resp.Body).Decode(&queryResp); err != nil {
		fmt.Fprintf(os.Stderr, "Error decoding response: %v\n", err)
		os.Exit(1)
	}

	// Print logs
	for _, log := range queryResp.Logs {
		printLog(log)
	}

	if queryResp.Meta.HasMore {
		fmt.Fprintf(os.Stderr, "\nMore logs available. Refine your query or increase the limit.\n")
	}
}

func handleStreamingResponse(client *http.Client, req *http.Request) {
	// Convert HTTP request to WebSocket
	wsURL := strings.Replace(req.URL.String(), "https://", "wss://", 1)
	wsURL = strings.Replace(wsURL, "http://", "ws://", 1)

	c, _, err := websocket.DefaultDialer.Dial(wsURL, req.Header)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error connecting to WebSocket: %v\n", err)
		os.Exit(1)
	}
	defer c.Close()

	for {
		var log LogEntry
		err := c.ReadJSON(&log)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error reading message: %v\n", err)
			break
		}
		printLog(log)
	}
}

func handleErrorResponse(resp *http.Response) {
	var errorResp struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&errorResp); err != nil {
		fmt.Fprintf(os.Stderr, "Error: HTTP %d\n", resp.StatusCode)
		return
	}

	fmt.Fprintf(os.Stderr, "Error (%s): %s\n", errorResp.Error.Code, errorResp.Error.Message)
}

func printLog(log LogEntry) {
	fmt.Printf("[%s] %s: %s\n", log.Timestamp.Format(time.RFC3339), log.Host, log.Message)
}
