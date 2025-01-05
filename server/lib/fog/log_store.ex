defmodule Fog.LogStore do
  require Logger

  defmodule LogLine do
    @derive Jason.Encoder

    defstruct [:key0, :key1, :timestamp, :text]
  end

  defp data_path do
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

  defp file_for(:reading, key0, key1, timestamp) do
    possible_path =
      file_for(:writing, key0, key1, timestamp)

    if File.exists?(possible_path) do
      possible_path
    else
      # move forward by a day, unless we hit the future
      now = DateTime.utc_now()
      next_timestamp = timestamp |> DateTime.add(1, :day)

      Logger.warning("#{key0}/#{key1} has no file for given timestamp #{timestamp}")

      if DateTime.compare(next_timestamp, now) == :gt do
        nil
      else
        file_for(:reading, key0, key1, next_timestamp)
      end
    end
  end

  def store(key0, key1, line) do
    now = DateTime.utc_now()
    log_path = file_for(:writing, key0, key1, now)
    {:ok, file} = File.open(log_path, [:append])
    timestamp = now |> DateTime.to_unix(:millisecond)
    # <version>\t<timestamp>\t<log itself>
    IO.write(file, "1\t#{timestamp}\t#{line}\n")
    File.close(file)

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

      String.match?(input, ~r/^(\d+)(min|h|d|w)$/) ->
        # Relative time format
        [_, value, unit] = Regex.run(~r/^(\d+)(min|h|d|w)$/, input)
        value = String.to_integer(value)

        seconds =
          case unit do
            "min" -> value * 60
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
    now = DateTime.utc_now() |> DateTime.add(-30, :second)
    {:ok, since} = (params["since"] || DateTime.to_iso8601(now)) |> parse_datetime

    # TODO support until
    initial_files =
      wanted_keys
      |> Enum.map(fn {key0, key1} = d ->
        {since, d, file_for(:reading, key0, key1, since)}
      end)
      |> Enum.filter(fn {_, _, maybe_path} -> maybe_path != nil end)
      |> Enum.sort_by(fn {dt, _, _} -> dt end, :asc)

    # convert to unix ts for fast lookup in the file
    since = since |> DateTime.to_unix(:millisecond)

    initial_files
    |> Enum.flat_map(fn {_, descriptor, file_path} ->
      {:ok, lines} = read_log_lines(descriptor, file_path, since)
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

  defp read_log_lines({key0, key1}, file_path, since) do
    with {:ok, data} <- File.read(file_path) do
      data
      |> String.split("\n")
      |> then(fn
        [] ->
          Logger.warning("no logs found, since=#{since}")

        v ->
          Logger.debug("got #{length(v)} lines, since=#{inspect(since)}")
          v
      end)
      |> Enum.map(fn line ->
        cond do
          # storage format v1
          String.starts_with?(line, "1") ->
            parsed = String.split(line, "\t")

            if length(parsed) < 3 do
              Logger.warning("invalid log line: #{line}")
            end

            # TODO Support grep

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
            nil
        end
      end)
      |> Enum.filter(fn
        nil ->
          false

        %LogLine{} = l ->
          l.timestamp > since
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
