defmodule FogWeb.LogController do
  use FogWeb, :controller

  def incoming_line(conn, params) do
    {:ok, log_line, _conn_details} = Plug.Conn.read_body(conn)
    IO.inspect(conn)
    IO.puts(log_line)

    Fog.Log.insert!(
      DateTime.utc_now() |> DateTime.to_unix(),
      log_line
    )

    conn
    |> json(%{})
  end

  def exec_filters(logs, params) do
    maybe_exact = params |> Map.get("filter_grep_exact")

    if maybe_exact do
      logs
      |> Enum.filter(fn log ->
        String.contains?(log.entry, maybe_exact)
      end)
    else
      logs
    end
  end

  def fetch_logs(conn, params) do
    {start_ts, ""} = params |> Map.get("start") |> Integer.parse()
    {end_ts, ""} = params |> Map.get("end") |> Integer.parse()

    Fog.Log.logs_between_timestamps!(start_ts, end_ts)
    |> Enum.map(fn entry ->
      Map.delete(entry, :__struct__)
      |> Map.delete(:__meta__)
    end)
    |> exec_filters(params)
    |> then(fn logs ->
      %{
        logs: logs
      }
    end)
    |> then(fn body ->
      conn
      |> json(body)
    end)
  end
end
