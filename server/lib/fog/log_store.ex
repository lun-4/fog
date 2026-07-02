defmodule Fog.LogStore do
  require Logger

  defmodule LogLine do
    @derive Jason.Encoder

    defstruct [:key0, :key1, :timestamp, :text]
  end

  def data_path do
    cfg = Application.fetch_env!(:fog, Fog.LogStore)
    Path.expand(cfg[:data_path])
  end

  def tmp_path do
    Path.join([data_path(), "_fog_internal_tmp"])
  end

  def folder_for(key0, key1) do
    path = Path.join([data_path(), key0, key1])
    File.mkdir_p!(path)
    path
  end

  def file_for(:writing, key0, key1, timestamp) do
    Path.join([
      folder_for(key0, key1),
      "#{timestamp.year}-#{timestamp.month}-#{timestamp.day}.log"
    ])
  end

  @spec files_for(String.t(), String.t(), DateTime.t(), DateTime.t()) :: list()
  defp files_for(key0, key1, initial_timestamp, final_timestamp) do
    Date.range(
      initial_timestamp |> DateTime.to_date(),
      final_timestamp |> DateTime.to_date()
    )
    |> Stream.map(fn date ->
      timestamp = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      {timestamp, file_for(:writing, key0, key1, timestamp)}
    end)
    |> Stream.filter(fn {_, possible_path} ->
      File.exists?(possible_path)
    end)
    |> Enum.to_list()
  end

  def store(key0, key1, line, timestamp \\ nil) do
    now =
      if timestamp == nil do
        DateTime.utc_now()
      else
        DateTime.from_unix!(timestamp, :millisecond)
      end

    {:ok, server} = Fog.LogServer.get_or_start_server(key0, key1)
    :ok = Fog.LogServer.store(server, line, now)

    Fog.LogStore.Realtime.count_ingest(key0, key1, 1)
    maybe_fan_out(%LogLine{key0: key0, key1: key1, timestamp: now, text: line})
    :ok
  end

  @doc """
  Store a batch of log lines for one `{key0, key1}` in a single writer round-trip.

  `lines` is a list of maps `%{"data" => text, "timestamp" => unix_ms}` (as decoded
  from the agent's `send_batch` frame); a missing/nil timestamp falls back to now.
  """
  def store_batch(key0, key1, lines) when is_list(lines) do
    now = DateTime.utc_now()

    entries =
      Enum.map(lines, fn entry ->
        text = Map.fetch!(entry, "data")

        ts =
          case Map.get(entry, "timestamp") do
            nil -> now
            ms -> DateTime.from_unix!(ms, :millisecond)
          end

        {text, ts}
      end)

    {:ok, server} = Fog.LogServer.get_or_start_server(key0, key1)
    :ok = Fog.LogServer.store_batch(server, entries)

    Fog.LogStore.Realtime.count_ingest(key0, key1, length(entries))

    # only pay the realtime fan-out when someone is actually following
    if Fog.LogStore.Realtime.any_subscribers?() do
      Enum.each(entries, fn {text, ts} ->
        Fog.LogStore.Realtime.process_log(%LogLine{
          key0: key0,
          key1: key1,
          timestamp: ts,
          text: text
        })
      end)
    end

    :ok
  end

  # skip the single global Realtime GenServer entirely when there are no followers,
  # so steady-state ingestion doesn't serialize through its mailbox.
  defp maybe_fan_out(%LogLine{} = log_line) do
    if Fog.LogStore.Realtime.any_subscribers?() do
      Fog.LogStore.Realtime.process_log(log_line)
    end

    :ok
  end

  def parse_datetime(nil), do: {:ok, nil}

  def parse_datetime(input) when is_binary(input) do
    cond do
      String.match?(input, ~r/^\d{4}-\d{2}-\d{2}/) ->
        # ISO8601 format
        case DateTime.from_iso8601(input) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          {:error, reason} -> {:error, reason}
        end

      String.match?(input, ~r/^(\d+)(m|min|h|d|w)$/) ->
        # Relative time format
        [_, value, unit] = Regex.run(~r/^(\d+)(min|h|d|w)$/, input)
        value = String.to_integer(value)

        seconds =
          case unit do
            v when v in ["m", "min"] -> value * 60
            "h" -> value * 60 * 60
            "d" -> value * 24 * 60 * 60
            "w" -> value * 7 * 24 * 60 * 60
          end

        {:ok, DateTime.add(DateTime.utc_now(), -seconds, :second)}

      true ->
        {:error, :invalid_format}
    end
  end

  defp list_child_folders(path) do
    case File.ls(path) do
      {:ok, files} ->
        folders =
          files
          |> Enum.filter(fn file ->
            path
            |> Path.join(file)
            |> File.dir?()
          end)
          |> Enum.sort()

        {:ok, folders}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def all_key0!() do
    {:ok, r} = list_child_folders(data_path())
    r
  end

  def key1_for!(key0) do
    {:ok, r} = list_child_folders(Path.join(data_path(), key0))
    r
  end

  def all_keys() do
    all_key0!()
    |> Enum.flat_map(fn key0 ->
      key1_for!(key0)
      |> Enum.map(fn key1 ->
        {key0, key1}
      end)
    end)
  end

  def matches_selectors?({key0, key1}, selectors) do
    selectors
    |> Enum.map(fn selector ->
      case selector |> String.split(".") do
        ["*", "*"] ->
          true

        [wanted_key0, "*"] ->
          wanted_key0 == key0

        ["*", wanted_key1] ->
          wanted_key1 == key1

        [wanted_key0, wanted_key1] ->
          wanted_key0 == key0 and wanted_key1 == key1

        _ ->
          raise "selector has invalid format: #{inspect(selector)}"
      end
    end)
    |> Enum.any?()
  end

  # resolve selectors directly to the {key0, key1} pairs they match, only listing
  # directories when a wildcard actually requires it. a fully-qualified k0.k1 becomes
  # a single existence check rather than a full walk of the whole data directory.
  def resolve_selectors(selectors) do
    selectors
    |> Enum.flat_map(&resolve_selector/1)
    |> Enum.uniq()
  end

  defp resolve_selector(selector) do
    case String.split(selector, ".") do
      ["*", "*"] ->
        all_keys()

      [wanted_key0, "*"] ->
        key1_for!(wanted_key0)
        |> Enum.map(fn key1 -> {wanted_key0, key1} end)

      ["*", wanted_key1] ->
        all_key0!()
        |> Enum.filter(fn key0 ->
          Path.join([data_path(), key0, wanted_key1]) |> File.dir?()
        end)
        |> Enum.map(fn key0 -> {key0, wanted_key1} end)

      [wanted_key0, wanted_key1] ->
        if Path.join([data_path(), wanted_key0, wanted_key1]) |> File.dir?() do
          [{wanted_key0, wanted_key1}]
        else
          []
        end

      _ ->
        raise "selector has invalid format: #{inspect(selector)}"
    end
  end

  # returns {files_by_key, since, until} where files_by_key is a list of
  # {k0k1, [{date_dt, file_path}, ...]}, each inner list ordered ascending by date.
  defp get_files_for(params) do
    wanted_keys = resolve_selectors(params["selectors"])
    Logger.debug("wanted keys: #{inspect(wanted_keys)}")

    since_default = DateTime.utc_now() |> DateTime.add(-30, :second)
    {:ok, since} = (params["since"] || DateTime.to_iso8601(since_default)) |> parse_datetime

    until_default = DateTime.utc_now() |> DateTime.add(1, :second)
    {:ok, until} = (params["until"] || DateTime.to_iso8601(until_default)) |> parse_datetime

    files_by_key =
      wanted_keys
      |> Enum.map(fn {key0, key1} = k0k1 ->
        {k0k1, files_for(key0, key1, since, until)}
      end)
      |> Enum.reject(fn {_k0k1, files} -> files == [] end)

    {files_by_key, since, until}
  end

  def query(params, opts \\ []) do
    Logger.info("query: #{inspect(params)}")

    limit = params["limit"] || raise "missing limit. this is a bug"
    {limit, ""} = Integer.parse(limit)

    {files_by_key, since, until} = get_files_for(params)

    Logger.debug("querying #{inspect(params)}, got #{length(files_by_key)} streams to read")
    Logger.debug("since: #{since}, until: #{until}")

    if DateTime.compare(since, until) == :gt do
      raise "since must be before until. this is a bug. since: #{inspect(since)}, until: #{inspect(until)}. #{inspect(DateTime.compare(since, until))}"
    end

    grep = params["grep"]

    # each stream (one k0.k1) is read in ascending date order and stops once it has
    # `limit` lines — any single stream can contribute at most `limit` to an oldest-N
    # result, so we never read whole day-files past the limit. the per-stream capped
    # lists are then merged and sliced to the global oldest `limit`.
    files_by_key
    |> Enum.map(fn key_files -> read_stream_lines(key_files, since, until, grep, opts, limit) end)
    |> Enum.concat()
    |> Enum.sort_by(fn line -> line.timestamp end, :asc)
    |> Enum.take(limit)
    # reprocess the lines so their timestamps are DateTime instead of ints
    |> Enum.map(fn line ->
      %LogLine{
        key0: line.key0,
        key1: line.key1,
        timestamp: DateTime.from_unix!(line.timestamp, :millisecond),
        text: line.text
      }
    end)
    |> then(fn v -> {:ok, v} end)
  end

  # read a single stream's day-files in ascending date order, stopping early once we've
  # accumulated `limit` lines (further/older files can't contribute to the oldest N).
  defp read_stream_lines({k0k1, files}, since, until, grep, opts, limit) do
    files
    |> Enum.reduce_while([], fn file, acc ->
      {:ok, lines} = read_log_lines(k0k1, file, since, until, grep, opts)
      acc = acc ++ lines

      if length(acc) >= limit do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
    |> Enum.take(limit)
  end

  defp parse_line_v1(key0, key1, line) do
    # <version>\t<timestamp>\t<log text> — parts: 3 keeps any tabs embedded in the text
    # in the third field without a slice/join round-trip.
    case String.split(line, "\t", parts: 3) do
      [_version, line_timestamp_unix_str, logline] ->
        line_timestamp_unix =
          case Integer.parse(line_timestamp_unix_str) do
            {num, ""} when is_integer(num) ->
              num

            _ ->
              raise "invalid line timestamp: #{line_timestamp_unix_str}, k0k1: #{key0}.#{key1} line is #{line}"
          end

        %LogLine{
          key0: key0,
          key1: key1,
          timestamp: line_timestamp_unix,
          text: logline
        }

      _ ->
        raise "invalid log line (expected version\\ttimestamp\\ttext): #{inspect(line)}, k0k1: #{key0}.#{key1}"
    end
  end

  defp read_log_lines({key0, key1}, {_, file_path}, since, until, grep, opts) do
    Logger.debug("querying file #{file_path} with opts #{inspect(opts)}")

    forced_features = opts |> Keyword.get(:forced_features, [])
    forced_index_ts_v1? = Enum.any?(forced_features, fn f -> f == :index_ts_v1 end)

    unwanted_features = opts |> Keyword.get(:unwanted_features, [])
    unwanted_index_ts_v1? = Enum.any?(unwanted_features, fn f -> f == :index_ts_v1 end)

    path_datetime = datetime_from_path(file_path)
    index_path = Fog.IndexStore.path_for(key0, key1, path_datetime)
    has_index_ts_v1? = File.exists?(index_path)

    contains_since? = path_datetime |> DateTime.to_date() == since |> DateTime.to_date()
    contains_until? = path_datetime |> DateTime.to_date() == until |> DateTime.to_date()
    # index_ts_v1 works by letting us map a timestamp to a seek offset
    # this works on singular file speedups, but won't really work if you want us to process 3GB of data
    # other optimizations (like line streaming) may work out best for us here
    could_use_index_ts_v1? = contains_since? || contains_until?

    if could_use_index_ts_v1? and not has_index_ts_v1? and forced_index_ts_v1? do
      raise "no index found for #{file_path} even though index_ts_v1 is a required query feature"
    end

    {start_offset, end_offset} =
      if could_use_index_ts_v1? and has_index_ts_v1? and not unwanted_index_ts_v1? do
        default_start_offset = 0

        default_end_offset =
          File.stat!(file_path) |> Map.get(:size)

        start_offset =
          if contains_since? do
            Logger.debug("using index_ts_v1 index for since")
            {:ok, start_offset} = Fog.IndexStore.read_at(key0, key1, since, accept_before?: true)

            if start_offset == -1 do
              default_start_offset
            else
              start_offset
            end
          else
            default_start_offset
          end

        end_offset =
          if contains_until? do
            Logger.debug("using index_ts_v1 index for until")

            {:ok, end_offset} =
              Fog.IndexStore.read_at(
                key0,
                key1,
                # if until is say, 00:00:30.5 we want to stop reading at the 00:00:31 mark instead of 00:00:30
                # (we'll filter either way so extra seconds just imply more bytes, rather than actually incorrect data)
                until
                |> DateTime.add(1, :second),
                accept_after?: true
              )

            if end_offset == -1 do
              default_end_offset
            else
              end_offset
            end
          else
            default_end_offset
          end

        {start_offset, end_offset}
      else
        # by default, read everything from the file
        Logger.debug("not using index_ts_v1 index for this path")
        {0, File.stat!(file_path) |> Map.get(:size)}
      end

    amount = end_offset - start_offset

    # convert to unix ts for fast lookup in the file
    since = since |> DateTime.to_unix(:millisecond)
    until = until |> DateTime.to_unix(:millisecond)

    Logger.debug(
      "getting #{amount} bytes from offset #{start_offset} (#{since / 1000}..#{until / 1000}) on #{file_path}"
    )

    # a :raw handle + a single pread of the index-bounded byte range is far cheaper than
    # line-by-line IO.read through the IO server. offsets are line-aligned (index seeks
    # point at a second's first line; defaults are 0 and the file size), so the range is
    # a whole number of lines and :binary.split leaves only a trailing "" to drop.
    {:ok, file} = File.open(file_path, [:read, :raw, :binary])

    lines =
      if amount <= 0 do
        []
      else
        case :file.pread(file, start_offset, amount) do
          {:ok, data} -> :binary.split(data, "\n", [:global])
          :eof -> []
        end
      end

    :ok = :file.close(file)

    result =
      lines
      |> Enum.reduce([], fn line, acc ->
        cond do
          line == "" ->
            acc

          grep != nil and not String.contains?(line, grep) ->
            acc

          # storage format v1
          String.starts_with?(line, "1") ->
            l = parse_line_v1(key0, key1, line)

            if l.timestamp >= since and l.timestamp < until do
              [l | acc]
            else
              acc
            end

          true ->
            Logger.warning("invalid log line: '#{line}'")
            acc
        end
      end)
      |> Enum.reverse()

    Logger.debug(
      "filtered to #{length(result)} loglines from (#{key0}/#{key1}), since=#{inspect(since)}"
    )

    {:ok, result}
  end

  def datetime_from_path(path) do
    path
    |> Path.basename()
    |> String.split(".")
    |> Enum.at(0)
    |> String.split("-")
    |> then(fn [year, month, day] ->
      {year, _} = Integer.parse(year)
      {month, _} = Integer.parse(month)
      {day, _} = Integer.parse(day)
      fake_dt = DateTime.new!(Date.new!(year, month, day), ~T[00:00:00], "Etc/UTC")
      fake_dt
    end)
  end

  @spec build_index_ts_v1(any, any, DateTime.t()) :: :ok | {:error, term()}
  def build_index_ts_v1(key0, key1, datetime) do
    Logger.debug("building index_ts_v1 for #{key0}/#{key1} at #{inspect(datetime)}")
    path = file_for(:writing, key0, key1, datetime)

    initial_datetime =
      path
      |> datetime_from_path

    case File.open(path, [:read]) do
      {:error, :enoent} ->
        # we need to generate a seek array that is [-1, -1, -1...] on this case
        Logger.debug("building index out of empty log file")
        really_build_index_ts_v1(key0, key1, initial_datetime, [])

      {:ok, file} ->
        stream =
          Stream.unfold({:file.position(file, :cur), file}, fn
            {pos, file} ->
              case IO.gets(file, "") do
                :eof -> nil
                line -> {{pos, line}, {:file.position(file, :cur), file}}
              end
          end)
          |> Stream.map(fn {seek, line} ->
            cond do
              # storage format v1
              String.starts_with?(line, "1") ->
                {seek, parse_line_v1(key0, key1, line)}
            end
          end)

        really_build_index_ts_v1(key0, key1, initial_datetime, stream)
    end
  end

  defp really_build_index_ts_v1(key0, key1, initial_datetime, stream) do
    # build index by going through every line

    stream
    |> Enum.reduce(%{}, fn {{:ok, seek}, %LogLine{} = line}, acc ->
      # TODO(optimization): dont need to parse all lines, can just get the first line
      # and then compute offsets (a subtraction)

      # index file works by batching log lines into per-second intervals
      # that means a day contains 86400 index entries, always
      line_dt = DateTime.from_unix!(line.timestamp, :millisecond)
      seconds_after_midnight = Fog.IndexStore.second_of_day(line_dt)

      if seconds_after_midnight > 86400 do
        raise "Fog.IndexStore: line #{line.timestamp} is not in the right format (#{inspect(seconds_after_midnight)} is over 86400, shouldnt be)"
      end

      case acc |> Map.get(seconds_after_midnight) do
        nil ->
          # no entry, use this as entry
          acc |> Map.put(seconds_after_midnight, {line_dt, seek})

        _ ->
          # has entry, dont use current log line as entry
          acc
      end
    end)
    |> Enum.map(fn {seconds_after_midnight, {line_dt, seek_position}} ->
      # convert to DateTime so that IndexStore can validate we're giving good data
      {line_dt
       |> DateTime.to_date()
       |> DateTime.new!(Time.from_seconds_after_midnight(seconds_after_midnight)), seek_position}
    end)
    |> Map.new()
    # index_ts_v1 relies on 86400 entries, but log files may not have all the timestamps.
    # hydrate to 86400
    |> then(fn offset_map ->
      Logger.debug(
        "index_ts_v1: #{key0}/#{key1} has #{Enum.count(offset_map)} initial seek entries"
      )

      1..86400
      |> Enum.map(fn seconds_from_midnight ->
        wanted_dt =
          initial_datetime
          |> DateTime.add(seconds_from_midnight, :second)

        stored_seek = offset_map |> Map.get(wanted_dt)
        # we have to default to -1 and then let query execution decide how to deal with the file.
        # we can't just use the last datetime because if, say, both `since` and `until` are unindexed,
        # they'd go to the same seek and would provide an empty read
        {wanted_dt, stored_seek || -1}
      end)
      |> Map.new()
    end)
    |> then(fn offset_map ->
      Logger.debug(
        "index_ts_v1: #{key0}/#{key1} normalized to #{Enum.count(offset_map)} seek entries"
      )

      # we can write all of this to the index file now!
      Fog.IndexStore.write(
        key0,
        key1,
        initial_datetime,
        offset_map |> Fog.IndexStore.Data.from_offset_map!()
      )
    end)
  end
end
