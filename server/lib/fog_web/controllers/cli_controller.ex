defmodule FogWeb.CLIController do
  require Logger
  use FogWeb, :controller

  def query(conn, params) do
    # Validate follow and until aren't both present
    if params["follow"] != nil && params["until"] != nil do
      conn
      |> put_status(400)
      |> json(%{error: "follow and until parameters are incompatible"})
    else
      params =
        params
        |> Map.put("limit", Map.get(params, "limit", "1000"))
        |> Map.put("selectors", Map.get(params, "selectors", "*.*") |> String.split(","))

      handle_query(conn, params)
    end
  end

  defp handle_query(conn, %{"follow" => "true"} = params) do
    # Get initial logs

    client_id = Fog.LogStore.Realtime.generate_client_id()

    :ok =
      Fog.LogStore.Realtime.subscribe(
        client_id,
        params |> Map.delete("stream")
      )

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    conn =
      case Fog.LogStore.query(params) do
        {:ok, logs} ->
          conn
          |> send_initial_logs(logs)

        {:error, :enoent} ->
          conn
      end

    conn
    |> stream_new_logs(client_id)
  end

  defp handle_query(conn, params) do
    {:ok, logs} = Fog.LogStore.query(params)
    json(conn, %{logs: logs})
  end

  defp send_event(conn, event_name, data) do
    chunk = """
    event: #{event_name}
    data: #{data}

    """

    chunk(conn, chunk)
  end

  defp send_initial_logs(conn, logs) do
    Enum.reduce_while(logs, conn, fn log, conn ->
      case send_event(conn, "log", Jason.encode!(log)) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defp stream_new_logs(conn, client_id) do
    receive do
      {:log_entry, _, log} ->
        case send_event(conn, "log", Jason.encode!(log)) do
          {:ok, conn} ->
            stream_new_logs(conn, client_id)

          {:error, :closed} ->
            :ok = Fog.LogStore.Realtime.unsubscribe(client_id)
            conn
        end

      # Handle other messages as needed
      v ->
        Logger.warning("unknown message from follow setup: #{inspect(v)}")
        stream_new_logs(conn, client_id)
    end
  end
end
