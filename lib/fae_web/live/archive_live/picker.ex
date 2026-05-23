defmodule FaeWeb.ArchiveLive.Picker do
  @moduledoc """
  Backends for the archive folder pickers: list one level of folders on
  the local filesystem (for the Source field) or inside a destination's
  bucket (for the Remote folder field), plus the path math for navigating
  up and down.

  Object storage has no real directories, so the remote side uses
  delimiter listing (CommonPrefixes) via the driver, browsing relative to
  the destination's `path_prefix` — the selected relative path becomes the
  archive's remote folder (`label`).
  """
  alias Fae.Storage.Destination
  alias Fae.Storage.Drivers

  @doc "Sub-directory names of a local path, sorted."
  @spec list_local(String.t()) :: {:ok, %{folders: [String.t()]}} | {:error, term()}
  def list_local(path) do
    case File.ls(path) do
      {:ok, names} ->
        folders =
          names
          |> Enum.filter(&File.dir?(Path.join(path, &1)))
          |> Enum.sort()

        {:ok, %{folders: folders}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Sub-folder names under `rel` within the destination, sorted."
  @spec list_remote(Destination.t(), String.t()) ::
          {:ok, %{folders: [String.t()]}} | {:error, term()}
  def list_remote(%Destination{} = dest, rel) do
    s3_prefix = remote_s3_prefix(dest, rel)
    driver = Drivers.driver_for(dest)

    case driver.list_prefixes(dest, s3_prefix) do
      {:ok, %{prefixes: prefixes}} ->
        folders =
          prefixes
          |> Enum.map(fn full ->
            full |> String.trim_trailing("/") |> String.replace_prefix(s3_prefix, "")
          end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.sort()

        {:ok, %{folders: folders}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc ~S"""
  The S3 key prefix (trailing slash, or "" at the root) for a destination
  plus a relative browse path.
  """
  @spec remote_s3_prefix(Destination.t(), String.t()) :: String.t()
  def remote_s3_prefix(%Destination{} = dest, rel) do
    [dest.path_prefix, rel]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("/")
    |> case do
      "" -> ""
      joined -> joined <> "/"
    end
  end

  @spec remote_join(String.t(), String.t()) :: String.t()
  def remote_join("", name), do: name
  def remote_join(rel, name), do: rel <> "/" <> name

  @spec remote_parent(String.t()) :: String.t()
  def remote_parent(rel) do
    rel |> String.split("/", trim: true) |> Enum.drop(-1) |> Enum.join("/")
  end

  @spec local_parent(String.t()) :: String.t()
  def local_parent(path), do: Path.dirname(path)
end
