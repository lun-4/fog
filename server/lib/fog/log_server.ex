defmodule Fog.LogServer do
  @moduledoc """
  while Fog.LogStore deals with the low level storage decisions (reads/writes, parsing, etc)
  Fog.LogServer deals with high level (example, when to run index, keeping tabs on current index, etc)
  """
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, opts)
  end

  def store(server, line, timestamp) do
    GenServer.call(server, {:store, line, timestamp})
  end

  @spec get_or_start_server(String.t(), String.t()) :: {:ok, pid} | term()
  def get_or_start_server(key0, key1) do
    k0k1 = {key0, key1}

    case Registry.lookup(Fog.LogServer.Registry, k0k1) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Fog.LogServer.Supervisor,
               %{
                 id: __MODULE__,
                 restart: :permanent,
                 start:
                   {__MODULE__, :start_link,
                    [
                      [
                        k0k1: k0k1,
                        name: {:via, Registry, {Fog.LogServer.Registry, k0k1, :self}}
                      ]
                    ]}
               }
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    k0k1 = opts |> Keyword.fetch!(:k0k1)
    Logger.info("Starting #{__MODULE__} k0k1=#{inspect(k0k1)}")
    {:ok, %{opts: opts, k0k1: k0k1, fds: %{}}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  @impl true
  def handle_call({:store, line, %DateTime{} = timestamp}, _from, state) do
    {key0, key1} = state.k0k1
    log_path = Fog.LogStore.file_for(:writing, key0, key1, timestamp)

    maybe_fd = state.fds |> Map.get(log_path)

    {:ok, fd} =
      case maybe_fd do
        {fd, _} -> {:ok, fd}
        nil -> File.open(log_path, [:append])
      end

    timestamp_unix_ms = timestamp |> DateTime.to_unix(:millisecond)
    # <version>\t<timestamp>\t<log itself>
    IO.write(fd, "1\t#{timestamp_unix_ms}\t#{line}\n")
    Logger.debug("Logged line #{line} at timestamp #{timestamp} to file @ #{log_path}.")
    fd_timestamp = System.monotonic_time()
    {:reply, :ok, put_in(state.fds, Map.put(state.fds, log_path, {fd, fd_timestamp}))}
  end

  @impl true
  def handle_cast(:check_unused_fds, state) do
    state.fds
    |> Enum.map(fn {path, {fd, fd_timestamp}} ->
      current_timestamp = System.monotonic_time()
      delta = System.convert_time_unit(current_timestamp - fd_timestamp, :native, :second)
      # if it's been an hour, we should close it
      if delta > 3600 do
        Logger.debug("closing unused file descriptor for #{path}, unused for #{delta} seconds")
        File.close(fd)
        nil
      else
        {fd, fd_timestamp}
      end
    end)
    |> Enum.filter(fn v -> v != nil end)
    |> then(fn new_fds ->
      {:noreply, put_in(state.fds, new_fds)}
    end)
  end

  @impl true
  def terminate(reason, state) do
    Logger.warning(
      "Terminating #{__MODULE__}, reason: #{inspect(reason)}, state: #{inspect(state)}"
    )

    :ok
  end
end
