defmodule Fae.Backups.Packager do
  @moduledoc """
  Turns a snapshot (`{kind, path}` from a source adapter) into an
  upload-ready file plus its filename extension.

  Two formats:

    * `"as_is"` — only valid for `:file` snapshots; the snapshot path
      is used directly, no copy. Extension preserved from the source
      filename (or `"bin"` if it had none).
    * `"tar_gz"` — produces `tar.gz` of the snapshot via the system
      `tar` binary. For `:dir` snapshots this is the only valid
      format; for `:file` snapshots it wraps the file. Extension is
      `"tar.gz"`. Cleanup removes the temp archive.
  """

  @type kind :: :file | :dir
  @type result ::
          {:ok, upload_path :: String.t(), ext :: String.t(), cleanup :: (-> :ok)}
          | {:error, term()}

  @spec package(kind(), String.t(), String.t()) :: result()
  def package(:file, path, "as_is") do
    ext =
      case Path.extname(path) do
        "" -> "bin"
        "." <> rest -> rest
      end

    {:ok, path, ext, fn -> :ok end}
  end

  def package(:dir, _path, "as_is") do
    {:error, :folder_requires_tar_gz}
  end

  def package(kind, path, "tar_gz") when kind in [:file, :dir] do
    tmp = Path.join(System.tmp_dir!(), "fae-backup-pkg-#{Ecto.UUID.generate()}.tar.gz")
    parent = Path.dirname(path)
    basename = Path.basename(path)

    case System.cmd("tar", ["--use-compress-program=gzip", "-cf", tmp, "-C", parent, basename],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        {:ok, tmp, "tar.gz",
         fn ->
           _ = File.rm(tmp)
           :ok
         end}

      {output, exit_code} ->
        _ = File.rm(tmp)
        {:error, {:tar_failed, exit_code, output}}
    end
  end

  def package(kind, _path, format), do: {:error, {:unsupported_packaging, kind, format}}
end
