defmodule FogWeb.AuthPlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_token(conn) do
      {:ok, token} ->
        case validate_token(token) do
          true ->
            assign(conn, :authenticated, true)

          false ->
            conn
            |> put_status(:unauthorized)
            |> Phoenix.Controller.json(%{error: "Invalid authentication token"})
            |> halt()
        end

      :error ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "Missing authentication token"})
        |> halt()
    end
  end

  defp get_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> :error
    end
  end

  defp validate_token(token) do
    case Fog.Authentication.one(token) do
      {:ok, nil} -> false
      {:ok, t} -> t.active
    end
  end
end
