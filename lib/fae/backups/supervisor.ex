defmodule Fae.Backups.Supervisor do
  @moduledoc """
  Top-level supervisor for the Backups tool. Owns the registry that
  enforces per-job run-exclusivity, plus the notifier that surfaces
  failures as desktop notifications. Run execution itself happens
  inside Oban (`Fae.Backups.RunWorker`); scheduling is driven by job
  CRUD hooks rather than a dedicated scheduler process.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Fae.Backups.RunRegistry,
      Fae.Backups.Scheduler
    ]

    # max_restarts/max_seconds explicit per OTP discipline.
    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 5
    )
  end
end
