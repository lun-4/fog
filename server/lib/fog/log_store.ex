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

  def folder_for(key0, key1) do
    path = Path.join([data_path(), key0, key1])
    File.mkdir_p!(path)
    path
  end

  defp file_for(:writing, key0, key1, timestamp) do
    Path.join([
      folder_for(key0, key1),
      "#{timestamp.year}-#{timestamp.month}-#{timestamp.day}.log"
    ])
  end

  defp file_for(:reading, key0, key1, {initial_timestamp, final_timestamp}) do
    possible_path =
      file_for(:writing, key0, key1, initial_timestamp)

    if File.exists?(possible_path) do
      {initial_timestamp, possible_path}
    else
      # move forward by a day, unless we hit final_timestamp
      next_timestamp = initial_timestamp |> DateTime.add(1, :day)

      Logger.warning("#{key0}/#{key1} has no file for given timestamp #{initial_timestamp}")

      cond do
        # blew past final timestamp
        # next_timestamp may be on the same day as final_timestamp, but at a different hour that is :gt.
        # to prevent this, compared with +1d of final_timestamp, should do the trick
        DateTime.compare(next_timestamp, final_timestamp |> DateTime.add(1, :day)) == :gt ->
          Logger.debug(
            "next_timestamp (#{inspect(next_timestamp)}) is after #{inspect(final_timestamp)}, stopping"
          )

          nil

        true ->
          Logger.debug("NEXT")
          file_for(:reading, key0, key1, {next_timestamp, final_timestamp})
      end
    end
  end

  def store(key0, key1, line, timestamp \\ nil) do
    now =
      if timestamp == nil do
        DateTime.utc_now()
      else
        DateTime.from_unix!(timestamp, :millisecond)
      end

    log_path = file_for(:writing, key0, key1, now)

    # TODO (optimization): we can hold file descriptors at runtime instead of open/close all the time
    {:ok, file} = File.open(log_path, [:append])
    timestamp = now |> DateTime.to_unix(:millisecond)
    # <version>\t<timestamp>\t<log itself>
    IO.write(file, "1\t#{timestamp}\t#{line}\n")
    File.close(file)
    Logger.debug("Logged line #{line} at timestamp #{inspect(now)} to file @ #{log_path}.")

    Fog.LogStore.Realtime.process_log(%LogLine{
      key0: key0,
      key1: key1,
      timestamp: now,
      text: line
    })
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
        [wanted_key0, "*"] ->
          wanted_key0 == key0

        ["*", wanted_key1] ->
          wanted_key1 == key1

        ["*", "*"] ->
          true

        [wanted_key0, wanted_key1] ->
          wanted_key0 == key0 and wanted_key1 == key1

        _ ->
          raise "selector has invalid format: #{inspect(selector)}"
      end
    end)
    |> Enum.any?()
  end

  defp get_files_for(params) do
    all = all_keys()

    wanted_keys =
      all
      |> Enum.filter(fn k0k1 ->
        matches_selectors?(k0k1, params["selectors"])
      end)

    # for each key, find the initial file based on the since parameter
    since_default = DateTime.utc_now() |> DateTime.add(-30, :second)
    {:ok, since} = (params["since"] || DateTime.to_iso8601(since_default)) |> parse_datetime

    # for each key, find the last file based on until
    until_default = DateTime.utc_now() |> DateTime.add(1, :second)
    {:ok, until} = (params["until"] || DateTime.to_iso8601(until_default)) |> parse_datetime

    files =
      wanted_keys
      |> Enum.map(fn {key0, key1} = d ->
        maybe_path = file_for(:reading, key0, key1, {since, until})
        {since, until, d, maybe_path}
      end)
      |> Enum.filter(fn {_, _, _, maybe_path} -> maybe_path != nil end)
      |> Enum.sort_by(fn {_, _, _, {%DateTime{} = dt, _}} -> dt end, :asc)

    {files, since, until}
  end

  def query(params, opts \\ []) do
    Logger.info("query: #{inspect(params)}")

    limit = params["limit"] || raise "missing limit. this is a bug"
    {limit, ""} = Integer.parse(limit)

    {initial_files, since, until} = get_files_for(params)

    Logger.debug("querying #{inspect(params)}, got #{length(initial_files)} files to read")
    Logger.debug("since: #{since}, until: #{until}")
    now = DateTime.utc_now()

    Logger.debug("since is #{DateTime.diff(now, since, :millisecond)}msec ago")
    Logger.debug("until is #{DateTime.diff(now, until, :millisecond)}msec ago")

    if DateTime.compare(since, until) == :gt do
      raise "since must be before until. this is a bug. since: #{inspect(since)}, until: #{inspect(until)}. #{inspect(DateTime.compare(since, until))}"
    end

    initial_files
    |> Enum.flat_map(fn {_, _, k0k1, file_path} ->
      {:ok, lines} = read_log_lines(k0k1, file_path, since, until, params["grep"], opts)
      lines
    end)
    # TODO (optimization): we do not need to sort if there's only one full selector (k0.k1, rather than k0.* or *.k1)
    # TODO (optimization): on the full selector case, sort filepaths by date rather than by k0k1 (then quit this second sort lol)
    |> Enum.sort_by(fn line -> line.timestamp end, :asc)
    # TODO (optimization): once amount of lines hits limit, we can stop reading
    |> Enum.slice(0..(limit - 1))
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

  defp parse_line_v1(key0, key1, line) do
    parsed = String.split(line, "\t")

    if length(parsed) < 3 do
      Logger.warning("invalid log line: #{line}")
    end

    line_timestamp_unix_str = parsed |> Enum.at(1)
    {line_timestamp_unix, ""} = Integer.parse(line_timestamp_unix_str)
    logline = parsed |> Enum.slice(2..-1) |> Enum.join("\t")

    %LogLine{
      key0: key0,
      key1: key1,
      timestamp: line_timestamp_unix,
      text: logline
    }
  end

  defp read_log_lines({key0, key1}, {_, file_path}, since, until, grep, opts) do
    Logger.debug("querying file #{file_path} with opts #{inspect(opts)}")

    verbose_debug? = opts |> Keyword.get(:verbose_debug, false)
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
        start_offset =
          if contains_since? do
            Logger.debug("using index_ts_v1 index for since")
            {:ok, start_offset} = Fog.IndexStore.read_at(key0, key1, since)
            start_offset
          else
            0
          end

        end_offset =
          if contains_until? do
            Logger.debug("using index_ts_v1 index for until")
            {:ok, end_offset} = Fog.IndexStore.read_at(key0, key1, until)
            end_offset
          else
            File.stat!(file_path) |> Map.get(:size)
          end

        {start_offset, end_offset}
      else
        # by default, read everything from the file
        Logger.debug("not using index_ts_v1 index for this path")
        {0, File.stat!(file_path) |> Map.get(:size)}
      end

    # TODO (optimization): should close file lol
    {:ok, file} = File.open(file_path, [:read])
    {:ok, _} = :file.position(file, start_offset)
    amount = end_offset - start_offset

    # convert to unix ts for fast lookup in the file
    since = since |> DateTime.to_unix(:millisecond)
    until = until |> DateTime.to_unix(:millisecond)

    Logger.debug("start offset #{start_offset}, end offset #{end_offset}")
    Logger.debug("getting #{amount} lines from #{since} to #{until} on #{file_path}")

    # TODO (optimization): use Stream instead of reading entire file into memory
    with {:ok, data} <- :file.read(file, amount) do
      data
      |> String.split("\n")
      |> then(fn
        [] ->
          Logger.warning("no logs found, since=#{since} until=#{inspect(until)}")

        v ->
          Logger.debug("got #{length(v)} lines, since=#{inspect(since)} until=#{inspect(until)}")
          v
      end)
      |> Enum.map(fn line ->
        cond do
          line == "" ->
            Logger.warning("empty line in #{inspect(file_path)}")
            nil

          grep != nil and not String.contains?(line, grep) ->
            nil

          # storage format v1
          String.starts_with?(line, "1") ->
            parse_line_v1(key0, key1, line)

          true ->
            Logger.warning("invalid log line: '#{line}'")
            nil
        end
      end)
      |> Enum.filter(fn
        nil ->
          false

        %LogLine{} = l ->
          if verbose_debug? do
            Logger.debug(
              "line since #{l.timestamp} >= #{inspect(since)} = #{inspect(l.timestamp >= since)}"
            )

            Logger.debug(
              "line until #{l.timestamp} <= #{inspect(until)} = #{inspect(l.timestamp <= until)}"
            )
          end

          l.timestamp >= since and l.timestamp <= until
      end)
    end
    |> then(fn
      {:error, _} = v ->
        v

      v ->
        Logger.debug(
          "filtered to #{length(v)} loglines from (#{key0}/#{key1}), since=#{inspect(since)}"
        )

        {:ok, v}
    end)
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

    # TODO (optimization): should close file lol
    {:ok, file} = File.open(path, [:read])

    # build index by going through every line

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
        # TODO should probably use the last dt's index until non-zero.. maybe?
        {wanted_dt, stored_seek || 0}
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
