defmodule Fog.Repo do
  use Ecto.Repo,
    otp_app: :fog,
    adapter: Ecto.Adapters.SQLite3,
    pool_size: 1
end
