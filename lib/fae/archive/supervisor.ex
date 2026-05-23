defmodule Fae.Archive.Supervisor do
  @moduledoc """
  Top-level supervisor for the Archive tool. Owns the `ProgressServer`
  that holds live progress for in-flight runs. Run execution itself
  happens inside Oban (`Fae.Archive.ArchiveWorker`).
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Fae.Archive.ProgressServer
    ]

    # max_restarts/max_seconds explicit per OTP discipline.
    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 5
    )
  end
end
