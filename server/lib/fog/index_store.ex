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

  def path_for(key0, key1, timestamp) do
    Path.join([
      folder_for(key0, key1),
      "#{timestamp.year}-#{timestamp.month}-#{timestamp.day}.bin"
    ])
  end

  alias Fog.IndexStore.Data
  @spec serialize!(Data.t()) :: binary()
  defp serialize!(data) when is_map(data) do
    if length(data.seeks) != @seconds_per_day do
      raise "ERROR: Invalid length of seek position, expected #{@seconds_per_day}, found #{length(data.seeks)}"
    end

    seeks_bin =
      for seek <- data.seeks, into: <<>> do
        <<seek::signed-big-64>>
      end

    checksum = :erlang.crc32(<<seeks_bin::binary>>)
    serialized = <<checksum::signed-big-64, seeks_bin::binary>>

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

  def random_temp_filename(prefix) do
    random_name = :crypto.strong_rand_bytes(8) |> Base.encode16()
    Path.join(System.tmp_dir!(), prefix <> random_name)
  end

  @spec write(String.t(), String.t(), DateTime.t(), Data.t()) :: :ok | {:error, term()}
  def write(key0, key1, timestamp, %Data{} = data) do
    temp_path = random_temp_filename("fog_index")
    path = path_for(key0, key1, timestamp)

    Logger.debug("writing to #{temp_path}, renaming to #{path}")

    with :ok <- File.write(temp_path, data |> serialize!),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      v -> v
    end
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
          for <<seek::signed-big-64 <- seeks_bin>> do
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

  @doc "Read entire deserialized index for the date of the given timestamp"
  @spec read(String.t(), String.t(), DateTime.t()) :: {:ok, Data.t()} | {:error, term()}
  def read(key0, key1, %DateTime{} = timestamp) do
    path = path_for(key0, key1, timestamp)

    with {:ok, raw_data} <- File.read(path) do
      raw_data |> deserialize
    end
  end

  @spec second_of_day(DateTime.t()) :: integer()
  def second_of_day(datetime) do
    datetime.hour * 3600 + datetime.minute * 60 + datetime.second
  end

  @spec read_at(String.t(), String.t(), DateTime.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def read_at(key0, key1, timestamp, opts \\ []) do
    path = path_for(key0, key1, timestamp)
    second = second_of_day(timestamp)

    accept_before? = Keyword.get(opts, :accept_before?, false)
    accept_after? = Keyword.get(opts, :accept_after?, false)

    if accept_before? and accept_after? do
      raise "invalid arguments: accept_before? and accept_after? are mutually exclusive"
    end

    if second == 0 do
      # the index file (and log file in general) already start from 00:00,
      # the first entry in the index is the first second, so we must not read the index entry at all
      # just assume 0 is 0
      {:ok, 0}
    else
      # Calculate the exact position to read from:
      # Skip checksum (8 bytes) + (second * 8 bytes per seek)
      seek_position = @checksum_size + (second - 1) * @seek_size

      with {:ok, file} <- File.open(path, [:read, :raw, :binary]),
           {:ok, <<seek_value::signed-big-64>>} <- :file.pread(file, seek_position, @seek_size),
           :ok <- File.close(file) do
        if seek_value == -1 and (accept_before? or accept_after?) do
          # this second does not have a seek value, but it may be in the range of the last couple seconds

          # for now just read the entire index and walk forwards/backwards
          # to do that we walk through entire array and find the max/min index (if accept_before?/accept_after?)
          # that is either before or after `second` (if accept_before?/accept_after?)

          Logger.debug(
            "read_at falling back to entire-index-read due to missing seek value on #{second} for #{key0}/#{key1}/#{timestamp}"
          )

          case read(key0, key1, timestamp) do
            {:ok, data} ->
              seeks = data.seeks

              seeks
              |> Stream.with_index()
              |> Enum.reduce(
                %{
                  index: nil
                },
                fn {seek_index, _}, acc ->
                  acc_index =
                    cond do
                      acc.index != nil -> acc.index
                      accept_before? -> -1
                      accept_after? -> 9_999_999_999_999_999
                    end

                  {valid_index?, better_index?} =
                    cond do
                      accept_before? ->
                        {seek_index < second, seek_index > acc_index}

                      accept_after? ->
                        {seek_index < second, seek_index < acc_index}

                      true ->
                        raise "invalid state"
                    end

                  if valid_index? and better_index? do
                    Map.put(acc, :index, seek_index)
                  else
                    acc
                  end
                end
              )
              |> then(fn
                %{index: nil} ->
                  {:ok, -1}

                %{index: v} when not is_nil(v) ->
                  seeks
                  |> Enum.at(v)
                  |> then(fn
                    nil ->
                      raise "invalid logic conclusion. should have a seek value if index is not nil"

                    v ->
                      {:ok, v}
                  end)
              end)

            {:error, _} = v ->
              v
          end
        else
          {:ok, seek_value}
        end
      else
        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
