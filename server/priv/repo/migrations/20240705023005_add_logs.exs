defmodule Fog.Repo.Migrations.AddLogs do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TABLE logs(timestamp INTEGER PRIMARY KEY AUTOINCREMENT, entry TEXT);",
      "DROP TABLE logs"
    )
  end
end
