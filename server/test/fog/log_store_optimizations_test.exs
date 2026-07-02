defmodule Fog.LogStoreOptimizationsTest do
  @moduledoc """
  Covers the ingest/query optimizations: direct selector resolution, per-stream
  early termination at `limit`, and the batched `store_batch/3` write path.

  async: false because these assert on selector resolution over the whole data
  directory, which is keyed off the global `Fog.LogStore` app env.
  """
  use ExUnit.Case, async: false
  require Logger

  defp rand, do: :crypto.strong_rand_bytes(10) |> Base.hex_encode32(case: :lower)

  setup do
    data_path = "/tmp/fog-opt-#{rand()}"
    :ok = Application.put_env(:fog, Fog.LogStore, data_path: data_path)
    {:ok, %{day: ~U[2026-03-01 00:00:00Z]}}
  end

  defp write_lines(key0, key1, base_dt, count) do
    base_ms = DateTime.to_unix(base_dt, :millisecond)

    for idx <- 1..count do
      ts = base_ms + idx * 1000
      :ok = Fog.LogStore.store(key0, key1, "line #{idx}", ts)
      ts
    end
  end

  test "fully-qualified selector resolves without walking unrelated streams", %{day: day} do
    k0 = "host#{rand()}"
    write_lines(k0, "wanted", day, 5)
    # unrelated streams that must NOT appear in the result
    write_lines(k0, "other", day, 5)
    write_lines("host#{rand()}", "wanted", day, 5)

    # resolve_selectors should return exactly the one pair for a k0.k1 selector
    assert Fog.LogStore.resolve_selectors(["#{k0}.wanted"]) == [{k0, "wanted"}]

    {:ok, logs} =
      Fog.LogStore.query(%{
        "selectors" => ["#{k0}.wanted"],
        "since" => day |> DateTime.to_iso8601(),
        "until" => day |> DateTime.add(1, :day) |> DateTime.to_iso8601(),
        "limit" => "1000"
      })

    assert length(logs) == 5
    assert Enum.all?(logs, fn l -> l.key0 == k0 and l.key1 == "wanted" end)
  end

  test "wildcard selectors resolve to the right pairs", %{day: day} do
    k0 = "host#{rand()}"
    write_lines(k0, "a", day, 1)
    write_lines(k0, "b", day, 1)

    assert Fog.LogStore.resolve_selectors(["#{k0}.*"]) |> Enum.sort() ==
             [{k0, "a"}, {k0, "b"}]

    assert {k0, "a"} in Fog.LogStore.resolve_selectors(["*.a"])
    # a non-existent stream resolves to nothing rather than raising
    assert Fog.LogStore.resolve_selectors(["#{k0}.nope"]) == []
  end

  test "limit returns the oldest N matching lines", %{day: day} do
    k0 = "host#{rand()}"
    timestamps = write_lines(k0, "svc", day, 50)
    oldest_10 = timestamps |> Enum.take(10)

    {:ok, logs} =
      Fog.LogStore.query(%{
        "selectors" => ["#{k0}.svc"],
        "since" => day |> DateTime.to_iso8601(),
        "until" => day |> DateTime.add(1, :day) |> DateTime.to_iso8601(),
        "limit" => "10"
      })

    assert length(logs) == 10

    returned_ms = Enum.map(logs, fn l -> DateTime.to_unix(l.timestamp, :millisecond) end)
    assert returned_ms == oldest_10
  end

  test "store_batch writes all lines in one round-trip and they query back", %{day: day} do
    k0 = "host#{rand()}"
    base_ms = DateTime.to_unix(day, :millisecond)

    lines =
      for idx <- 1..25 do
        %{"data" => "batched #{idx}", "timestamp" => base_ms + idx * 1000}
      end

    :ok = Fog.LogStore.store_batch(k0, "svc", lines)

    {:ok, logs} =
      Fog.LogStore.query(%{
        "selectors" => ["#{k0}.svc"],
        "since" => day |> DateTime.to_iso8601(),
        "until" => day |> DateTime.add(1, :day) |> DateTime.to_iso8601(),
        "limit" => "1000"
      })

    assert length(logs) == 25
    assert Enum.map(logs, & &1.text) == Enum.map(1..25, fn i -> "batched #{i}" end)
  end

  test "grep filters lines within a batch", %{day: day} do
    k0 = "host#{rand()}"
    base_ms = DateTime.to_unix(day, :millisecond)

    :ok =
      Fog.LogStore.store_batch(k0, "svc", [
        %{"data" => "hello world", "timestamp" => base_ms + 1000},
        %{"data" => "error: boom", "timestamp" => base_ms + 2000},
        %{"data" => "all good", "timestamp" => base_ms + 3000}
      ])

    {:ok, logs} =
      Fog.LogStore.query(%{
        "selectors" => ["#{k0}.svc"],
        "since" => day |> DateTime.to_iso8601(),
        "until" => day |> DateTime.add(1, :day) |> DateTime.to_iso8601(),
        "grep" => "error",
        "limit" => "1000"
      })

    assert Enum.map(logs, & &1.text) == ["error: boom"]
  end
end
