defmodule Fae.Backups.Drivers.S3 do
  @moduledoc """
  S3-compatible driver. Works against AWS S3, Hetzner Object Storage,
  MinIO, etc. Set `force_path_style: true` on the `Destination` for
  Hetzner.

  ## Limits (v1)

    * In-memory upload — `File.read!/1` loads the whole file before
      signing and PUTting. Fine for SQLite DBs and modest folders;
      large multi-GB tarballs would benefit from streaming /
      multipart upload (deferred to v2).
    * `list/2` paginates internally via `ContinuationToken`, so the
      caller sees the full set in one response regardless of how
      many objects exist under the prefix.
  """
  @behaviour Fae.Backups.Drivers.Driver

  alias Fae.Backups.Destination

  @impl true
  def put(%Destination{} = dest, key, source_path) do
    body = File.read!(source_path)
    byte_size = byte_size(body)
    sha256 = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    url = object_url(dest, key)
    headers = base_headers(url)
    signed = sign(dest, "PUT", url, headers, body)

    case Req.put(url, body: body, headers: signed) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, %{byte_size: byte_size, sha256: sha256}}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:s3_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list(%Destination{} = dest, prefix) do
    list_paginated(dest, prefix, nil, [])
  end

  @impl true
  def verify(%Destination{} = dest) do
    url = bucket_url(dest)
    headers = base_headers(url)
    signed = sign(dest, "HEAD", url, headers, "")

    case Req.head(url, headers: signed) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: 301, headers: resp_headers}} ->
        {:error, {:wrong_region, header(resp_headers, "x-amz-bucket-region")}}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 403}} ->
        {:error, :forbidden}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :no_bucket}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:s3_error, status, response_body}}

      {:error, %{reason: reason}} ->
        {:error, {:network, reason}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp header(headers, name) when is_list(headers) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      _ -> nil
    end
  end

  @impl true
  def delete(%Destination{} = dest, key) do
    url = object_url(dest, key)
    headers = base_headers(url)
    signed = sign(dest, "DELETE", url, headers, "")

    case Req.delete(url, headers: signed) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:s3_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_paginated(dest, prefix, continuation, acc) do
    base = "#{bucket_url(dest)}/"

    params =
      [{"list-type", "2"}, {"prefix", prefix}]
      |> add_continuation(continuation)

    query = URI.encode_query(params)
    url = "#{base}?#{query}"

    headers = base_headers(url)
    signed = sign(dest, "GET", url, headers, "")

    case Req.get(url, headers: signed) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {objects, next_token} = parse_list(body)
        accumulated = acc ++ objects

        if next_token do
          list_paginated(dest, prefix, next_token, accumulated)
        else
          {:ok, accumulated}
        end

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:s3_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp add_continuation(params, nil), do: params
  defp add_continuation(params, token), do: [{"continuation-token", token} | params]

  # URL construction
  #
  # Path-style:    <endpoint>/<bucket>/<key>
  # Virtual-host:  <bucket>.<endpoint-host>/<key>
  #
  # Hetzner requires path-style; AWS supports both. Keys are
  # URL-encoded but slashes are preserved as path separators.
  defp object_url(%Destination{} = dest, key) do
    encoded_key = encode_object_key(key)
    "#{bucket_url(dest)}/#{encoded_key}"
  end

  defp bucket_url(%Destination{force_path_style: true} = dest) do
    "#{normalize_endpoint(dest)}/#{dest.bucket}"
  end

  defp bucket_url(%Destination{force_path_style: false} = dest) do
    uri = URI.parse(normalize_endpoint(dest))
    port_part = if uri.port in [nil, 80, 443], do: "", else: ":#{uri.port}"
    "#{uri.scheme}://#{dest.bucket}.#{uri.host}#{port_part}"
  end

  defp normalize_endpoint(%Destination{endpoint_url: url}) do
    String.trim_trailing(url, "/")
  end

  defp encode_object_key(key) do
    key
    |> String.split("/")
    |> Enum.map(fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
    |> Enum.join("/")
  end

  defp base_headers(url) do
    %URI{host: host, port: port, scheme: scheme} = URI.parse(url)

    host_header =
      if port in [nil, 80, 443] or port == default_port(scheme), do: host, else: "#{host}:#{port}"

    [{"host", host_header}]
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port(_), do: nil

  defp sign(%Destination{} = dest, method, url, headers, body) do
    datetime = :calendar.universal_time()

    :aws_signature.sign_v4(
      dest.access_key_id,
      dest.secret_access_key,
      dest.region,
      "s3",
      datetime,
      method,
      url,
      headers,
      body
    )
  end

  # S3 ListObjectsV2 XML parsing. The output schema is stable; using
  # regex avoids pulling in an XML library for the few fields we need
  # (Contents/Key/LastModified/Size + NextContinuationToken).
  @doc false
  def parse_list(xml) when is_binary(xml) do
    objects =
      ~r{<Contents>(.*?)</Contents>}s
      |> Regex.scan(xml, capture: :all_but_first)
      |> Enum.map(fn [content] ->
        %{
          key: extract(content, "Key"),
          last_modified: parse_datetime(extract(content, "LastModified")),
          size: extract(content, "Size") |> String.to_integer()
        }
      end)

    next_token =
      case Regex.run(~r{<NextContinuationToken>(.*?)</NextContinuationToken>}s, xml) do
        [_, token] -> token
        _ -> nil
      end

    {objects, next_token}
  end

  defp extract(xml, tag) do
    [_, content] = Regex.run(~r{<#{tag}>(.*?)</#{tag}>}s, xml)
    content
  end

  defp parse_datetime(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end
end
