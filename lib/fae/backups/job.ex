defmodule Fae.Backups.Job do
  @moduledoc """
  A backup job: source + destination + schedule + retention. The
  scheduler enqueues runs of these via `Fae.Backups.RunWorker`.

  ## Source kinds

  * `"file"` — a single file on disk.
  * `"folder"` — a directory; always packaged as `tar_gz`.
  * `"sqlite"` — a SQLite DB; the source adapter runs `VACUUM INTO`
    to a temp file before packaging, so live DBs (including Fae's own
    DB) can be snapshotted safely.

  ## Package formats

  * `"as_is"` — single-file sources only; the source bytes are uploaded
    unchanged.
  * `"tar_gz"` — wrap (and compress) into a `.tar.gz` before upload.
    Required for folder sources.

  ## Recurrence

  * `"hourly"` — fires at `:00` every hour. `time_of_day` ignored.
  * `"daily"` — fires at `time_of_day` every day.
  * `"weekly"` — fires at `time_of_day` on `day_of_week` (0 = Sunday).
  * `"monthly"` — fires at `time_of_day` on `day_of_month` (capped at
    28 to avoid month-end edge cases).

  ## Retention strategies

  * `"keep_last_n"` — params: `%{"n" => integer}`.
  * `"keep_for_days"` — params: `%{"days" => integer}`.
  * `"gfs"` — params: `%{"daily" => i, "weekly" => i, "monthly" => i}`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Fae.Storage.Destination

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime]

  @source_kinds ~w(file folder sqlite)
  @package_formats ~w(as_is tar_gz)
  @recurrence_kinds ~w(hourly daily weekly monthly)
  @retention_strategies ~w(keep_last_n keep_for_days gfs)
  @time_of_day_regex ~r/^(?:[01]\d|2[0-3]):[0-5]\d$/
  @slug_regex ~r/^[a-z0-9][a-z0-9-]*$/

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          source_kind: String.t() | nil,
          source_path: String.t() | nil,
          destination_id: Ecto.UUID.t() | nil,
          destination: Destination.t() | Ecto.Association.NotLoaded.t() | nil,
          prefix: String.t() | nil,
          package_format: String.t() | nil,
          recurrence_kind: String.t() | nil,
          time_of_day: String.t() | nil,
          day_of_week: integer() | nil,
          day_of_month: integer() | nil,
          retention_strategy: String.t() | nil,
          retention_params: map() | nil,
          enabled: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "backup_jobs" do
    field :name, :string
    field :slug, :string
    field :source_kind, :string
    field :source_path, :string

    belongs_to :destination, Destination

    field :prefix, :string, default: ""
    field :package_format, :string
    field :recurrence_kind, :string
    field :time_of_day, :string
    field :day_of_week, :integer
    field :day_of_month, :integer
    field :retention_strategy, :string
    field :retention_params, :map
    field :enabled, :boolean, default: true

    timestamps()
  end

  @required ~w(name slug source_kind source_path destination_id package_format
               recurrence_kind retention_strategy retention_params)a
  @optional ~w(prefix time_of_day day_of_week day_of_month enabled)a

  def changeset(job, attrs) do
    job
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_format(:slug, @slug_regex,
      message: "must be lowercase letters, digits, and hyphens"
    )
    |> validate_inclusion(:source_kind, @source_kinds)
    |> validate_inclusion(:package_format, @package_formats)
    |> validate_inclusion(:recurrence_kind, @recurrence_kinds)
    |> validate_inclusion(:retention_strategy, @retention_strategies)
    |> validate_folder_requires_tar_gz()
    |> validate_recurrence_fields()
    |> validate_time_of_day_format()
    |> validate_retention_params()
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:destination_id)
  end

  defp validate_folder_requires_tar_gz(changeset) do
    case {get_field(changeset, :source_kind), get_field(changeset, :package_format)} do
      {"folder", "as_is"} ->
        add_error(
          changeset,
          :package_format,
          "must be 'tar_gz' when source_kind is 'folder'"
        )

      _ ->
        changeset
    end
  end

  defp validate_recurrence_fields(changeset) do
    case get_field(changeset, :recurrence_kind) do
      "hourly" ->
        changeset

      "daily" ->
        require_field(changeset, :time_of_day, "is required for daily schedules")

      "weekly" ->
        changeset
        |> require_field(:time_of_day, "is required for weekly schedules")
        |> require_field(:day_of_week, "is required for weekly schedules")
        |> validate_inclusion(:day_of_week, 0..6,
          message: "must be between 0 (Sunday) and 6 (Saturday)"
        )

      "monthly" ->
        changeset
        |> require_field(:time_of_day, "is required for monthly schedules")
        |> require_field(:day_of_month, "is required for monthly schedules")
        |> validate_inclusion(:day_of_month, 1..28, message: "must be between 1 and 28")

      _ ->
        changeset
    end
  end

  defp require_field(changeset, field, message) do
    case get_field(changeset, field) do
      nil -> add_error(changeset, field, message)
      _ -> changeset
    end
  end

  defp validate_time_of_day_format(changeset) do
    case get_field(changeset, :time_of_day) do
      nil ->
        changeset

      value ->
        if Regex.match?(@time_of_day_regex, value) do
          changeset
        else
          add_error(changeset, :time_of_day, "must be in HH:MM format")
        end
    end
  end

  defp validate_retention_params(changeset) do
    strategy = get_field(changeset, :retention_strategy)
    params = get_field(changeset, :retention_params)

    case {strategy, params} do
      {"keep_last_n", %{"n" => n}} when is_integer(n) and n > 0 ->
        changeset

      {"keep_for_days", %{"days" => d}} when is_integer(d) and d > 0 ->
        changeset

      {"gfs", %{"daily" => d, "weekly" => w, "monthly" => m}}
      when is_integer(d) and is_integer(w) and is_integer(m) and d >= 0 and w >= 0 and m >= 0 ->
        changeset

      {nil, _} ->
        changeset

      _ ->
        add_error(
          changeset,
          :retention_params,
          "shape does not match retention_strategy"
        )
    end
  end

  @doc "Allowed source_kind values."
  def source_kinds, do: @source_kinds

  @doc "Allowed package_format values."
  def package_formats, do: @package_formats

  @doc "Allowed recurrence_kind values."
  def recurrence_kinds, do: @recurrence_kinds

  @doc "Allowed retention_strategy values."
  def retention_strategies, do: @retention_strategies
end
