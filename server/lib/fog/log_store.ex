defmodule Fog.LogStore do
  require Logger

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
    timestamp = now |> DateTime.to_unix()
    IO.write(file, "#{timestamp}\t#{line}\n")
    File.close(file)
  end

  defp parse_datetime(input) when is_binary(input) do
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

  defmodule LogLine do
    @derive Jason.Encoder

    defstruct [:timestamp, :text]
  end

  def query(params) do
    # TODO support not having key0 (all logs everywhere)
    # TODO support not having key1 (all key1s in key0)
    key0 = params["key0"] || raise "TODO support no key0"
    key1 = params["key1"] || raise "TODO support no key1"
    limit = params["limit"] || raise "missing limit. this is a bug"

    # TODO support until
    {:ok, since} = params["since"] |> parse_datetime

    file_path = file_for(key0, key1, since)
    {:ok, data} = File.read(file_path)

    since = since |> DateTime.to_unix()

    data
    |> String.split("\n")
    |> Enum.map(fn
      "" ->
        nil

      line ->
        parsed = String.split(line, "\t")

        if length(parsed) < 2 do
          Logger.warning("invalid log line: #{line}")
        end

        line_timestamp_unix_str = parsed |> Enum.at(0)
        {line_timestamp, ""} = Integer.parse(line_timestamp_unix_str)
        logline = parsed |> Enum.slice(1..-1) |> Enum.join("\t")
        %LogLine{timestamp: line_timestamp, text: logline}
    end)
    |> Enum.filter(fn
      nil ->
        false

      %LogLine{} = l ->
        l.timestamp > since
    end)
    |> Enum.slice(0..limit)
  end
end
