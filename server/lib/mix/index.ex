defmodule Mix.Tasks.Fog.Index do
  require Logger
  use Mix.Task

  @requirements ["app.config"]

  def start_repo do
    [:ecto, :ecto_sql, :exqlite, :db_connection]
    |> Enum.each(fn app -> Application.ensure_all_started(app) end)

    children = [
      Fog.Repo
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Fog.Supervisor
    )
  end

  def run(["ts_v1", key0, key1]) do
    Logger.info("Starting Fog reindex for #{key0}.#{key1}")
    Logger.warning("WARN: this runs reindex for _everything_ in the given k0k1 pair")

    folder = Fog.LogStore.folder_for(key0, key1)

    File.ls!(folder)
    |> Enum.map(fn child_path ->
      path = Path.join([folder, child_path])

      cond do
        File.regular?(path) ->
          timestamp = Fog.LogStore.datetime_from_path(path)
          :ok = Fog.LogStore.build_index_ts_v1(key0, key1, timestamp)

        true ->
          Logger.info("ignoring #{inspect(path)}")
      end
    end)
  end

  def run(["check_ts_v1", key0, key1]) do
    Logger.info("Validating checksums for #{key0} #{key1} (assumes all indices exist)")

    folder = Fog.LogStore.folder_for(key0, key1)

    File.ls!(folder)
    |> Enum.map(fn child_path ->
      path = Path.join([folder, child_path])

      cond do
        File.regular?(path) ->
          timestamp = Fog.LogStore.datetime_from_path(path)
          Logger.info("checking #{path}...")
          {:ok, data} = Fog.IndexStore.read(key0, key1, timestamp)

          stats =
            data.seeks
            |> Enum.reduce(%{hit: 0, nonhit: 0}, fn seek, acc ->
              if seek == -1 do
                %{acc | nonhit: acc.nonhit + 1}
              else
                %{acc | hit: acc.hit + 1}
              end
            end)

          Logger.info(
            "ok! index has #{stats.hit} seek values, #{stats.nonhit} missing seek values"
          )

        true ->
          Logger.info("ignoring #{inspect(path)}")
      end
    end)
  end
end
