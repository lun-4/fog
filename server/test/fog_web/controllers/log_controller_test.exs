defmodule Fog.IntegrationTest do
  require Logger
  use FogWeb.ConnCase, async: false

  # We'll use WebSockex for WS client in tests
  defmodule TestAgent do
    use WebSockex

    def start_link(url, state) do
      WebSockex.start_link(url, __MODULE__, state)
    end

    def send_log(client, key0, key1, data, timestamp \\ nil) do
      if timestamp != nil do
        Logger.debug("test agent, sending #{timestamp} => #{data}")
      end

      message =
        Jason.encode!(%{
          "op" => "send",
          "data" => %{
            "key0" => key0,
            "key1" => key1,
            "data" => data,
            "timestamp" => timestamp
          }
        })

      WebSockex.send_frame(client, {:text, message})
    end

    def send_heartbeat(client) do
      message = Jason.encode!(%{"op" => "heartbeat"})
      WebSockex.send_frame(client, {:text, message})
    end

    # Handle server messages
    def handle_frame({:text, msg}, state) do
      decoded = Jason.decode!(msg)
      send(state.test_pid, {:ws_message, decoded})
      {:ok, state}
    end
  end

  defp random_string do
    :crypto.strong_rand_bytes(20)
    |> Base.hex_encode32(case: :lower)
    |> binary_part(0, 20)
  end

  setup do
    data_path = "/tmp/fog-test-#{random_string()}"
    Logger.info("Test data path is #{data_path}")
    :ok = Application.put_env(:fog, Fog.LogStore, data_path: data_path)
    # Configure test agent credentials
    key0 = "test_host"
    key1 = "test_service"
    test_log = "sample log entry #{System.system_time(:second)}"

    {:ok, token} = Fog.Authentication.create_random("test suite")

    test_pid = self()
    base_url = "ws://localhost:4002"
    ws_url = "#{base_url}/api/v1/agent/ws?token=#{token.token}"

    {:ok, client} =
      TestAgent.start_link(
        ws_url,
        %{test_pid: test_pid}
      )

    {:ok,
     %{
       client: client,
       token: token.token,
       key0: key0,
       key1: key1,
       test_log: test_log,
       base_url: base_url
     }}
  end

  defp auth_header(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "agent websocket connection and cli query" do
    test "complete flow: connect, send logs, query via HTTP", %{
      token: token,
      client: client,
      key0: key0,
      key1: key1,
      test_log: test_log,
      conn: conn
    } do
      assert_receive {:ws_message, %{"op" => "hello", "data" => %{}}}, 1000
      TestAgent.send_log(client, key0, key1, test_log)

      # wait a brief moment for log processing
      Process.sleep(100)

      conn =
        conn
        |> auth_header(token)
        |> get(~p"/api/v1/cli/query", %{
          selectors: "#{key0}.#{key1}",
          since: "1h"
        })

      rjson = json_response(conn, 200)
      logs = rjson["logs"]

      # Verify log entry is in response
      assert Enum.any?(logs, fn %{"text" => text} = _entry ->
               String.contains?(text, test_log)
             end)

      # 6. Test heartbeat
      TestAgent.send_heartbeat(client)

      assert_receive {:ws_message, %{"op" => "heartbeat_ack"}}, 1000
    end

    test "cli query with invalid follow/until combination", %{conn: conn, token: token} do
      response =
        conn
        |> auth_header(token)
        |> get(~p"/api/v1/cli/query", %{
          follow: true,
          until: "2024-03-20T15:04:05Z"
        })

      assert response.status == 400
    end

    test "cli query respects limit parameter", %{
      client: client,
      token: token,
      key0: key0,
      key1: key1,
      conn: conn
    } do
      # Send 5 log entries
      for i <- 1..5 do
        TestAgent.send_log(client, key0, key1, "log entry #{i}")
      end

      Process.sleep(100)

      # Query with limit=3
      conn =
        conn
        |> auth_header(token)
        |> get(~p"/api/v1/cli/query", %{
          selectors: "#{key0}.#{key1}",
          limit: 3
        })

      rjson = json_response(conn, 200)
      logs = rjson["logs"]
      assert length(logs) == 3
    end

    test "cli query with follow (SSE)", %{
      client: client,
      token: token,
      key0: key0,
      key1: key1,
      base_url: base_url
    } do
      # Start SSE request in a separate process
      parent = self()

      task =
        Task.async(fn ->
          url = "#{String.replace(base_url, "ws:", "http:")}/api/v1/cli/query"
          # Use stream_hackney to support streaming response
          resp =
            HTTPoison.get!(
              url,
              [{"Accept", "text/event-stream"}, {"Authorization", "Bearer #{token}"}],
              params: %{
                selectors: "#{key0}.#{key1}",
                follow: true,
                # Get last 2 lines initially
                limit: 2
              },
              stream_to: self(),
              async: :once
            )

          # Process chunked SSE response
          collect_sse_events(parent, resp, [])
        end)

      # Give SSE connection time to establish
      Process.sleep(100)

      # Send some test logs
      test_logs = [
        "SSE test log 1 #{System.system_time(:second)}",
        "SSE test log 2 #{System.system_time(:second)}",
        "SSE test log 3 #{System.system_time(:second)}"
      ]

      Enum.each(test_logs, fn log ->
        TestAgent.send_log(client, key0, key1, log)
        # Small delay between logs
        Process.sleep(50)
      end)

      # Wait for events and verify
      received_logs = Task.await(task)

      # We should receive all logs since we're following
      Enum.each(test_logs, fn log ->
        assert Enum.any?(received_logs, fn received ->
                 String.contains?(received, log)
               end)
      end)
    end
  end

  # Helper to collect SSE events
  defp collect_sse_events(parent, conn, acc) do
    receive do
      %HTTPoison.AsyncChunk{chunk: chunk} ->
        new_events =
          chunk
          |> String.split("\n\n")
          |> Enum.filter(&(&1 != ""))
          |> Enum.map(fn event ->
            case Regex.run(~r/data: (.+)/, event) do
              [_, data] -> data
              _ -> nil
            end
          end)
          |> Enum.filter(&(&1 != nil))

        if length(acc) + length(new_events) >= 3 do
          # We got all our test events, return them
          acc ++ new_events
        else
          HTTPoison.stream_next(conn)
          collect_sse_events(parent, conn, acc ++ new_events)
        end

      %HTTPoison.AsyncEnd{} ->
        acc

      _ ->
        HTTPoison.stream_next(conn)
        collect_sse_events(parent, conn, acc)
    end
  end

  test "cli query with until parameter", %{
    client: client,
    token: token,
    key0: key0,
    key1: key1,
    conn: conn
  } do
    # Send logs with timestamps spread across time
    current_time = System.system_time(:second)

    # Send 3 logs with different timestamps
    test_logs = [
      # 2 hours ago
      {"log from past", current_time - 2 * 60 * 60},
      # 1 hour ago
      {"log from middle", current_time - 1 * 60 * 60},
      # now
      {"log from recent", current_time}
    ]

    Enum.each(test_logs, fn {message, timestamp} ->
      TestAgent.send_log(client, key0, key1, "#{timestamp}: #{message}", timestamp * 1000)
    end)

    # Allow logs to be processed
    Process.sleep(100)

    # Query with until set to 20 minutes ago
    twenty_mins_ago =
      DateTime.utc_now()
      |> DateTime.add(-(20 * 60), :second)
      |> DateTime.to_iso8601()

    conn =
      conn
      |> auth_header(token)
      |> get(~p"/api/v1/cli/query", %{
        selectors: "#{key0}.#{key1}",
        since: "18h",
        until: twenty_mins_ago
      })

    rjson = json_response(conn, 200)
    logs = rjson["logs"]

    # Should only see logs from 2 hours ago and 1 hour ago
    assert length(logs) == 2

    # Verify we don't see the most recent log
    refute Enum.any?(logs, fn %{"text" => text} ->
             String.contains?(text, "log from recent")
           end)

    # Verify we do see the older logs
    assert Enum.any?(logs, fn %{"text" => text} ->
             String.contains?(text, "log from past")
           end)

    assert Enum.any?(logs, fn %{"text" => text} ->
             String.contains?(text, "log from middle")
           end)
  end

  test "cli query with grep parameter", %{
    client: client,
    token: token,
    key0: key0,
    key1: key1,
    conn: conn
  } do
    # Send logs with different patterns
    test_logs = [
      "ERROR: database connection failed",
      "INFO: normal operation proceeding",
      "ERROR: authentication failed",
      "DEBUG: cache miss",
      "ERROR: disk space low"
    ]

    Enum.each(test_logs, fn log ->
      TestAgent.send_log(client, key0, key1, log)
    end)

    # Allow logs to be processed
    Process.sleep(100)

    # Query with grep for ERROR logs
    conn =
      conn
      |> auth_header(token)
      |> get(~p"/api/v1/cli/query", %{
        selectors: "#{key0}.#{key1}",
        grep: "ERROR"
      })

    rjson = json_response(conn, 200)
    logs = rjson["logs"]

    # Should only see ERROR logs
    assert length(logs) == 3

    # Verify each log contains ERROR
    Enum.each(logs, fn %{"text" => text} ->
      assert String.contains?(text, "ERROR")
    end)

    # Verify we don't see INFO or DEBUG logs
    refute Enum.any?(logs, fn %{"text" => text} ->
             String.contains?(text, "INFO") or String.contains?(text, "DEBUG")
           end)

    # Test case-sensitive grep
    conn =
      build_conn()
      |> auth_header(token)
      |> get(~p"/api/v1/cli/query", %{
        selectors: "#{key0}.#{key1}",
        # lowercase
        grep: "error"
      })

    rjson = json_response(conn, 200)
    logs = rjson["logs"]

    # Should see no logs since grep is case-sensitive
    assert length(logs) == 0
  end
end
