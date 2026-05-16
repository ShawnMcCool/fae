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
      {Oban, Application.fetch_env!(:fae, Oban)},
      {Task.Supervisor, name: Fae.TaskSupervisor},
      {DNSCluster, query: Application.get_env(:fae, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Fae.PubSub},
      Fae.SystemStatus,
      Fae.SelfUpdate.Updater,
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

    children
    |> Supervisor.start_link(opts)
    |> post_supervisor_hooks()
  end

  # Runs post-start hooks when the supervision tree came up successfully.
  # Skipping the hooks on a failed start prevents misleading secondary
  # errors from masking the original cause of the failure.
  defp post_supervisor_hooks({:ok, _pid} = result) do
    if Fae.SelfUpdate.enabled?() do
      Fae.SelfUpdate.boot!()
    end

    result
  end

  defp post_supervisor_hooks({:error, _reason} = error), do: error

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
