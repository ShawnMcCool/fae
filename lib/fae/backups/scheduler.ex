defmodule Fae.Backups.Scheduler do
  @moduledoc """
  Subscribes to `backups:jobs` and keeps each enabled job's next-fire
  Oban entry up-to-date. On boot, reconciles every enabled job from
  the DB; on every `{:job_changed, id}` broadcast, reconciles that
  one job.

  Reconciliation = cancel any queued/scheduled/retryable
  `Fae.Backups.RunWorker` for this job_id, then insert a fresh one
  with `scheduled_at` computed from the current recurrence rules. If
  the job no longer exists or is disabled, only the cancellation
  step runs.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fae.Backups.{Jobs, Recurrence, RunWorker}

  def start_link(opts \\ []) do
    if enabled?() do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @doc """
  Returns whether the scheduler should run in this environment. Off
  in :test by default so the global GenServer doesn't fight with the
  per-test SQL sandbox; on otherwise.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:fae, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @doc """
  Synchronously reconciles one job. Public mostly for tests; the
  runtime path is the PubSub handler.
  """
  @spec reconcile(String.t()) :: :ok
  def reconcile(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:reconcile, job_id})
  end

  @doc """
  Reconciles every enabled job from the DB. Called on application
  boot (via `Fae.Backups.boot!/0`) so jobs whose previously-queued
  Oban entries were wiped (fresh DB, queue purge, etc.) get
  scheduled. Idempotent — re-running is safe.
  """
  @spec hydrate() :: :ok
  def hydrate, do: GenServer.call(__MODULE__, :hydrate)

  @impl true
  def init(_opts) do
    :ok = Fae.Backups.subscribe_jobs()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:job_changed, job_id}, state) do
    do_reconcile(job_id)
    {:noreply, state}
  end

  @impl true
  def handle_call({:reconcile, job_id}, _from, state) do
    do_reconcile(job_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:hydrate, _from, state) do
    for job <- Jobs.list_enabled() do
      do_reconcile(job.id)
    end

    {:reply, :ok, state}
  end

  # Exposed for tests that want to run reconciliation in the test
  # process so Oban testing-mode flags (which are process-local)
  # apply. Production callers go through `reconcile/1` (which routes
  # through the GenServer).
  @doc false
  def do_reconcile(job_id) do
    cancel_queued(job_id)

    case Jobs.get(job_id) do
      nil ->
        :ok

      %{enabled: false} ->
        :ok

      job ->
        case insert_next(job) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("Scheduler insert failed for #{job_id}: #{inspect(reason)}")
        end
    end
  end

  defp cancel_queued(job_id) do
    worker_name = inspect(RunWorker)

    query =
      from j in Oban.Job,
        where: j.worker == ^worker_name,
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("json_extract(?, '$.job_id') = ?", j.args, ^job_id)

    Oban.cancel_all_jobs(query)
  end

  defp insert_next(job) do
    next = Recurrence.next_fire(job, Fae.Clock.now())

    %{"job_id" => job.id, "kind" => "scheduled"}
    |> RunWorker.new(scheduled_at: next)
    |> Oban.insert()
  end
end
