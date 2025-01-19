defmodule Fog.LogStoreBenchmarkTest do
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

    {:ok,
     %{
       key0_medium: "host#{random_string()}",
       key1_medium: "service#{random_string()}",
       key0_small: "host#{random_string()}",
       key1_small: "service#{random_string()}",
       key0_large: "host#{random_string()}",
       key1_large: "service#{random_string()}"
     }}
  end

  defp write_test_data(key0, key1, amount) do
    base_timestamp =
      DateTime.utc_now()
      |> DateTime.add(-:rand.uniform(100), :day)
      |> DateTime.to_date()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    base_timestamp_unix =
      base_timestamp
      |> DateTime.to_unix(:millisecond)

    1..amount
    |> Enum.each(fn idx ->
      timestamp = base_timestamp_unix + idx * 1000

      Fog.LogStore.store(
        key0,
        key1,
        "Sample log entry #{:rand.uniform(100)} for testing (idx #{idx})",
        timestamp
      )
    end)

    base_timestamp
  end

  @tag :benchmark_writes
  test "benchmark writes with log store", %{
    key0_medium: key0_medium,
    key1_medium: key1_medium,
    key0_small: key0_small,
    key1_small: key1_small,
    key0_large: key0_large,
    key1_large: key1_large
  } do
    # Define the benchmarks
    Benchee.run(
      %{
        "write_small_batch" => fn -> write_test_data(key0_small, key1_small, 100) end,
        "write_medium_batch" => fn -> write_test_data(key0_medium, key1_medium, 1000) end,
        "write_large_batch" => fn -> write_test_data(key0_large, key1_large, 10000) end
        # "query_all_data" => fn ->
        #  nil
        # end
      },
      time: 10,
      memory_time: 2,
      formatters: [
        {Benchee.Formatters.Console, extended_statistics: true},
        {Benchee.Formatters.HTML, file: "benchmark_results.html"}
      ],
      print: [
        fast_warning: false
      ]
    )
  end

  @tag :benchmark
  test "benchmark reads with log store", %{
    key0_small: key0_small,
    key1_small: key1_small
    # key0_medium: key0_medium,
    # key1_medium: key1_medium,
    # key0_large: key0_large,
    # key1_large: key1_large
  } do
    small_timestamp = write_test_data(key0_small, key1_small, 100)
    # medium_timestamp = write_test_data(key0_medium, key1_medium, 1000)
    # large_timestamp = write_test_data(key0_large, key1_large, 10000)
    # Define the benchmarks
    Benchee.run(
      %{
        "read_from_small" => fn ->
          {:ok, _} =
            Fog.LogStore.query(%{
              "selectors" => ["#{key0_small}.#{key1_small}"],
              "since" => small_timestamp |> DateTime.to_iso8601(),
              "limit" => "100"
            })
        end
        # "query_all_data" => fn ->
        #  nil
        # end
      },
      time: 10,
      memory_time: 2,
      formatters: [
        {Benchee.Formatters.Console, extended_statistics: true},
        {Benchee.Formatters.HTML, file: "benchmark_results.html"}
      ],
      print: [
        fast_warning: false
      ]
    )
  end
end
