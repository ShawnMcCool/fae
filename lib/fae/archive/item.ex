defmodule Fae.Archive.Item do
  @moduledoc """
  One file within an archive run. Carries the durable upload record —
  object key, byte size, SHA256, and provider ETag — that lets the user
  trust the copy enough to reclaim local space later, and lets an
  interrupted run resume by skipping items already `uploaded`.
  """
  use Ecto.Schema

  alias Fae.Archive.Run

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime]

  @statuses ~w(pending uploaded failed)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          relative_path: String.t() | nil,
          object_key: String.t() | nil,
          status: String.t(),
          byte_size: non_neg_integer() | nil,
          sha256: String.t() | nil,
          etag: String.t() | nil,
          error_message: String.t() | nil,
          attempts: non_neg_integer(),
          uploaded_at: DateTime.t() | nil,
          run_id: Ecto.UUID.t() | nil,
          run: Run.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "archive_items" do
    field :relative_path, :string
    field :object_key, :string
    field :status, :string, default: "pending"
    field :byte_size, :integer
    field :sha256, :string
    field :etag, :string
    field :error_message, :string
    field :attempts, :integer, default: 0
    field :uploaded_at, :utc_datetime_usec

    belongs_to :run, Run

    timestamps()
  end

  @doc "Valid status strings."
  def statuses, do: @statuses
end
