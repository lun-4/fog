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

  @doc """
  Store many `{line, %DateTime{}}` entries in a single call. The entries are
  written to disk with a single `IO.write` per day-file, and a single ack is
  sent back to the caller.
  """
  def store_batch(server, entries) when is_list(entries) do
    GenServer.call(server, {:store_batch, entries})
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

  @impl true
  def handle_call({:store, line, %DateTime{} = timestamp}, {agent_pid, _}, state) do
    {key0, key1} = state.k0k1
    state = write_chunk(state, key0, key1, [{line, timestamp}])
    state = put_in(state.websocket_pids, Map.put(state.websocket_pids, agent_pid, true))

    send(agent_pid, {:log_server_ack, key0, key1})
    {:reply, :ok, state}
  end

  def handle_call({:store_batch, entries}, {agent_pid, _}, state) do
    {key0, key1} = state.k0k1

    # group consecutive same-day entries so each day-file takes a single IO.write.
    # (batches are time-ordered so same-day entries are consecutive; day rollover
    #  mid-batch just yields more than one chunk, which is still correct.)
    state =
      entries
      |> Enum.chunk_by(fn {_line, %DateTime{} = ts} ->
        Fog.LogStore.file_for(:writing, key0, key1, ts)
      end)
      |> Enum.reduce(state, fn chunk, acc -> write_chunk(acc, key0, key1, chunk) end)

    state = put_in(state.websocket_pids, Map.put(state.websocket_pids, agent_pid, true))

    # one ack per batch
    send(agent_pid, {:log_server_ack, key0, key1})
    {:reply, :ok, state}
  end

  # writes a chunk of {line, timestamp} entries that all belong to the same day-file,
  # with a single IO.write, tracking the byte offset in-state (no per-line fstat/seek
  # syscall) and filling in-memory index_ts_v1 seek slots as we go.
  defp write_chunk(state, _key0, _key1, []), do: state

  defp write_chunk(state, key0, key1, [{_line, %DateTime{} = first_ts} | _] = chunk) do
    log_path = Fog.LogStore.file_for(:writing, key0, key1, first_ts)
    index_path = Fog.IndexStore.path_for(key0, key1, first_ts)

    {index_data, index_was_present?} =
      get_index_data(state, key0, key1, first_ts, log_path, index_path)

    {fd, offset0} = get_fd(state, log_path)

    {iodata, final_offset, index_data, index_changed?} =
      Enum.reduce(chunk, {[], offset0, index_data, false}, fn {line, %DateTime{} = ts},
                                                              {io_acc, offset, idx, changed} ->
        timestamp_unix_ms = DateTime.to_unix(ts, :millisecond)
        # storage format v1: <version>\t<timestamp>\t<log itself>
        payload = "1\t#{timestamp_unix_ms}\t#{line}\n"

        {idx, changed} =
          if idx != nil do
            second_of_day = Fog.IndexStore.second_of_day(ts)

            if Enum.at(idx.seeks, second_of_day) == -1 do
              {put_in(idx.seeks, List.replace_at(idx.seeks, second_of_day, offset)), true}
            else
              {idx, changed}
            end
          else
            {idx, changed}
          end

        {[io_acc, payload], offset + byte_size(payload), idx, changed}
      end)

    IO.write(fd, iodata)

    state =
      if index_data != nil do
        # W6: when we start tracking a fresh index in memory, checkpoint it right away
        # instead of leaving the first seeks unsynced for up to a full minute.
        if not index_was_present? and index_changed? do
          Fog.IndexStore.write(key0, key1, first_ts, index_data)
        end

        put_in(
          state.index_ts_v1,
          Map.put(state.index_ts_v1, index_path, {key0, key1, first_ts, index_data})
        )
      else
        state
      end

    put_in(state.fds, Map.put(state.fds, log_path, {fd, System.monotonic_time(), final_offset}))
  end

  defp get_index_data(state, key0, key1, timestamp, log_path, index_path) do
    build_index_ts_v1? = Fog.IndexStore.should_index_log_path?(log_path)
    index_was_present? = Map.has_key?(state.index_ts_v1, index_path)
    maybe_index_data = Map.get(state.index_ts_v1, index_path)

    {:ok, index_data} =
      cond do
        not build_index_ts_v1? ->
          {:ok, nil}

        maybe_index_data == nil ->
          case Fog.IndexStore.read(key0, key1, timestamp) do
            {:error, :enoent} ->
              # log file is bigger than the desired indexable size but has no index yet;
              # build it now so queries against this file are fast.
              :ok = Fog.LogStore.build_index_ts_v1(key0, key1, timestamp)
              Fog.IndexStore.read(key0, key1, timestamp)

            {:ok, _} = v ->
              v
          end

        true ->
          {_, _, _, real_index_data} = maybe_index_data
          {:ok, real_index_data}
      end

    {index_data, index_was_present?}
  end

  # returns {fd, current_offset}. the offset is tracked in-state (initialised to the
  # file size on open) so we never pay a per-line :file.position/2 syscall.
  defp get_fd(state, log_path) do
    case Map.get(state.fds, log_path) do
      {fd, _fd_timestamp, offset} ->
        {fd, offset}

      nil ->
        {:ok, fd} = File.open(log_path, [:append])
        {:ok, offset} = :file.position(fd, :eof)
        {fd, offset}
    end
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
      {k0, k1} = state.k0k1
      Logger.info("#{k0}/#{k1}: Synced index for #{Enum.count(index_ts_v1)} log files")
      schedule_index_syncing()

      {:noreply, put_in(state.index_ts_v1, index_ts_v1)}
    end)
  end

  @impl true
  def handle_info(:check_unused_fds, state) do
    state.fds
    |> Enum.map(fn {path, {fd, fd_timestamp, offset}} ->
      current_timestamp = System.monotonic_time()
      delta = System.convert_time_unit(current_timestamp - fd_timestamp, :native, :second)
      # if it's been an hour, we should close it
      if delta > 3600 do
        Logger.debug("closing unused file descriptor for #{path}, unused for #{delta} seconds")
        File.close(fd)
        nil
      else
        {path, {fd, fd_timestamp, offset}}
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
