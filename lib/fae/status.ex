defmodule Fae.Status do
  @moduledoc """
  Read-model that gathers Fae's live operational state into a single input map.

  This is the one place the application's status is read across contexts
  (backups, storage, dotfiles, self-update, system uptime, version). Both the
  LiveView dashboard (`FaeWeb.DashboardView`) and the machine-facing status
  contract (`FaeWeb.StatusContract`) are pure transforms of this snapshot, so
  the web UI and the `/api/status` endpoint always read the same facts.

  All side-effecting reads (Repo queries, GenServer calls) live here.
  """

  alias Fae.{Clock, Dotfiles, SelfUpdate, SystemStatus, Version}
  alias Fae.Backups.{Jobs, Runs}
  alias Fae.Storage.Destinations

  @recent_activity_limit 10

  @type t :: %{
          jobs: [Fae.Backups.Job.t()],
          last_runs: %{optional(Ecto.UUID.t()) => Fae.Backups.Run.t() | nil},
          recent_runs: [Fae.Backups.Run.t()],
          destinations: [Fae.Storage.Destination.t()],
          version: String.t(),
          latest_release: map() | nil,
          self_update_phase: atom(),
          self_update_error: term(),
          system: %{boot_at: DateTime.t(), uptime_seconds: non_neg_integer()},
          now: DateTime.t(),
          dotfiles: %{
            config: Dotfiles.Config.t(),
            tracked_count: non_neg_integer(),
            last_run: map() | nil
          }
        }

  @doc """
  Reads the current operational state. Returns the raw input map consumed by
  the dashboard and status-contract presenters.
  """
  @spec snapshot() :: t()
  def snapshot do
    jobs = Jobs.list()
    self_update = SelfUpdate.current_status()

    %{
      jobs: jobs,
      last_runs: Map.new(jobs, fn job -> {job.id, Runs.last(job.id)} end),
      recent_runs: Runs.list_recent_all(@recent_activity_limit),
      destinations: Destinations.list(),
      version: Version.current_version(),
      latest_release: cached_release(),
      self_update_phase: self_update.phase,
      self_update_error: self_update.error,
      system: SystemStatus.get_state(),
      now: Clock.now(),
      dotfiles: %{
        config: Dotfiles.get_config(),
        tracked_count: length(Dotfiles.list_tracked()),
        last_run: Dotfiles.last_run()
      }
    }
  end

  defp cached_release do
    case SelfUpdate.cached_release() do
      {:ok, release} -> release
      :none -> nil
    end
  end
end
