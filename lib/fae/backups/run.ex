defmodule Fae.Backups.Run do
  @moduledoc """
  One execution of a backup job. Created in `"running"` state at the
  start of the pipeline; transitioned to `"success"`, `"failed"`,
  `"snoozed"`, or `"skipped"` when it finishes.

  `"skipped"` happens when a job's previous run is still in flight at
  the next schedule tick (skip-if-overlapping).

  `"snoozed"` is a non-fatal attempt — a transient error (DNS,
  TCP, 5xx, rate-limit) hit while attempts remain. The Oban worker
  will retry per its backoff schedule; the dashboard does not treat
  snoozed runs as failures.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Fae.Backups.Job

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  @statuses ~w(running success failed skipped snoozed)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          job_id: Ecto.UUID.t() | nil,
          job: Job.t() | Ecto.Association.NotLoaded.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          status: String.t() | nil,
          error_message: String.t() | nil,
          object_key: String.t() | nil,
          byte_size: integer() | nil,
          sha256: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "backup_runs" do
    belongs_to :job, Job

    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :status, :string
    field :error_message, :string
    field :object_key, :string
    field :byte_size, :integer
    field :sha256, :string

    timestamps()
  end

  @doc "Changeset for an initial 'running' insert."
  def start_changeset(run, attrs) do
    run
    |> cast(attrs, [:job_id, :started_at, :status])
    |> validate_required([:job_id, :started_at, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:job_id)
  end

  @doc "Changeset for transitioning a run to a terminal state."
  def finish_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :finished_at,
      :status,
      :error_message,
      :object_key,
      :byte_size,
      :sha256
    ])
    |> validate_required([:finished_at, :status])
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Allowed status values."
  def statuses, do: @statuses
end
