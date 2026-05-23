defmodule Fae.Storage.Drivers.Driver do
  @moduledoc """
  Behaviour for destination drivers. Callers target this behaviour
  exclusively; concrete implementations (currently only
  S3-compatible) plug in via `Fae.Storage.Drivers.driver_for/1`.

  Implementations should be pure functions of the `Destination`
  struct plus arguments — no GenServer or other shared state.
  """

  alias Fae.Storage.Destination

  @type put_result :: %{byte_size: non_neg_integer(), sha256: String.t()}
  @type stream_result :: %{byte_size: non_neg_integer(), sha256: String.t(), etag: String.t()}
  @type object :: %{key: String.t(), last_modified: DateTime.t(), size: non_neg_integer()}

  @callback put(Destination.t(), key :: String.t(), source_path :: String.t()) ::
              {:ok, put_result()} | {:error, term()}

  @doc """
  Streaming, integrity-checked upload for large files (the Archive
  tool). Reads `source_path` in bounded parts so memory stays flat
  regardless of file size, sends a per-part `Content-MD5` so the
  provider rejects any corrupted bytes in transit, and folds a
  whole-file SHA256 while streaming. After the upload it confirms the
  stored object's size with a HEAD.

  Files at or below the part size go up as a single PUT; larger files
  use S3 multipart upload. Either way the result records the bytes,
  the locally-computed SHA256 (the durable integrity record), and the
  provider's ETag.

  Recognised `opts`:

    * `:part_size_bytes` — override the default part size (mainly for
      tests; note S3 requires non-final parts to be at least 5 MiB).
  """
  @callback put_stream(
              Destination.t(),
              key :: String.t(),
              source_path :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, stream_result()} | {:error, term()}

  @callback list(Destination.t(), prefix :: String.t()) ::
              {:ok, [object()]} | {:error, term()}

  @doc """
  Lists a single level of the keyspace under `prefix` using
  `delimiter=/`: the immediate sub-folders (`prefixes`, from S3
  CommonPrefixes) and the files at this level (`keys`). Powers the
  destination folder picker.
  """
  @callback list_prefixes(Destination.t(), prefix :: String.t()) ::
              {:ok, %{prefixes: [String.t()], keys: [String.t()]}} | {:error, term()}

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
