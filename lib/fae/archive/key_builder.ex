defmodule Fae.Archive.KeyBuilder do
  @moduledoc """
  Pure composition of a destination `path_prefix`, a per-archive label,
  and a file's path relative to the source root into an S3 object key:

      <path_prefix>/<label>/<relative path>

  Empty segments are omitted, so an empty prefix or label simply drops
  out. The relative path's internal structure (and any whitespace in
  filenames) is preserved verbatim — only surrounding slashes are
  trimmed — so the user's on-disk curation is mirrored faithfully.
  """

  @separator "-"

  @spec build(String.t() | nil, String.t() | nil, String.t()) :: String.t()
  def build(path_prefix, label, relative_path) do
    [normalize_segment(path_prefix), normalize_segment(label), strip_slashes(relative_path)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("/")
  end

  @doc """
  Turns a free-text label into a URL-safe path segment: decompose
  accents to ASCII, lowercase, and collapse every run of non-alphanumeric
  characters into a single hyphen, trimmed. A label with nothing
  slug-worthy (only whitespace/punctuation) returns `{:error, :empty_slug}`
  so the caller can surface it rather than produce an empty path segment.
  """
  @spec slugify(String.t()) :: {:ok, String.t()} | {:error, :empty_slug}
  def slugify(label) do
    slug =
      label
      |> to_string()
      |> String.normalize(:nfd)
      |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, @separator)
      |> String.trim(@separator)

    if slug == "", do: {:error, :empty_slug}, else: {:ok, slug}
  end

  @doc """
  Composes the stored `label` for a quick archive — the remote folder
  segment that dates the upload:

      <quick_archive_prefix>/<YYYY>/<YYYY-MM-DD>-<slug>

  The prefix (a per-destination setting) is optional and drops out when
  empty. `date` is resolved at run-creation time, not upload time, so the
  path reflects when the operator clicked. Built on `build/3`, so the
  unchanged worker key path (`build(path_prefix, label, relative)`)
  produces the full object key with no quick-specific branch.
  """
  @spec quick_label(String.t() | nil, Date.t(), String.t()) ::
          {:ok, String.t()} | {:error, :empty_slug}
  def quick_label(quick_archive_prefix, %Date{} = date, label) do
    with {:ok, slug} <- slugify(label) do
      year = Integer.to_string(date.year)
      dated_folder = "#{Date.to_iso8601(date)}#{@separator}#{slug}"
      {:ok, build(quick_archive_prefix, year, dated_folder)}
    end
  end

  # User-supplied prefix/label: trim whitespace and surrounding slashes.
  defp normalize_segment(nil), do: ""
  defp normalize_segment(segment), do: segment |> to_string() |> String.trim() |> String.trim("/")

  # Filesystem relative path: only strip surrounding slashes; a leading
  # or trailing space could be part of a real filename, so leave it.
  defp strip_slashes(nil), do: ""
  defp strip_slashes(path), do: path |> to_string() |> String.trim("/")
end
