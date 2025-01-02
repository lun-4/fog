defmodule Fog.LogStore do
  require Logger

  defmodule LogLine do
    @derive Jason.Encoder

    defstruct [:key0, :key1, :timestamp, :text]
  end

  defp folder_for(key0, key1) do
    cfg = Application.fetch_env!(:fog, Fog.LogStore)
    data_path = Path.expand(cfg[:data_path])
    path = Path.join([data_path, key0, key1])
    File.mkdir_p!(path)
    path
  end

  defp file_for(key0, key1, timestamp) do
    Path.join([
      folder_for(key0, key1),
      "#{timestamp.year}-#{timestamp.month}-#{timestamp.day}.log"
    ])
  end

  def store(key0, key1, line) do
    now = DateTime.utc_now()
    log_path = file_for(key0, key1, now)
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

  def query(params) do
    # TODO support not having key0 (all logs everywhere)
    # TODO support not having key1 (all key1s in key0)
    key0 = params["key0"] || raise "TODO support no key0"
    key1 = params["key1"] || raise "TODO support no key1"
    limit = params["limit"] || raise "missing limit. this is a bug"
    {limit, ""} = Integer.parse(limit)

    # TODO support until
    # TODO support multiple files (e.g since = nil, means all file under key0/key1)
    now = DateTime.utc_now() |> DateTime.add(-30, :second)
    {:ok, since} = (params["since"] || DateTime.to_iso8601(now)) |> parse_datetime

    file_path = file_for(key0, key1, since)
    since = since |> DateTime.to_unix(:millisecond)

    with {:ok, data} <- File.read(file_path) do
      data
      |> String.split("\n")
      |> then(fn
        [] ->
          Logger.warning("no logs found, since=#{since} now=#{now}")

        v ->
          Logger.debug("got #{length(v)} lines, params=#{inspect(params)}")
          v
      end)
      |> Enum.map(fn line ->
        cond do
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
            nil
        end
      end)
      |> Enum.filter(fn
        nil ->
          false

        %LogLine{} = l ->
          l.timestamp > since
      end)
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
  end
end
