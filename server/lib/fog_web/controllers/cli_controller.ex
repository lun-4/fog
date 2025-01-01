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
      params = Map.put(params, "limit", Map.get(params, "limit", 1000))
      handle_query(conn, params)
    end
  end

  defp handle_query(conn, %{"follow" => "true"} = params) do
    # Get initial logs
    logs = Fog.LogStore.query(params)
    :ok = Fog.LogStore.Realtime.subscribe(Fog.LogStore.Realtime.generate_client_id(), params)

    conn
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)
    |> send_initial_logs(logs)
    |> stream_new_logs()
  end

  defp handle_query(conn, params) do
    logs = Fog.LogStore.query(params)
    json(conn, %{logs: logs})
  end

  defp send_event(conn, event_name, data) do
    chunk = """
    event: #{event_name}
    data: #{Jason.encode!(data)}

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

  defp stream_new_logs(conn) do
    receive do
      {:log, log} ->
        case send_event(conn, "log", Jason.encode!(log)) do
          {:ok, conn} -> stream_new_logs(conn)
          {:error, :closed} -> conn
        end

      # Handle other messages as needed
      v ->
        Logger.warning("unknown message: #{inspect(v)}")
        stream_new_logs(conn)
    end
  end
end
