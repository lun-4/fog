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
        {%{midnight | second: seconds}, 0}
      end)
      |> Enum.into(%{})

    assert Enum.count(seeks) == 86400

    :ok =
      Fog.IndexStore.write(key0, key1, datetime, seeks |> Fog.IndexStore.Data.from_offset_map!())

    {:ok, data} = Fog.IndexStore.read(key0, key1, datetime)
    assert data != nil
  end
end
