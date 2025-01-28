defmodule Fog.IndexV1Test do
  require Logger
  use ExUnit.Case, async: true

  defp random_string do
    :crypto.strong_rand_bytes(20)
    |> Base.hex_encode32(case: :lower)
    |> binary_part(0, 20)
  end

  setup do
    data_path = "/tmp/fog-test-#{random_string()}"
    Logger.info("Test data path is #{data_path}")
    :ok = Application.put_env(:fog, Fog.LogStore, data_path: data_path)
    key0 = "test_host#{random_string()}"
    key1 = "test_service#{random_string()}"

    Fog.LogStore.tmp_path()
    |> File.mkdir_p!()

    {:ok,
     %{
       key0: key0,
       key1: key1
     }}
  end

  test "can write and read to index files", %{key0: key0, key1: key1} do
    datetime = DateTime.utc_now()
    midnight = %{datetime | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

    seeks =
      1..86400
      |> Enum.map(fn seconds ->
        rand_offset = :rand.uniform(10000)
        {%{midnight | second: seconds}, rand_offset}
      end)
      |> Enum.into(%{})

    assert Enum.count(seeks) == 86400

    :ok =
      Fog.IndexStore.write(key0, key1, datetime, seeks |> Fog.IndexStore.Data.from_offset_map!())

    {:ok, data} = Fog.IndexStore.read(key0, key1, datetime)
    assert data != nil

    {wanted_key, query} =
      seeks
      |> Map.keys()
      |> Enum.random()
      |> then(fn dt ->
        {dt, %{dt | microsecond: {356, 0}}}
      end)

    wanted_seek = seeks |> Map.get(wanted_key)
    wanted_second = Fog.IndexStore.second_of_day(wanted_key)

    seek_from_list = data.seeks |> Enum.at(wanted_second)
    assert seek_from_list != wanted_seek

    {:ok, seek_from_constant} = Fog.IndexStore.read_at(key0, key1, query)
    assert seek_from_constant == wanted_seek
  end

  test "missing seek values still work on read_at", %{key0: key0, key1: key1} do
    datetime = DateTime.utc_now()
    midnight = %{datetime | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

    base_index = 1000

    seeks =
      1..86400
      |> Enum.map(fn seconds ->
        rand_offset = :rand.uniform(10000)
        {midnight |> DateTime.add(seconds, :second), rand_offset}
      end)
      |> Enum.into(%{})
      # set a range of indexes to -1
      |> then(fn seeks ->
        1..100
        |> Enum.reduce(seeks, fn idx, seeks ->
          Map.put(seeks, midnight |> DateTime.add(base_index + idx, :second), -1)
        end)
      end)

    assert Enum.count(seeks) == 86400

    :ok =
      Fog.IndexStore.write(key0, key1, datetime, seeks |> Fog.IndexStore.Data.from_offset_map!())

    ts = midnight |> DateTime.add(2, :second)
    original_seek = seeks |> Map.get(ts)
    {:ok, fetched_seek} = Fog.IndexStore.read_at(key0, key1, ts)
    assert fetched_seek == original_seek

    # now seek at one of the missing indexes, should be -1
    ts = midnight |> DateTime.add(base_index + 10, :second)
    original_seek = seeks |> Map.get(ts)
    {:ok, fetched_seek} = Fog.IndexStore.read_at(key0, key1, ts)
    assert fetched_seek == original_seek
    assert fetched_seek == -1

    # backtracking should work
    ts = midnight |> DateTime.add(base_index + 10, :second)
    wanted_ts = midnight |> DateTime.add(base_index, :second)
    original_seek = seeks |> Map.get(wanted_ts)
    assert original_seek != nil
    {:ok, fetched_seek} = Fog.IndexStore.read_at(key0, key1, ts, accept_before?: true)
    assert fetched_seek == original_seek
    assert fetched_seek != -1

    # fast-forwarding should work
    ts = midnight |> DateTime.add(base_index + 50, :second)
    wanted_ts = midnight |> DateTime.add(base_index + 101, :second)
    original_seek = seeks |> Map.get(wanted_ts)
    assert original_seek != nil
    {:ok, fetched_seek} = Fog.IndexStore.read_at(key0, key1, ts, accept_after?: true)
    assert fetched_seek == original_seek
    assert fetched_seek != -1
  end
end
