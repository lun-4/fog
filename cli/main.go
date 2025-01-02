package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"

	"github.com/r3labs/sse/v2"
)

type LogEntry struct {
	Key0 string `json:"key0"`
	Key1 string `json:"key1"`
	Text string `json:"text"`
}

type Config struct {
	serverURL string
	key0      string
	key1      string
	since     string
	until     string
	grep      string
	follow    bool
	limit     int
}

func main() {
	config := parseFlags()

	if err := validateConfig(config); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	if config.follow {
		if err := streamLogs(config); err != nil {
			fmt.Fprintf(os.Stderr, "Error streaming logs: %v\n", err)
			os.Exit(1)
		}
	} else {
		if err := queryLogs(config); err != nil {
			fmt.Fprintf(os.Stderr, "Error querying logs: %v\n", err)
			os.Exit(1)
		}
	}
}

func parseFlags() Config {
	var config Config

	flag.StringVar(&config.serverURL, "server", "", "Log server URL (required)")
	flag.StringVar(&config.key0, "key0", "", "Comma-separated list of key0 values to filter")
	flag.StringVar(&config.key1, "key1", "", "Comma-separated list of key1 values to filter")
	flag.StringVar(&config.since, "since", "", "Start time (e.g., '2h', '2024-03-20T15:04:05Z')")
	flag.StringVar(&config.until, "until", "", "End time (same format as since)")
	flag.StringVar(&config.grep, "grep", "", "Text to search for in logs")
	flag.BoolVar(&config.follow, "follow", false, "Enable streaming updates")
	flag.IntVar(&config.limit, "limit", 1000, "Maximum number of logs to return")

	flag.Parse()

	if config.serverURL == "" {
		fmt.Fprintln(os.Stderr, "Error: server URL is required")
		flag.Usage()
		os.Exit(1)
	}

	return config
}

func validateConfig(config Config) error {
	if config.follow && config.until != "" {
		return fmt.Errorf("follow and until flags cannot be used together")
	}
	return nil
}

func buildQueryParams(config Config) url.Values {
	params := url.Values{}

	if config.key0 != "" {
		params.Add("key0", config.key0)
	}
	if config.key1 != "" {
		params.Add("key1", config.key1)
	}
	if config.since != "" {
		params.Add("since", config.since)
	}
	if config.until != "" {
		params.Add("until", config.until)
	}
	if config.grep != "" {
		params.Add("grep", config.grep)
	}
	if config.follow {
		params.Add("follow", "true")
	}
	params.Add("limit", fmt.Sprintf("%d", config.limit))

	return params
}

func queryLogs(config Config) error {
	params := buildQueryParams(config)

	queryURL := fmt.Sprintf("%s/api/v1/cli/query?%s",
		strings.TrimSuffix(config.serverURL, "/"),
		params.Encode())

	resp, err := http.Get(queryURL)
	if err != nil {
		return fmt.Errorf("failed to query logs: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("server returned status code %d", resp.StatusCode)
	}

	var response struct {
		Results []LogEntry `json:"logs"`
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read response body: %v", err)
	}

	if err := json.Unmarshal(body, &response); err != nil {
		return fmt.Errorf("failed to parse JSON response: %v", err)
	}

	// Print each log entry
	fmt.Printf("Got %d logs for %s/%s:\n", len(response.Results), config.key0, config.key1)
	for _, result := range response.Results {
		fmt.Printf("[%s/%s] %s\n", result.Key0, result.Key1, result.Text)
	}

	return nil
}

func streamLogs(config Config) error {
	params := buildQueryParams(config)

	queryURL := fmt.Sprintf("%s/api/v1/cli/query?%s",
		strings.TrimSuffix(config.serverURL, "/"),
		params.Encode())

	client := sse.NewClient(queryURL)

	fmt.Fprintf(os.Stderr, "Streaming logs...\n")

	// Handle server-sent events
	err := client.Subscribe("messages", func(event *sse.Event) {
		var logEntry LogEntry

		if err := json.Unmarshal(event.Data, &logEntry); err != nil {
			fmt.Fprintf(os.Stderr, "Error parsing log entry: %v\n", err)
			return
		}

		fmt.Printf("[%s/%s] %s\n", logEntry.Key0, logEntry.Key1, logEntry.Text)
	})

	if err != nil {
		return fmt.Errorf("failed to subscribe to log stream: %v", err)
	}

	// Keep the connection alive until interrupted
	select {}
}
