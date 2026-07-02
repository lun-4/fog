defmodule Fog.LogStore.Realtime do
  use GenServer
  require Logger

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def generate_client_id do
    <<i1::32, i2::32, i3::32>> = :crypto.strong_rand_bytes(12)
    "client_#{i1}#{i2}#{i3}"
  end

  def subscribe(client_id, filter_params) do
    GenServer.call(__MODULE__, {:subscribe, client_id, filter_params})
  end

  def unsubscribe(client_id) do
    GenServer.call(__MODULE__, {:unsubscribe, client_id})
  end

  def process_log(log_entry) do
    GenServer.cast(__MODULE__, {:process_log, log_entry})
  end

  @subscriber_table :fog_realtime_subs
  @ingest_table :fog_ingest_counts

  @doc """
  Fast, lock-free check for whether any client is currently following. Lets the
  ingestion path skip the `process_log` cast (and this GenServer's mailbox) entirely
  when nobody is subscribed.
  """
  def any_subscribers? do
    case :ets.whereis(@subscriber_table) do
      :undefined -> false
      _ -> :ets.lookup_element(@subscriber_table, :count, 2) > 0
    end
  end

  @doc """
  Count `n` ingested log lines for `{key0, key1}`. Uses a lock-free ETS counter so
  the per-second "received N logs" stat keeps working even when nobody is following
  (i.e. independently of whether `process_log/1` runs).
  """
  def count_ingest(key0, key1, n) do
    case :ets.whereis(@ingest_table) do
      :undefined -> :ok
      _ -> :ets.update_counter(@ingest_table, {key0, key1}, n, {{key0, key1}, 0})
    end

    :ok
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@subscriber_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(@subscriber_table, {:count, 0})

    :ets.new(@ingest_table, [:named_table, :public, :set, write_concurrency: true])

    schedule_log()

    {:ok,
     %{
       # Map of filter hash -> %{filter: filter_params, parsed: parsed_filter, clients: [{client_id, pid}, ...]}
       filters: %{},
       # Map of client_id -> {filter_hash, pid} for quick lookups during unsubscribe
       clients: %{}
     }}
  end

  defp publish_subscriber_count(clients) do
    :ets.insert(@subscriber_table, {:count, map_size(clients)})
  end

  defp schedule_log() do
    Process.send_after(self(), :schedule_log, 1000)
  end

  @impl true
  def handle_call({:subscribe, client_id, filter_params}, {pid, _}, state) do
    case validate_filter_params(filter_params) do
      :ok ->
        # Monitor the subscriber to handle crashes/disconnects
        Process.monitor(pid)

        filter_hash = hash_filter(filter_params)
        parsed = parse_filter(filter_params)

        # Update filters map
        new_filters =
          Map.update(
            state.filters,
            filter_hash,
            %{filter: filter_params, parsed: parsed, clients: [{client_id, pid}]},
            fn %{clients: clients} = filter_entry ->
              %{filter_entry | clients: [{client_id, pid} | clients]}
            end
          )

        # Update clients map
        new_clients = Map.put(state.clients, client_id, {filter_hash, pid})
        publish_subscriber_count(new_clients)

        {:reply, :ok, %{state | filters: new_filters, clients: new_clients}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:unsubscribe, client_id}, _from, state) do
    case Map.get(state.clients, client_id) do
      nil ->
        {:reply, :ok, state}

      {filter_hash, _client_pid} ->
        # Remove client from the filter's client list
        new_filters =
          case Map.get(state.filters, filter_hash) do
            %{clients: clients} = filter_entry ->
              updated_clients = Enum.reject(clients, fn {cid, _} -> cid == client_id end)

              if Enum.empty?(updated_clients) do
                Map.delete(state.filters, filter_hash)
              else
                Map.put(state.filters, filter_hash, %{filter_entry | clients: updated_clients})
              end
          end

        new_clients = Map.delete(state.clients, client_id)
        publish_subscriber_count(new_clients)

        {:reply, :ok, %{state | filters: new_filters, clients: new_clients}}
    end
  end

  @impl true
  def handle_cast({:process_log, %Fog.LogStore.LogLine{} = log_entry}, state) do
    Enum.each(state.filters, fn {_hash, %{parsed: parsed, clients: clients}} ->
      if matches_filter?(log_entry, parsed) do
        Enum.each(clients, fn {client_id, pid} ->
          send(pid, {:log_entry, client_id, log_entry})
        end)
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:schedule_log, state) do
    # counts are accumulated at ingest time via count_ingest/3 (ETS), so this works
    # whether or not anyone is following. subtract exactly what we logged so lines
    # counted between tab2list and reset aren't lost.
    :ets.tab2list(@ingest_table)
    |> Enum.each(fn {{k0, k1} = key, count} ->
      if count > 0 do
        Logger.info("#{k0}/#{k1}: received #{count} logs")
        :ets.update_counter(@ingest_table, key, -count)
      end
    end)

    schedule_log()
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Find all client_ids associated with the dead pid
    dead_clients =
      Enum.filter(state.clients, fn {_client_id, {_hash, client_pid}} ->
        client_pid == pid
      end)

    # Remove each dead client
    new_state =
      Enum.reduce(dead_clients, state, fn {client_id, _}, acc ->
        {:reply, :ok, new_state} = handle_call({:unsubscribe, client_id}, nil, acc)
        new_state
      end)

    {:noreply, new_state}
  end

  # Private Functions

  defp hash_filter(filter_params) do
    filter_params
    |> :erlang.term_to_binary()
    |> :erlang.phash2()
  end

  # resolve since/until to absolute DateTimes once, at subscribe time, instead of
  # re-parsing the strings on every log line for every subscriber. relative windows
  # (e.g. "2h") become absolute at subscribe time, which is what a live follow wants.
  defp parse_filter(filter_params) do
    {:ok, since} = Fog.LogStore.parse_datetime(Map.get(filter_params, "since"))
    {:ok, until} = Fog.LogStore.parse_datetime(Map.get(filter_params, "until"))

    %{
      selectors: Map.get(filter_params, "selectors"),
      since: since,
      until: until,
      grep: Map.get(filter_params, "grep")
    }
  end

  defp validate_filter_params(params) do
    Logger.debug("subscribing with params: #{inspect(params)}")
    valid_keys = ~w(selectors since until grep follow limit)

    cond do
      not is_map(params) ->
        {:error, "Filter params must be a map"}

      params["follow"] && params["until"] ->
        {:error, "Cannot specify both 'follow' and 'until' parameters"}

      Enum.any?(Map.keys(params), &(&1 not in valid_keys)) ->
        {:error, "Invalid filter parameter"}

      true ->
        :ok
    end
  end

  defp matches_filter?(log_entry, parsed) do
    matches_selectors?(log_entry, parsed) and
      matches_time_range?(log_entry, parsed) and
      matches_grep?(log_entry, parsed)
  end

  defp matches_selectors?(entry, %{selectors: selectors}),
    do: Fog.LogStore.matches_selectors?({entry.key0, entry.key1}, selectors)

  defp matches_time_range?(log_entry, %{since: since, until: until}) do
    timestamp = log_entry.timestamp || raise "nil timestamp. should never happen"

    cond do
      is_nil(since) and is_nil(until) ->
        true

      is_nil(since) ->
        DateTime.compare(timestamp, until) in [:lt, :eq]

      is_nil(until) ->
        DateTime.compare(timestamp, since) in [:gt, :eq]

      true ->
        DateTime.compare(timestamp, since) in [:gt, :eq] and
          DateTime.compare(timestamp, until) in [:lt, :eq]
    end
  end

  defp matches_grep?(_entry, %{grep: nil}), do: true

  defp matches_grep?(%Fog.LogStore.LogLine{text: data}, %{grep: pattern}) when is_binary(data),
    do: String.contains?(data, pattern)

  defp matches_grep?(_entry, _parsed), do: false
end
