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
    :ok = File.mkdir_p(Fog.LogStore.tmp_path())

    schedule_unused_fds()
    schedule_index_syncing()

    {:ok,
     %{
       opts: opts,
       k0k1: k0k1,
       fds: %{},
       index_ts_v1: %{},
       websocket_pids: %{}
     }}
  end

  defp schedule_unused_fds() do
    Process.send_after(self(), :check_unused_fds, 10 * 60 * 1000)
  end

  defp schedule_index_syncing() do
    # index_ts_v1 is per-second
    # so checkpointing every minute sounds fine
    Process.send_after(self(), :sync_index, 1 * 60 * 1000)
  end

  @devmode false

  @impl true
  def handle_call({:store, line, %DateTime{} = timestamp}, {agent_pid, _}, state) do
    {key0, key1} = state.k0k1
    log_path = Fog.LogStore.file_for(:writing, key0, key1, timestamp)
    index_path = Fog.IndexStore.path_for(key0, key1, timestamp)

    build_index_ts_v1? = Fog.IndexStore.should_index_log_path?(log_path)
    maybe_index_data = state.index_ts_v1 |> Map.get(index_path)

    {:ok, index_data} =
      cond do
        not build_index_ts_v1? ->
          {:ok, nil}

        maybe_index_data == nil ->
          case Fog.IndexStore.read(key0, key1, timestamp) do
            {:error, :enoent} ->
              # we need to build the index for this file right now as it's not available
              # and we want it (as our log file is bigger than the desired indexable size)
              :ok = Fog.LogStore.build_index_ts_v1(key0, key1, timestamp)
              Fog.IndexStore.read(key0, key1, timestamp)

            {:ok, _} = v ->
              v
          end

        true ->
          {_, _, _, real_index_data} = maybe_index_data
          {:ok, real_index_data}
      end

    maybe_fd = state.fds |> Map.get(log_path)

    {:ok, fd} =
      case maybe_fd do
        {fd, _} ->
          {:ok, fd}

        nil ->
          with {:ok, fd} <- File.open(log_path, [:append]) do
            {:ok, _} = :file.position(fd, :eof)
            {:ok, fd}
          end
      end

    timestamp_unix_ms = timestamp |> DateTime.to_unix(:millisecond)
    {:ok, current_seek} = :file.position(fd, :cur)
    # TODO (optimization): batch to temporary file then fsync+rename
    # <version>\t<timestamp>\t<log itself>
    IO.write(fd, "1\t#{timestamp_unix_ms}\t#{line}\n")

    if @devmode do
      Logger.debug("log line=#{line}, tstamp=#{timestamp}, file=#{log_path}")
    end

    fd_timestamp = System.monotonic_time()

    # if index_data didn't have this second of the day, set it
    # (writing to the index file happens asynchronously)
    state =
      if index_data != nil do
        second_of_day = Fog.IndexStore.second_of_day(timestamp)

        maybe_seek =
          if index_data != nil do
            index_data.seeks |> Enum.at(second_of_day)
          else
            -1
          end

        # TODO (optimization): if we are a new index, we should sync immediately instead of waiting
        # one entire minute with very useful data in-memory...
        index_data =
          if maybe_seek == -1 do
            Logger.debug(
              "#{state.key0}/#{state.key1} log server: setting index_ts_v1 seek at #{inspect(second_of_day)} = #{current_seek}"
            )

            put_in(
              index_data.seeks,
              index_data.seeks |> List.replace_at(second_of_day, current_seek)
            )
          else
            index_data
          end

        put_in(
          state.index_ts_v1,
          Map.put(state.index_ts_v1, index_path, {key0, key1, timestamp, index_data})
        )
      else
        state
      end

    state = put_in(state.fds, Map.put(state.fds, log_path, {fd, fd_timestamp}))

    state =
      put_in(
        state.websocket_pids,
        Map.put(state.websocket_pids, agent_pid, true)
      )

    # for now since we don't batch, ack always
    send(agent_pid, {:log_server_ack, key0, key1})

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sync_index, state) do
    state.index_ts_v1
    |> Stream.filter(fn {_, {_, _, _, index_data}} ->
      index_data != nil
    end)
    |> Enum.map(fn {_, {key0, key1, timestamp, index_data}} = kv ->
      Logger.debug("Syncing index for #{key0}/#{key1}/#{timestamp}...")
      Fog.IndexStore.write(key0, key1, timestamp, index_data)
      kv
    end)
    # remove index data after 2 days to prevent memleaks
    |> Enum.filter(fn {_, {_, _, timestamp, _}} ->
      now = DateTime.utc_now()
      amount_of_days = DateTime.diff(now, timestamp, :day)
      amount_of_days < 2
    end)
    |> Map.new()
    |> then(fn index_ts_v1 ->
      Logger.info("Synced index for all #{Enum.count(index_ts_v1)} keys")

      {:noreply, put_in(state.index_ts_v1, index_ts_v1)}
    end)
  end

  @impl true
  def handle_info(:check_unused_fds, state) do
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
        {path, {fd, fd_timestamp}}
      end
    end)
    |> Enum.filter(fn v -> v != nil end)
    |> Map.new()
    |> then(fn new_fds ->
      schedule_unused_fds()
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
