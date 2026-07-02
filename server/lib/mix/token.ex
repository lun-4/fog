defmodule Mix.Tasks.Fog.Token do
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

  def run(["create"]) do
    IO.puts("must give description to create a token")
  end

  def run(["create", name]) do
    start_repo()

    {:ok, t} = Fog.Authentication.create_random(name)
    IO.puts("created token #{inspect(t)}")
    IO.puts("token:")
    IO.puts(t.token)
  end

  def run(["list"]) do
    start_repo()

    Fog.Authentication.all_active()
    |> Enum.each(fn t ->
      IO.puts("#{t.id} #{t.description} #{String.slice(t.token, 0, 10)}...")
    end)
  end
end
