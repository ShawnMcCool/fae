defmodule Fae.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FaeWeb.Telemetry,
      Fae.Repo,
      {Ecto.Migrator, repos: Application.fetch_env!(:fae, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:fae, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Fae.PubSub},
      Fae.SystemStatus,
      FaeWeb.Endpoint
    ]

    # max_restarts/max_seconds set explicitly per OTP discipline; defaults work
    # but explicit values document the chosen tolerance and prevent drift if
    # Erlang defaults ever change.
    opts = [
      strategy: :one_for_one,
      name: Fae.Supervisor,
      max_restarts: 3,
      max_seconds: 5
    ]

    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FaeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
