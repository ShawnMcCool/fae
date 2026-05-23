defmodule FaeWeb.PathBrowser.Source do
  @moduledoc """
  Backend for `FaeWeb.PathBrowser`: list one level of a tree — the local
  filesystem or a destination's bucket — plus the path math for
  navigating up and down.

  Object storage has no real directories, so the remote side uses
  delimiter listing (CommonPrefixes) via the driver, browsing relative
  to the destination's `path_prefix`. `relativize/3` turns the driver's
  full prefixes/keys into leaf names (carrying file size + last-modified)
  for display.
  """
  alias Fae.Storage.Destination
  alias Fae.Storage.Drivers

  @type entry :: %{name: String.t(), size: non_neg_integer(), last_modified: DateTime.t() | nil}
  @type listing :: %{folders: [String.t()], files: [entry()]}
  @type source :: {:local, String.t()} | {:remote, Destination.t(), String.t()}

  @doc "One level of folders (always) and files (when `show_files?`)."
  @spec list(source(), boolean()) :: {:ok, listing()} | {:error, term()}
  def list({:local, path}, show_files?), do: list_local(path, show_files?)
  def list({:remote, dest, rel}, show_files?), do: list_remote(dest, rel, show_files?)

  defp list_local(path, show_files?) do
    case File.ls(path) do
      {:ok, names} ->
        {dirs, files} = Enum.split_with(names, &File.dir?(Path.join(path, &1)))
        {:ok, %{folders: Enum.sort(dirs), files: local_files(path, files, show_files?)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp local_files(_path, _names, false), do: []

  defp local_files(path, names, true) do
    names
    |> Enum.sort()
    |> Enum.map(fn name ->
      stat = File.stat!(Path.join(path, name), time: :posix)
      %{name: name, size: stat.size, last_modified: DateTime.from_unix!(stat.mtime)}
    end)
  end

  defp list_remote(%Destination{} = dest, rel, show_files?) do
    s3_prefix = remote_s3_prefix(dest, rel)
    driver = Drivers.driver_for(dest)

    case driver.list_prefixes(dest, s3_prefix) do
      {:ok, listing} -> {:ok, relativize(listing, s3_prefix, show_files?)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Turn the driver's full prefixes/keys into leaf names relative to `s3_prefix`."
  @spec relativize(map(), String.t(), boolean()) :: listing()
  def relativize(%{prefixes: prefixes} = listing, s3_prefix, show_files?) do
    folders =
      prefixes
      |> Enum.map(fn full ->
        full |> String.trim_trailing("/") |> String.replace_prefix(s3_prefix, "")
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.sort()

    %{folders: folders, files: relativize_files(listing[:files] || [], s3_prefix, show_files?)}
  end

  defp relativize_files(_files, _s3_prefix, false), do: []

  defp relativize_files(files, s3_prefix, true) do
    files
    |> Enum.map(fn file ->
      %{
        name: String.replace_prefix(file.key, s3_prefix, ""),
        size: file.size,
        last_modified: file.last_modified
      }
    end)
    |> Enum.reject(&(&1.name == ""))
    |> Enum.sort_by(& &1.name)
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

  @doc "Descend into `name` from the current location."
  @spec down(:local | :remote, String.t(), String.t()) :: String.t()
  def down(:local, path, name), do: Path.join(path, name)
  def down(:remote, "", name), do: name
  def down(:remote, rel, name), do: rel <> "/" <> name

  @doc "Ascend one level from the current location."
  @spec up(:local | :remote, String.t()) :: String.t()
  def up(:local, path), do: Path.dirname(path)

  def up(:remote, rel),
    do: rel |> String.split("/", trim: true) |> Enum.drop(-1) |> Enum.join("/")

  @doc "Human label for the current location."
  @spec location_label(:local | :remote, String.t()) :: String.t()
  def location_label(:local, path), do: path
  def location_label(:remote, ""), do: "(top level)"
  def location_label(:remote, rel), do: rel
end
