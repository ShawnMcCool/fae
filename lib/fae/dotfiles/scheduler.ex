defmodule Fae.Dotfiles.Scheduler do
  @moduledoc """
  Keeps exactly one scheduled `Fae.Dotfiles.BackupWorker` job queued,
  matching the current config. Subscribes to `dotfiles:status` and
  reconciles on every `{:dotfiles_changed}` broadcast so cadence and
  enable/disable changes take effect immediately.

  Reconciliation cancels any queued/scheduled/retryable BackupWorker
  job, then (if the tool is initialized and enabled) inserts a fresh
  one at `now + interval_seconds`. When not initialized or disabled,
  only the cancellation step runs.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fae.Dotfiles.{BackupWorker, Configs}

  def start_link(opts \\ []) do
    if enabled?() do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @doc """
  Whether the scheduler should run in this environment. Off in :test
  by default so the global GenServer doesn't fight with the per-test
  SQL sandbox; on otherwise.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:fae, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @doc """
  Synchronously reconciles via the GenServer. Production callers use
  this; tests call `do_reconcile/0` directly so Oban's process-local
  testing mode applies.
  """
  @spec reconcile() :: :ok
  def reconcile, do: GenServer.call(__MODULE__, :reconcile)

  @impl true
  def init(_opts) do
    :ok = Fae.Dotfiles.subscribe_status()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:dotfiles_changed}, state) do
    do_reconcile()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:reconcile, _from, state) do
    do_reconcile()
    {:reply, :ok, state}
  end

  # Exposed for tests that run reconciliation in the test process so
  # Oban testing-mode flags (which are process-local) apply.
  @doc false
  @spec do_reconcile() :: :ok
  def do_reconcile do
    cancel_queued()

    config = Configs.get()

    if config.initialized and config.enabled do
      case schedule_next(config) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("Dotfiles scheduler insert failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc false
  @spec schedule_next(Fae.Dotfiles.Config.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def schedule_next(config) do
    next = DateTime.add(Fae.Clock.now(), config.interval_seconds, :second)

    %{"kind" => "scheduled"}
    |> BackupWorker.new(scheduled_at: next)
    |> Oban.insert()
  end

  defp cancel_queued do
    worker_name = inspect(BackupWorker)

    query =
      from j in Oban.Job,
        where: j.worker == ^worker_name,
        where: j.state in ["available", "scheduled", "retryable"]

    Oban.cancel_all_jobs(query)
  end
end
