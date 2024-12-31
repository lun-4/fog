defmodule FogWeb.AgentSocket do
  require Logger
  @behaviour Phoenix.Socket.Transport

  def child_spec(_opts) do
    :ignore
  end

  def connect(state) do
    Logger.debug("Agent socket connect called")
    {:ok, state}
  end

  def init(state) do
    Logger.debug("Agent socket init called")
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

  def handle_info(message, state) do
    Logger.debug(
      "Agent socket handle_info called, message=#{inspect(message)} state=#{inspect(state)}"
    )

    # Handle messages from other processes
    {:push, {:text, Jason.encode!(message)}, state}
  end

  def terminate(reason, _state) do
    Logger.debug("Agent socket terminate called: reason=#{inspect(reason)}")
    :ok
  end

  # Custom message handling
  defp handle_message(%{"type" => "heartbeat"} = _message, _opts, state) do
    reply = Jason.encode!(%{type: "heartbeat_ack"})
    {:reply, :ok, {:text, reply}, state}
  end

  defp handle_message(message, _opts, state) do
    reply = Jason.encode!(%{error: "unknown_message_type", received: message})
    {:reply, :ok, {:text, reply}, state}
  end
end
