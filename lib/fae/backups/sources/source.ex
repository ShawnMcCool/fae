defmodule Fae.Backups.Sources.Source do
  @moduledoc """
  Behaviour for source adapters. A snapshot is a moment-in-time
  capture of the source ready to be packaged and uploaded.

  Implementations return:

    * `:file` — a single regular file, ready to be packaged as-is or
      tar.gz'd.
    * `:dir` — a directory whose contents should be tar.gz'd.

  The returned `cleanup` function is called by `RunPipeline` after
  the run finishes (success or failure). Adapters that hand back the
  original on-disk path (File, Folder) return a no-op cleanup;
  adapters that materialize a temp file (Sqlite) return a cleanup
  that removes it.
  """

  @type snapshot ::
          {:ok, kind :: :file | :dir, path :: String.t(), cleanup :: (-> :ok)}
          | {:error, term()}

  @callback snapshot(source_path :: String.t()) :: snapshot()
end
