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

  defp folder_for(key0, key1) do
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

  def query(params) do
    all = all_keys()

    wanted_keys =
      all
      |> Enum.filter(fn k0k1 ->
        matches_selectors?(k0k1, params["selectors"])
      end)

    Logger.info("query: #{inspect(wanted_keys)}")

    limit = params["limit"] || raise "missing limit. this is a bug"
    {limit, ""} = Integer.parse(limit)

    # for each key, find the initial file based on the since parameter
    since_default = DateTime.utc_now() |> DateTime.add(-30, :second)
    {:ok, since} = (params["since"] || DateTime.to_iso8601(since_default)) |> parse_datetime

    # for each key, find the last file based on until
    until_default = DateTime.utc_now() |> DateTime.add(1, :second)
    {:ok, until} = (params["until"] || DateTime.to_iso8601(until_default)) |> parse_datetime

    initial_files =
      wanted_keys
      |> Enum.map(fn {key0, key1} = d ->
        maybe_path = file_for(:reading, key0, key1, {since, until})
        {since, until, d, maybe_path}
      end)
      |> Enum.filter(fn {_, _, _, maybe_path} -> maybe_path != nil end)
      |> Enum.sort_by(fn {_, _, _, {%DateTime{} = dt, _}} -> dt end, :asc)

    # convert to unix ts for fast lookup in the file
    since = since |> DateTime.to_unix(:millisecond)
    until = until |> DateTime.to_unix(:millisecond)

    Logger.debug("querying #{inspect(params)}, got #{length(initial_files)} files to read")
    Logger.debug("since: #{since}, until: #{until}")
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    Logger.debug("since is #{now - since}msec ago")
    Logger.debug("until is #{now - until}msec ago")

    if since > until do
      raise "since must be before until. this is a bug. since: #{since}, until: #{until}"
    end

    initial_files
    |> Enum.flat_map(fn {_, _, descriptor, file_path} ->
      {:ok, lines} = read_log_lines(descriptor, file_path, since, until, params["grep"])
      lines
    end)
    |> Enum.sort_by(fn line -> line.timestamp end, :asc)
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

  defp read_log_lines({key0, key1}, {_, file_path}, since, until, grep) do
    Logger.debug("querying file #{file_path}")

    with {:ok, data} <- File.read(file_path) do
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

          true ->
            Logger.warning("invalid log line: '#{line}'")
            nil
        end
      end)
      |> Enum.filter(fn
        nil ->
          false

        %LogLine{} = l ->
          Logger.debug(
            "line since #{l.timestamp} >= #{inspect(since)} = #{inspect(l.timestamp >= since)}"
          )

          Logger.debug(
            "line until #{l.timestamp} <= #{inspect(until)} = #{inspect(l.timestamp <= until)}"
          )

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
end
