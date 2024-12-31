defmodule Fog.Repo.Migrations.AddTokens do
  use Ecto.Migration

  def change do
    create table(:agent_tokens) do
      add(:token, :string, null: false)
      add(:description, :string)
      add(:last_used_at, :utc_datetime)
      add(:active, :boolean, default: true, null: false)

      timestamps()
    end

    create(unique_index(:agent_tokens, [:token]))
  end
end
