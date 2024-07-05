defmodule Fog.Log do
  use Ecto.Schema
  alias Fog.Repo

  @primary_key false

  schema "logs" do
    field :timestamp, :integer
    field :entry, :string
  end

  def logs_between_timestamps!(start_timestamp, end_timestamp) do
    result =
      Repo.query!(
        "SELECT timestamp, entry FROM logs WHERE timestamp BETWEEN ? AND ?",
        [start_timestamp, end_timestamp]
      )

    Enum.map(result.rows, &Repo.load(Fog.Log, {result.columns, &1}))
  end

  def insert!(timestamp, line) do
    Repo.insert!(%Fog.Log{
      timestamp: timestamp,
      entry: line
    })
  end
end
