defmodule Fae.Archive.Run do
  @moduledoc """
  One bulk archival run: a source directory streamed up to a storage
  destination under a free-text label. Object keys mirror the source
  tree as `<destination.path_prefix>/<label>/<relative path>`.

  The DB row is the durable record and the final tally; live progress
  while a run is in flight lives in `Fae.Archive.ProgressServer`, not
  here (per the desktop-app state-ownership decision).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Fae.Storage.Destination

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime]

  @statuses ~w(pending scanning uploading completed partial failed canceled)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t(),
          kind: String.t(),
          source_path: String.t() | nil,
          label: String.t(),
          status: String.t(),
          total_files: non_neg_integer(),
          total_bytes: non_neg_integer(),
          uploaded_files: non_neg_integer(),
          uploaded_bytes: non_neg_integer(),
          failed_files: non_neg_integer(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          error_message: String.t() | nil,
          destination_id: Ecto.UUID.t() | nil,
          destination: Destination.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "archive_runs" do
    field :name, :string, default: ""
    # "standard" (curated, content-dated, reconfigurable) or "quick"
    # (one-shot, upload-dated — `label` carries the dated folder path).
    field :kind, :string, default: "standard"
    field :source_path, :string
    # The remote folder segment of the object key (after the
    # destination's path_prefix). May contain slashes.
    field :label, :string, default: ""
    field :status, :string, default: "pending"
    field :total_files, :integer, default: 0
    field :total_bytes, :integer, default: 0
    field :uploaded_files, :integer, default: 0
    field :uploaded_bytes, :integer, default: 0
    field :failed_files, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :error_message, :string

    belongs_to :destination, Destination

    timestamps()
  end

  @doc """
  Changeset for creating a run from user input. Validates that the
  source path is an existing directory so the form can surface a typo
  inline rather than failing at scan time.
  """
  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [:name, :source_path, :label, :destination_id])
    |> update_change(:name, &String.trim/1)
    |> update_change(:source_path, &String.trim/1)
    |> normalize_label()
    |> validate_required([:name, :source_path, :destination_id])
    |> validate_source_directory()
    |> assoc_constraint(:destination)
  end

  @doc """
  Form changeset for a quick archive: one-shot, upload-dated. Validates
  only the operator-facing fields — `name` (the label text, shown in the
  list), `source_path`, and `destination_id`. `kind` is forced to `quick`.

  The `label` (the dated folder path
  `<quick_archive_prefix>/<YYYY>/<YYYY-MM-DD>-<slug>`) is *not* a form
  field: `Fae.Archive` computes it from the name + destination + today and
  puts it on the record at insert time, so the worker's existing key path
  needs no quick-specific branch.
  """
  def quick_form_changeset(run, attrs) do
    run
    |> cast(attrs, [:name, :source_path, :destination_id])
    |> put_change(:kind, "quick")
    |> update_change(:name, &String.trim/1)
    |> update_change(:source_path, &String.trim/1)
    |> validate_required([:name, :source_path, :destination_id])
    |> validate_source_directory()
    |> assoc_constraint(:destination)
  end

  @doc """
  Changeset for an in-place rename — the only safe mutation of an
  existing archive, since `name` doesn't feed the object key. All other
  changes go through the clone-and-replace ("Reconfigure") flow.
  """
  def rename_changeset(run, attrs) do
    run
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
  end

  defp normalize_label(changeset) do
    case get_change(changeset, :label) do
      nil -> changeset
      value -> put_change(changeset, :label, String.trim(value))
    end
  end

  defp validate_source_directory(changeset) do
    case get_field(changeset, :source_path) do
      blank when blank in [nil, ""] ->
        changeset

      path ->
        if File.dir?(path) do
          changeset
        else
          add_error(changeset, :source_path, "is not an existing directory")
        end
    end
  end

  @doc "Valid status strings."
  def statuses, do: @statuses
end
