defmodule FogWeb.AgentSocket do
  require Logger
  @behaviour Phoenix.Socket.Transport

  def child_spec(_opts) do
    :ignore
  end

  def connect(state) do
    Logger.debug("Agent socket connect called #{inspect(state)}")
    {:ok, state}
  end

  def init(state) do
    Logger.debug("Agent socket init called #{inspect(state)}")
    send(self(), :validate_auth)
    {:ok, state}
  end

  def handle_in({text, opts}, state) do
    Logger.debug(
      "Agent socket handle_in called, text=#{inspect(text)} opts=#{inspect(opts)} state=#{inspect(state)}"
    )

    case Jason.decode(text) do
      {:ok, message} ->
        handle_message(message, opts, state)

      {:error, _reason} ->
        reply = Jason.encode!(%{error: "invalid_json"})
        {:reply, :ok, {:text, reply}, state}
    end
  end

  defp json(msg), do: {:text, Jason.encode!(msg)}

  def handle_info({:log_server_ack, k0, k1}, state) do
    Logger.debug("ack #{k0} #{k1}")

    {:push,
     json(%{
       op: "send_ack",
       data: %{
         key0: k0,
         key1: k1
       }
     }), state}
  end

  def handle_info(:validate_auth, state) do
    given_token = state.params["token"]

    if given_token == nil do
      {:stop, :normal, {4000, "missing token"}, state}
    else
      {:ok, maybe_token} = Fog.Authentication.one(given_token)

      if maybe_token == nil do
        {:stop, :normal, {4001, "invalid token"}, state}
      else
        {:push,
         json(%{
           op: "hello",
           data: %{}
         }), state}
      end
    end
  end

  def handle_info(message, state) do
    Logger.warning(
      "Agent socket handle_info called, message=#{inspect(message)} state=#{inspect(state)}"
    )

    {:ok, state}
  end

  def terminate(reason, _state) do
    Logger.debug("Agent socket terminate called: reason=#{inspect(reason)}")

    case reason do
      {:error, :closed} -> :noop
      {:error, v} -> Logger.error(inspect(v))
      _ -> :noop
    end

    :ok
  end

  defp handle_message(%{"op" => "heartbeat"} = _message, _opts, state) do
    {:reply, :ok, json(%{op: "heartbeat_ack"}), state}
  end

  defp handle_message(
         %{"op" => "send", "data" => %{"data" => log_line, "key0" => key0, "key1" => key1} = data} =
           _message,
         _opts,
         state
       ) do
    :ok = Fog.LogStore.store(key0, key1, log_line, data |> Map.get("timestamp"))
    {:ok, state}
  end

  defp handle_message(_message, _opts, state) do
    {:stop, :normal, {4000, "unknown op or bad data"}, state}
  end
end
