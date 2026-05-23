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

  @spec build(String.t() | nil, String.t() | nil, String.t()) :: String.t()
  def build(path_prefix, label, relative_path) do
    [normalize_segment(path_prefix), normalize_segment(label), strip_slashes(relative_path)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("/")
  end

  # User-supplied prefix/label: trim whitespace and surrounding slashes.
  defp normalize_segment(nil), do: ""
  defp normalize_segment(segment), do: segment |> to_string() |> String.trim() |> String.trim("/")

  # Filesystem relative path: only strip surrounding slashes; a leading
  # or trailing space could be part of a real filename, so leave it.
  defp strip_slashes(nil), do: ""
  defp strip_slashes(path), do: path |> to_string() |> String.trim("/")
end
