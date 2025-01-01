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

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok,
     %{
       # Map of filter hash -> %{filter: filter_params, clients: [{client_id, pid}, ...]}
       filters: %{},
       # Map of client_id -> {filter_hash, pid} for quick lookups during unsubscribe
       clients: %{}
     }}
  end

  @impl true
  def handle_call({:subscribe, client_id, filter_params}, {pid, _}, state) do
    case validate_filter_params(filter_params) do
      :ok ->
        # Monitor the subscriber to handle crashes/disconnects
        Process.monitor(pid)

        filter_hash = hash_filter(filter_params)

        # Update filters map
        new_filters =
          Map.update(
            state.filters,
            filter_hash,
            %{filter: filter_params, clients: [{client_id, pid}]},
            fn %{filter: ^filter_params, clients: clients} = filter_entry ->
              %{filter_entry | clients: [{client_id, pid} | clients]}
            end
          )

        # Update clients map
        new_clients = Map.put(state.clients, client_id, {filter_hash, pid})

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

      {filter_hash, client_pid} ->
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

        {:reply, :ok, %{state | filters: new_filters, clients: new_clients}}
    end
  end

  @impl true
  def handle_cast({:process_log, log_entry}, state) do
    Enum.each(state.filters, fn {_hash, %{filter: filter_params, clients: clients}} ->
      if matches_filter?(log_entry, filter_params) do
        Enum.each(clients, fn {client_id, pid} ->
          send(pid, {:log_entry, client_id, log_entry})
        end)
      end
    end)

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

  defp validate_filter_params(params) do
    valid_keys = ~w(key0 key1 since until grep follow limit)

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

  defp matches_filter?(log_entry, filter_params) do
    with true <- matches_key0?(log_entry, filter_params),
         true <- matches_key1?(log_entry, filter_params),
         true <- matches_time_range?(log_entry, filter_params),
         true <- matches_grep?(log_entry, filter_params) do
      true
    else
      false -> false
    end
  end

  defp matches_key0?(%{"key0" => key0}, %{"key0" => filter_key0})
       when is_list(filter_key0),
       do: key0 in filter_key0

  defp matches_key0?(%{"key0" => key0}, %{"key0" => filter_key0}),
    do: key0 == filter_key0

  defp matches_key0?(_, %{"key0" => _}), do: false
  defp matches_key0?(_, _), do: true

  defp matches_key1?(%{"key1" => key1}, %{"key1" => filter_key1})
       when is_list(filter_key1),
       do: key1 in filter_key1

  defp matches_key1?(%{"key1" => key1}, %{"key1" => filter_key1}),
    do: key1 == filter_key1

  defp matches_key1?(_, %{"key1" => _}), do: false
  defp matches_key1?(_, _), do: true

  defp matches_time_range?(log_entry, filter_params) do
    timestamp = Map.get(log_entry, "timestamp")
    since = Map.get(filter_params, "since")
    until = Map.get(filter_params, "until")

    cond do
      is_nil(timestamp) ->
        false

      is_nil(since) and is_nil(until) ->
        true

      is_nil(since) ->
        compare_timestamps(timestamp, until) <= 0

      is_nil(until) ->
        compare_timestamps(timestamp, since) >= 0

      true ->
        compare_timestamps(timestamp, since) >= 0 and compare_timestamps(timestamp, until) <= 0
    end
  end

  defp matches_grep?(%{"data" => data}, %{"grep" => pattern}) when is_binary(data) do
    String.contains?(data, pattern)
  end

  defp matches_grep?(_, %{"grep" => _}), do: false
  defp matches_grep?(_, _), do: true

  defp compare_timestamps(timestamp1, timestamp2) do
    DateTime.compare(
      parse_timestamp(timestamp1),
      parse_timestamp(timestamp2)
    )
  end

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _} -> datetime
      _ -> raise "Invalid timestamp format"
    end
  end

  defp parse_timestamp(timestamp), do: timestamp
end
