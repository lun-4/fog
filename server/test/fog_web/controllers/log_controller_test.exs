defmodule Fog.IntegrationTest do
  require Logger
  use FogWeb.ConnCase, async: false

  # We'll use WebSockex for WS client in tests
  defmodule TestAgent do
    use WebSockex

    def start_link(url, state) do
      WebSockex.start_link(url, __MODULE__, state)
    end

    def send_log(client, key0, key1, data) do
      message =
        Jason.encode!(%{
          "op" => "send",
          "data" => %{
            "key0" => key0,
            "key1" => key1,
            "data" => data
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

  describe "agent websocket connection and cli query" do
    test "complete flow: connect, send logs, query via HTTP", %{
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
        get(conn, ~p"/api/v1/cli/query", %{
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

    test "cli query with invalid follow/until combination", %{conn: conn} do
      response =
        get(conn, ~p"/api/v1/cli/query", %{
          follow: true,
          until: "2024-03-20T15:04:05Z"
        })

      assert response.status == 400
    end

    test "cli query respects limit parameter", %{
      client: client,
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
        get(conn, ~p"/api/v1/cli/query", %{
          selectors: "#{key0}.#{key1}",
          limit: 3
        })

      rjson = json_response(conn, 200)
      logs = rjson["logs"]
      assert length(logs) == 3
    end

    test "cli query with follow (SSE)", %{
      client: client,
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
              [{"Accept", "text/event-stream"}],
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
end
