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

  defp write_test_data(key0, key1, amount, base_timestamp \\ nil) do
    base_timestamp =
      if base_timestamp != nil do
        base_timestamp
      else
        DateTime.utc_now()
        |> DateTime.add(-:rand.uniform(100), :day)
        |> DateTime.to_date()
        |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      end

    base_timestamp_unix =
      base_timestamp
      |> DateTime.to_unix(:millisecond)

    logs =
      1..amount
      |> Enum.map(fn idx ->
        timestamp = base_timestamp_unix + idx * 1000

        text = "Sample log entry #{:rand.uniform(100)} for testing (idx #{idx})"

        :ok =
          Fog.LogStore.store(
            key0,
            key1,
            text,
            timestamp
          )

        %{timestamp: timestamp, text: text}
      end)

    {base_timestamp, logs}
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

  test "index building works", %{
    key0_large: key0_large,
    key1_large: key1_large
  } do
    {large_timestamps, large_timestamp_min, large_timestamp_max} =
      [
        write_test_data(key0_large, key1_large, 10000),
        write_test_data(key0_large, key1_large, 10000),
        write_test_data(key0_large, key1_large, 10000),
        write_test_data(key0_large, key1_large, 10000),
        write_test_data(key0_large, key1_large, 10000)
      ]
      |> Stream.map(fn {t, _} -> t end)
      |> Enum.sort(DateTime)
      |> then(fn tstamps ->
        {
          tstamps,
          tstamps |> Enum.at(0),
          tstamps |> Enum.at(-1)
        }
      end)

    large_timestamps
    |> Enum.each(fn timestamp ->
      :ok = Fog.LogStore.build_index_ts_v1(key0_large, key1_large, timestamp)
    end)

    {:ok, _} =
      Fog.LogStore.query(
        %{
          "selectors" => ["#{key0_large}.#{key1_large}"],
          "since" => large_timestamp_min |> DateTime.to_iso8601(),
          "until" => large_timestamp_max |> DateTime.to_iso8601(),
          "limit" => "100000"
        },
        forced_features: [
          :index_ts_v1
        ]
      )
  end

  @tag :benchmark
  test "benchmark reads with log store", %{
    # key0_small: key0_small,
    # key1_small: key1_small,
    # key0_medium: key0_medium,
    # key1_medium: key1_medium,
    key0_large: key0_large,
    key1_large: key1_large
  } do
    # small_timestamp = write_test_data(key0_small, key1_small, 100)
    # medium_timestamp = write_test_data(key0_medium, key1_medium, 1000)
    {large_timestamps, large_timestamp_min, large_timestamp_max} =
      [
        write_test_data(key0_large, key1_large, 10000),
        write_test_data(key0_large, key1_large, 10000),
        write_test_data(key0_large, key1_large, 10000),
        write_test_data(key0_large, key1_large, 10000),
        write_test_data(key0_large, key1_large, 10000)
      ]
      |> Stream.map(fn {t, _} -> t end)
      |> Enum.sort(DateTime)
      |> then(fn tstamps ->
        {
          tstamps,
          tstamps |> Enum.at(0),
          tstamps |> Enum.at(-1)
        }
      end)

    large_timestamps
    |> Enum.each(fn timestamp ->
      :ok = Fog.LogStore.build_index_ts_v1(key0_large, key1_large, timestamp)
    end)

    # Define the benchmarks
    Benchee.run(
      %{
        # "read_from_small" => fn ->
        #  {:ok, _} =
        #    Fog.LogStore.query(%{
        #      "selectors" => ["#{key0_small}.#{key1_small}"],
        #      "since" => small_timestamp |> DateTime.to_iso8601(),
        #      "limit" => "100"
        #    })
        # end,
        "read_from_large" => fn ->
          {:ok, _} =
            Fog.LogStore.query(
              %{
                "selectors" => ["#{key0_large}.#{key1_large}"],
                "since" => large_timestamp_min |> DateTime.to_iso8601(),
                "until" => large_timestamp_max |> DateTime.to_iso8601(),
                "limit" => "100000"
              },
              disable_features: [
                :index_ts_v1
              ]
            )
        end,
        "read_from_large_with_index" => fn ->
          {:ok, _} =
            Fog.LogStore.query(
              %{
                "selectors" => ["#{key0_large}.#{key1_large}"],
                "since" => large_timestamp_min |> DateTime.to_iso8601(),
                "until" => large_timestamp_max |> DateTime.to_iso8601(),
                "limit" => "100000"
              },
              forced_features: [
                :index_ts_v1
              ]
            )
        end
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

  test "using the index gives correct data", %{
    key0_large: key0_large,
    key1_large: key1_large
  } do
    {timestamp, logs} =
      write_test_data(key0_large, key1_large, 1000)

    :ok = Fog.LogStore.build_index_ts_v1(key0_large, key1_large, timestamp)

    log1 = logs |> Enum.at(30)
    log2 = logs |> Enum.at(100)

    {:ok, returned_logs} =
      Fog.LogStore.query(
        %{
          "selectors" => ["#{key0_large}.#{key1_large}"],
          "since" => log1.timestamp |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
          # include the next second lol
          "until" =>
            (log2.timestamp + 1000) |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
          "limit" => "1000"
        },
        forced_features: [
          :index_ts_v1
        ]
      )

    returned_log1 = returned_logs |> Enum.at(0)
    returned_log2 = returned_logs |> Enum.at(-1)

    assert returned_log1.text == log1.text
    assert returned_log2.text == log2.text

    # test without index

    {:ok, returned_logs} =
      Fog.LogStore.query(
        %{
          "selectors" => ["#{key0_large}.#{key1_large}"],
          "since" => log1.timestamp |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
          # include the next second lol
          "until" =>
            (log2.timestamp + 1000) |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
          "limit" => "1000"
        },
        unwanted_features: [
          :index_ts_v1
        ]
      )

    returned_log1 = returned_logs |> Enum.at(0)
    returned_log2 = returned_logs |> Enum.at(-1)

    assert returned_log1.text == log1.text
    assert returned_log2.text == log2.text
  end

  test "an incomplete index still returns good data", %{
    key0_large: key0_large,
    key1_large: key1_large
  } do
    {timestamp, logs} =
      write_test_data(key0_large, key1_large, 1000)

    # intentionally generate an incomplete index
    incomplete_index_seeks = List.duplicate(-1, 86400)
    index_data = %Fog.IndexStore.Data{seeks: incomplete_index_seeks}
    :ok = Fog.IndexStore.write(key0_large, key1_large, timestamp, index_data)

    log1 = logs |> Enum.at(30)
    log2 = logs |> Enum.at(100)

    {:ok, returned_logs} =
      Fog.LogStore.query(
        %{
          "selectors" => ["#{key0_large}.#{key1_large}"],
          "since" => log1.timestamp |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
          # include the next second lol
          "until" =>
            (log2.timestamp + 1000) |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
          "limit" => "1000"
        },
        forced_features: [
          :index_ts_v1
        ]
      )

    returned_log1 = returned_logs |> Enum.at(0)
    returned_log2 = returned_logs |> Enum.at(-1)

    assert returned_log1.text == log1.text
    assert returned_log2.text == log2.text
  end

  test "log server does not build index unless log file is large enough", %{
    key0_large: key0_large,
    key1_large: key1_large
  } do
    {timestamp, logs} =
      write_test_data(key0_large, key1_large, 1000)

    assert length(logs) == 1000

    {:ok, server} = Fog.LogServer.get_or_start_server(key0_large, key1_large)
    server_state = :sys.get_state(server)
    assert server_state.index_ts_v1 == %{}

    {_timestamp, logs} =
      write_test_data(key0_large, key1_large, 20000, timestamp |> DateTime.add(10, :millisecond))

    assert length(logs) == 20000

    {:ok, returned_logs} =
      Fog.LogStore.query(%{
        "selectors" => ["#{key0_large}.#{key1_large}"],
        "since" => timestamp |> DateTime.to_iso8601(),
        "until" =>
          DateTime.utc_now()
          |> DateTime.to_iso8601(),
        "limit" => "100000"
      })

    assert length(returned_logs) == 21000

    server_state = :sys.get_state(server)
    assert Enum.count(server_state.index_ts_v1) > 0

    {_path, {_k0, _k1, _ts, index_data}} = Enum.at(server_state.index_ts_v1, 0)
    assert length(index_data.seeks) > 0

    missing_seek_count_before =
      index_data.seeks
      |> Enum.filter(fn x -> x == -1 end)
      |> Enum.count()

    hit_seek_count =
      index_data.seeks
      |> Enum.filter(fn x -> x != -1 end)
      |> Enum.count()

    assert hit_seek_count > 100

    # submitting another log on a timestamp in the future should make the log server
    # emit another seek hit
    cool_timestamp =
      logs
      |> Enum.at(-1)
      |> then(fn log ->
        log.timestamp + 1000
      end)

    :ok =
      Fog.LogStore.store(
        key0_large,
        key1_large,
        "hit seek",
        cool_timestamp
      )

    server_state = :sys.get_state(server)
    assert Enum.count(server_state.index_ts_v1) > 0

    {_path, {_k0, _k1, _ts, index_data}} = Enum.at(server_state.index_ts_v1, 0)
    assert length(index_data.seeks) > 0

    missing_seek_count_after =
      index_data.seeks
      |> Enum.filter(fn x -> x == -1 end)
      |> Enum.count()

    assert missing_seek_count_after == missing_seek_count_before - 1
  end
end
