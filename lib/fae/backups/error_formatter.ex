defmodule Fae.Backups.ErrorFormatter do
  @moduledoc """
  Turns pipeline error terms into human-readable strings for storage
  in `Fae.Backups.Run.error_message`.

  The stored format is a single-line summary, then a blank line, then
  the raw `inspect/1` of the term for debugging:

      DNS lookup failed for the storage host (nxdomain) — the network was likely not ready

      %Finch.TransportError{reason: :nxdomain, source: ...}

  The dashboard and notifier render only the first paragraph; the
  per-job page shows the whole thing.
  """

  @posix_errnos ~w(enoent eacces enospc eisdir enotdir emfile eexist ebadf ebusy efbig eio eperm erofs)a

  @doc """
  Returns the full stored form: friendly summary + blank line + raw
  inspect.
  """
  @spec format(term()) :: String.t()
  def format(reason) do
    summary = summarize(reason)
    detail = inspect(reason, pretty: true, limit: :infinity, printable_limit: 2048)

    "#{summary}\n\n#{detail}"
  end

  @doc "Returns a one-line human summary of the error term."
  @spec summarize(term()) :: String.t()

  # Network transport errors (from Finch / Mint, surfaced by Req in the S3 driver).
  def summarize(%Finch.TransportError{reason: reason}), do: network_message(reason)
  def summarize(%Mint.TransportError{reason: reason}), do: network_message(reason)

  def summarize(%Finch.HTTPError{reason: reason}),
    do: "HTTP protocol error from the storage host (#{inspect(reason)})"

  def summarize({:network, reason}), do: network_message(reason)

  # S3-shaped errors from Fae.Storage.Drivers.S3.
  def summarize({:s3_error, status, _body}), do: http_status_message(status)

  # Packager errors.
  def summarize(:folder_requires_tar_gz),
    do: "Folder sources can only be packaged as tar.gz"

  def summarize({:tar_failed, exit_code, output}),
    do: "tar exited with code #{exit_code}" <> first_line(output)

  def summarize({:unsupported_packaging, kind, format}),
    do: "Source kind '#{kind}' cannot be packaged as '#{format}'"

  # Source-adapter errors.
  def summarize({:unknown_source_kind, kind}),
    do: "Unknown source kind '#{kind}'"

  def summarize({:not_a_directory, type}),
    do: "Source path is not a directory (got #{type})"

  def summarize({:not_a_regular_file, type}),
    do: "Source path is not a regular file (got #{type})"

  def summarize({:stat, reason}), do: file_message(reason, "the source path")

  # Bare timeouts and POSIX errnos.
  def summarize(:timeout), do: "Operation timed out"
  def summarize({:timeout, what}), do: "Timed out: #{inspect(what)}"

  def summarize(reason) when reason in @posix_errnos,
    do: file_message(reason, "the source")

  # Fallbacks.
  def summarize(reason) when is_atom(reason), do: "Backup failed: #{reason}"
  def summarize(other), do: "Backup failed: #{inspect(other, limit: 5, printable_limit: 200)}"

  defp network_message(:nxdomain),
    do: "DNS lookup failed for the storage host (nxdomain) — the network was likely not ready"

  defp network_message(:econnrefused),
    do: "Storage host refused the connection (econnrefused)"

  defp network_message(:ehostunreach),
    do: "No route to the storage host (ehostunreach)"

  defp network_message(:enetunreach),
    do: "Network is unreachable (enetunreach)"

  defp network_message(:timeout),
    do: "Timed out reaching the storage host"

  defp network_message(:etimedout),
    do: "Connection timed out (etimedout)"

  defp network_message(:closed),
    do: "Connection closed by the storage host"

  defp network_message(:econnreset),
    do: "Storage host reset the connection (econnreset)"

  defp network_message(:tls_alert),
    do: "TLS handshake failed with the storage host"

  defp network_message({:tls_alert, _} = reason),
    do: "TLS handshake failed with the storage host (#{inspect(reason)})"

  defp network_message(reason),
    do: "Network error reaching the storage host (#{inspect(reason)})"

  defp http_status_message(401),
    do: "Storage rejected the credentials (401 Unauthorized)"

  defp http_status_message(403),
    do: "Storage denied access (403 Forbidden) — check bucket policy and credentials"

  defp http_status_message(404),
    do: "Storage bucket or path not found (404)"

  defp http_status_message(429),
    do: "Storage rate-limited the request (429) — will be retried"

  defp http_status_message(status) when status >= 500,
    do: "Storage server error (#{status}) — will be retried"

  defp http_status_message(status),
    do: "Storage rejected the request (HTTP #{status})"

  defp file_message(:enoent, what), do: "Couldn't find #{what} (enoent)"
  defp file_message(:eacces, what), do: "Permission denied reading #{what} (eacces)"
  defp file_message(:eperm, what), do: "Permission denied on #{what} (eperm)"
  defp file_message(:enospc, _what), do: "Disk full (enospc)"
  defp file_message(:eisdir, what), do: "#{what} is a directory, expected a file (eisdir)"
  defp file_message(:enotdir, what), do: "#{what} is not a directory (enotdir)"
  defp file_message(:eexist, what), do: "#{what} already exists (eexist)"
  defp file_message(:emfile, _what), do: "Too many open files (emfile)"
  defp file_message(:erofs, what), do: "#{what} is on a read-only filesystem (erofs)"
  defp file_message(:eio, what), do: "I/O error reading #{what} (eio)"
  defp file_message(reason, what), do: "Couldn't access #{what} (#{reason})"

  defp first_line(""), do: ""
  defp first_line(nil), do: ""

  defp first_line(text) when is_binary(text) do
    case String.split(text, "\n", parts: 2) do
      [first | _] ->
        snippet = first |> String.trim() |> String.slice(0, 200)
        if snippet == "", do: "", else: ": " <> snippet

      _ ->
        ""
    end
  end

  defp first_line(_), do: ""
end
