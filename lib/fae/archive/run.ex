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
    field :source_path, :string
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
    |> cast(attrs, [:source_path, :label, :destination_id])
    |> validate_required([:source_path, :destination_id])
    |> update_change(:source_path, &String.trim/1)
    |> normalize_label()
    |> validate_source_directory()
    |> assoc_constraint(:destination)
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
