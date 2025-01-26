defmodule Fog.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = File.mkdir_p(Fog.LogStore.tmp_path())

    children = [
      FogWeb.Telemetry,
      Fog.Repo,
      {Ecto.Migrator, repos: Application.fetch_env!(:fog, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:fog, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Fog.PubSub},
      {Registry, keys: :unique, name: Fog.LogServer.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Fog.LogServer.Supervisor},
      {Fog.LogStore.Realtime, name: Fog.LogStore.Realtime},
      # Start a worker by calling: Fog.Worker.start_link(arg)
      # {Fog.Worker, arg},
      # Start to serve requests, typically the last entry
      FogWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fog.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FogWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end
end
