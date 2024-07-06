defmodule FogWeb.LogTest do
  use FogWeb.ConnCase, async: false
  @words ["dog", "cat", "canary", "subsolar", "nursemaid", "deity", "ferroeletric"]
  defp random_logline(),
    do:
      1..3
      |> Enum.map(fn _ ->
        @words
        |> Enum.random()
      end)
      |> Enum.join(" ")

  setup do
    logs =
      1..100
      |> Enum.map(fn n ->
        Fog.Log.insert!(n, random_logline())
      end)

    %{logs: logs}
  end

  test "it can fetch logs between timestamps", %{logs: logs, conn: conn} do
    first = logs |> Enum.at(0)
    last = logs |> Enum.at(-1)

    resp =
      get(conn, "/api/v1/logs", %{
        "start" => first.timestamp,
        "end" => last.timestamp
      })
      |> json_response(200)

    assert resp["logs"] |> Enum.count() == 100
    assert resp["logs"] |> Enum.at(0) |> Map.get("timestamp") == first.timestamp
  end

  test "remote grep works", %{logs: logs, conn: conn} do
    first = logs |> Enum.at(0)
    last = logs |> Enum.at(-1)
    wanted_word = @words |> Enum.random()

    resp =
      get(conn, "/api/v1/logs", %{
        "start" => first.timestamp,
        "end" => last.timestamp,
        "filter_grep_exact" => wanted_word
      })
      |> json_response(200)

    assert resp["logs"] |> Enum.count() > 0

    resp["logs"]
    |> Enum.each(fn log ->
      entry = log |> Map.get("entry")
      assert String.contains?(entry, wanted_word)
    end)
  end
end
