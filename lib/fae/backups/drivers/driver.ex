defmodule Fae.Backups.Drivers.Driver do
  @moduledoc """
  Behaviour for destination drivers. The run pipeline targets this
  behaviour exclusively; concrete implementations (currently only
  S3-compatible) plug in via `Fae.Backups.Drivers.driver_for/1`.

  Implementations should be pure functions of the `Destination`
  struct plus arguments — no GenServer or other shared state.
  """

  alias Fae.Backups.Destination

  @type put_result :: %{byte_size: non_neg_integer(), sha256: String.t()}
  @type object :: %{key: String.t(), last_modified: DateTime.t(), size: non_neg_integer()}

  @callback put(Destination.t(), key :: String.t(), source_path :: String.t()) ::
              {:ok, put_result()} | {:error, term()}

  @callback list(Destination.t(), prefix :: String.t()) ::
              {:ok, [object()]} | {:error, term()}

  @callback delete(Destination.t(), key :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Cheapest possible reachability + auth + region check, used by the
  destination form's "save = verify first" path. Implementations
  should distinguish the common failure modes so the UI can attach
  the error to the right field:

    * `:unauthorized` / `:forbidden` — bad credentials
    * `:no_bucket` — endpoint reached but the bucket doesn't exist
    * `{:wrong_region, hint_or_nil}` — endpoint hit, bucket lives
      elsewhere (S3 returns the correct region as a hint)
    * `{:network, reason}` — DNS, TLS, connection refused, etc.
    * `{:s3_error, status, body}` — anything else
  """
  @callback verify(Destination.t()) ::
              :ok
              | {:error,
                 :unauthorized
                 | :forbidden
                 | :no_bucket
                 | {:wrong_region, String.t() | nil}
                 | {:network, term()}
                 | {:s3_error, pos_integer(), term()}}
end
