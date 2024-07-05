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
end
