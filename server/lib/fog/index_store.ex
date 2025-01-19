defmodule Fog.IndexStore do
  require Logger

  @moduledoc """
  Handles reading and writing of index files that map timestamps to seek positions.

  Index file format:
  - 8 byte checksum at start
  - 86400 seek positions (8 bytes each, one per second in day)
  - Total file size: 691,208 bytes
  """

  # Constants
  @seconds_per_day 86_400
  # bytes
  @seek_size 8
  # bytes
  @checksum_size 8
  @total_file_size @checksum_size + @seconds_per_day * @seek_size

  defp folder_for(key0, key1) do
    path = Path.join([Fog.LogStore.data_path(), "_fog_internal", "index_ts_v1", key0, key1])
    File.mkdir_p!(path)
    path
  end

  defp path_for(key0, key1, timestamp) do
    Path.join([
      folder_for(key0, key1),
      "#{timestamp.year}-#{timestamp.month}-#{timestamp.day}.bin"
    ])
  end

  alias Fog.IndexStore.Data
  @spec serialize!(Data.t()) :: binary()
  defp serialize!(data) when is_map(data) do
    if length(data.seeks) != @seconds_per_day do
      raise "ERROR: Invalid seek length, expected #{@seconds_per_day}, found #{length(data.seeks)}"
    end

    seeks_bin =
      for seek <- data.seeks, into: <<>> do
        <<seek::unsigned-big-64>>
      end

    checksum = :erlang.crc32(<<seeks_bin::binary>>)
    serialized = <<checksum::unsigned-big-64, seeks_bin::binary>>

    if byte_size(serialized) != @total_file_size do
      raise "data size: #{length(serialized)} bytes, expected #{@total_file_size} bytes"
    end

    serialized
  end

  defmodule Data do
    @type t :: %__MODULE__{}
    defstruct([:seeks])

    @spec from_offset_map!(map()) :: t()
    def from_offset_map!(seek_offsets) do
      seek_offsets
      |> Map.keys()
      |> Enum.sort(:asc)
      |> Enum.map(fn k ->
        {m, _} = k.microsecond

        v = seek_offsets |> Map.get(k)

        if m > 0 do
          raise "bad seek offset: #{inspect(k)}, #{inspect(v)}"
        end

        v
      end)
      |> then(fn seeks ->
        %__MODULE__{seeks: seeks}
      end)
    end
  end

  @spec write(String.t(), String.t(), DateTime.t(), Data.t()) :: :ok | {:error, term()}
  def write(key0, key1, timestamp, %Data{} = data) do
    path = path_for(key0, key1, timestamp)
    File.write(path, data |> serialize!)
  end

  @spec deserialize(binary()) :: {:ok, Data.t()} | {:error, term()}
  defp deserialize(binary) when is_binary(binary) do
    if byte_size(binary) != @total_file_size do
      Logger.warning(
        "Invalid binary size: #{byte_size(binary)} bytes, expected #{@total_file_size} bytes"
      )

      {:error, :bad_data}
    else
      <<stored_checksum::unsigned-big-64, seeks_bin::binary>> = binary
      calculated_checksum = :erlang.crc32(seeks_bin)

      if stored_checksum != calculated_checksum do
        Logger.warning("Checksum mismatch: #{stored_checksum} != #{calculated_checksum}")
        {:error, :checksum_mismatch}
      else
        seeks =
          for <<seek::unsigned-big-64 <- seeks_bin>> do
            seek
          end

        if length(seeks) != @seconds_per_day do
          Logger.warning(
            "Invalid number of seeks: #{length(seeks)}, expected #{@seconds_per_day}"
          )

          {:error, :bad_seek_length}
        else
          {:ok, %Data{seeks: seeks}}
        end
      end
    end
  end

  @spec read(String.t(), String.t(), DateTime.t()) :: {:ok, Data.t()} | {:error, term()}
  def read(key0, key1, timestamp) do
    path = path_for(key0, key1, timestamp)

    with {:ok, raw_data} <- File.read(path) do
      raw_data |> deserialize
    end
  end

  @spec second_of_day(DateTime.t()) :: integer()
  def second_of_day(datetime) do
    datetime.hour * 3600 + datetime.minute * 60 + datetime.second
  end

  @spec read_at(String.t(), String.t(), DateTime.t()) :: {:ok, integer()} | {:error, term()}
  def read_at(key0, key1, timestamp) do
    path = path_for(key0, key1, timestamp)
    second = second_of_day(timestamp)

    # Calculate the exact position to read from:
    # Skip checksum (8 bytes) + (second * 8 bytes per seek)
    seek_position = @checksum_size + (second - 1) * @seek_size

    with {:ok, file} <- File.open(path, [:read, :raw, :binary]),
         {:ok, <<seek_value::unsigned-big-64>>} <- :file.pread(file, seek_position, @seek_size),
         :ok <- File.close(file) do
      {:ok, seek_value}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end
end
