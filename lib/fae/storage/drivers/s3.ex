defmodule Fae.Storage.Drivers.S3 do
  @moduledoc """
  S3-compatible driver. Works against AWS S3, Hetzner Object Storage,
  MinIO, etc. Set `force_path_style: true` on the `Destination` for
  Hetzner.

  ## Uploads

    * `put_stream/4` is the only upload path (used by both Backups and
      Archive). It streams the file in bounded parts (single PUT at or
      below the part size, S3 multipart above it), sends a per-part
      `Content-MD5` the provider validates, folds a whole-file SHA256
      while streaming, and HEAD-checks the stored size. Memory stays
      flat regardless of file size, so it handles arbitrarily large
      files — multi-GB SQLite DBs included.

  ## Other notes

    * `list/2` paginates internally via `ContinuationToken`, so the
      caller sees the full set in one response regardless of how
      many objects exist under the prefix.
  """
  @behaviour Fae.Storage.Drivers.Driver

  alias Fae.Storage.Destination

  # 64 MiB parts: large enough to keep the request count low on
  # multi-GB files, small enough that peak memory (part size × upload
  # concurrency) stays modest. Comfortably above S3's 5 MiB minimum
  # for non-final parts.
  @default_part_size_bytes 64 * 1024 * 1024

  # Per-request receive timeout for the part-carrying PUTs. Req/Finch
  # default to 15s, which a single multi-GB or even a 64 MiB part can't
  # finish on a home uplink — the provider only responds once it has
  # received the whole part, so this must cover a full part transfer at
  # a slow upload speed. 10 minutes covers a 64 MiB part down to roughly
  # 1 Mbit/s.
  @upload_receive_timeout_ms 10 * 60 * 1000

  @impl true
  def put_stream(%Destination{} = dest, key, source_path, opts) do
    part_size = Keyword.get(opts, :part_size_bytes, @default_part_size_bytes)
    byte_size = File.stat!(source_path).size

    if byte_size <= part_size do
      put_single(dest, key, source_path, byte_size)
    else
      put_multipart(dest, key, source_path, part_size, byte_size)
    end
  end

  # Small files: one PUT carrying a Content-MD5 the provider validates,
  # then a HEAD to confirm the stored size.
  defp put_single(dest, key, source_path, byte_size) do
    body = File.read!(source_path)
    sha256 = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    url = object_url(dest, key)
    headers = base_headers(url) ++ [{"content-md5", content_md5(body)}]
    signed = sign(dest, "PUT", url, headers, body)

    with {:ok, %Req.Response{status: status, headers: resp_headers}}
         when status in 200..299 <-
           Req.put(url, body: body, headers: signed, receive_timeout: @upload_receive_timeout_ms),
         {:ok, ^byte_size} <- head_object_size(dest, key) do
      {:ok, %{byte_size: byte_size, sha256: sha256, etag: header(resp_headers, "etag")}}
    else
      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:s3_error, status, response_body}}

      {:ok, actual} when is_integer(actual) ->
        {:error, {:size_mismatch, byte_size, actual}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Large files: S3 multipart. Abort the upload on any failure so we
  # don't leave (billable) orphaned parts behind.
  defp put_multipart(dest, key, source_path, part_size, byte_size) do
    case create_multipart(dest, key) do
      {:ok, upload_id} ->
        finish_multipart(dest, key, source_path, part_size, byte_size, upload_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_multipart(dest, key, source_path, part_size, byte_size, upload_id) do
    result =
      with {:ok, {parts, sha256}} <- stream_parts(dest, key, source_path, part_size, upload_id),
           {:ok, etag} <- complete_multipart(dest, key, upload_id, parts),
           {:ok, ^byte_size} <- head_object_size(dest, key) do
        {:ok, %{byte_size: byte_size, sha256: sha256, etag: etag}}
      else
        {:ok, actual} when is_integer(actual) ->
          {:error, {:size_mismatch, byte_size, actual}}

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      {:ok, _} = ok ->
        ok

      {:error, _} = error ->
        _ = abort_multipart(dest, key, upload_id)
        error
    end
  end

  defp stream_parts(dest, key, source_path, part_size, upload_id) do
    opened =
      File.open(source_path, [:read, :binary, :raw], fn fd ->
        read_parts(fd, dest, key, upload_id, part_size, 1, [], :crypto.hash_init(:sha256))
      end)

    case opened do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:open, reason}}
    end
  end

  defp read_parts(fd, dest, key, upload_id, part_size, part_number, parts, sha_ctx) do
    case :file.read(fd, part_size) do
      {:ok, data} ->
        case upload_part(dest, key, upload_id, part_number, data) do
          {:ok, etag} ->
            read_parts(
              fd,
              dest,
              key,
              upload_id,
              part_size,
              part_number + 1,
              [{part_number, etag} | parts],
              :crypto.hash_update(sha_ctx, data)
            )

          {:error, reason} ->
            {:error, reason}
        end

      :eof ->
        sha256 = sha_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
        {:ok, {Enum.reverse(parts), sha256}}

      {:error, reason} ->
        {:error, {:read, reason}}
    end
  end

  defp create_multipart(dest, key) do
    url = object_url(dest, key) <> "?uploads"
    signed = sign(dest, "POST", url, base_headers(url), "")

    case Req.post(url, body: "", headers: signed) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case parse_upload_id(body) do
          nil -> {:error, {:malformed_response, body}}
          upload_id -> {:ok, upload_id}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:s3_error, status, body}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp upload_part(dest, key, upload_id, part_number, data) do
    query = encode_query([{"partNumber", part_number}, {"uploadId", upload_id}])
    url = object_url(dest, key) <> "?" <> query
    headers = base_headers(url) ++ [{"content-md5", content_md5(data)}]
    signed = sign(dest, "PUT", url, headers, data)

    case Req.put(url, body: data, headers: signed, receive_timeout: @upload_receive_timeout_ms) do
      {:ok, %Req.Response{status: 200, headers: resp_headers}} ->
        case header(resp_headers, "etag") do
          nil -> {:error, :missing_part_etag}
          etag -> {:ok, etag}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:s3_error, status, body}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp complete_multipart(dest, key, upload_id, parts) do
    query = encode_query([{"uploadId", upload_id}])
    url = object_url(dest, key) <> "?" <> query
    body = build_complete_xml(parts)
    headers = base_headers(url) ++ [{"content-type", "application/xml"}]
    signed = sign(dest, "POST", url, headers, body)

    case Req.post(url, body: body, headers: signed) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        # S3 can return 200 with an <Error> body on a failed completion.
        if String.contains?(response_body, "<Error>") do
          {:error, {:s3_error, 200, response_body}}
        else
          {:ok, parse_complete_etag(response_body)}
        end

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:s3_error, status, response_body}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp abort_multipart(dest, key, upload_id) do
    query = encode_query([{"uploadId", upload_id}])
    url = object_url(dest, key) <> "?" <> query
    signed = sign(dest, "DELETE", url, base_headers(url), "")
    Req.delete(url, headers: signed)
  end

  # Post-upload integrity backstop: confirm the provider stored exactly
  # the byte count we streamed.
  defp head_object_size(dest, key) do
    url = object_url(dest, key)
    signed = sign(dest, "HEAD", url, base_headers(url), "")

    case Req.head(url, headers: signed) do
      {:ok, %Req.Response{status: 200, headers: resp_headers}} ->
        case header(resp_headers, "content-length") do
          nil -> {:error, :missing_content_length}
          value -> {:ok, String.to_integer(value)}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:s3_error, status, body}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp content_md5(data), do: :crypto.hash(:md5, data) |> Base.encode64()

  @impl true
  def list(%Destination{} = dest, prefix) do
    list_paginated(dest, prefix, nil, [])
  end

  @impl true
  def list_prefixes(%Destination{} = dest, prefix) do
    list_prefixes_paginated(dest, prefix, nil, [], [])
  end

  defp list_prefixes_paginated(dest, prefix, continuation, prefixes, files) do
    base = "#{bucket_url(dest)}/"

    params =
      [{"list-type", "2"}, {"delimiter", "/"}, {"prefix", prefix}]
      |> add_continuation(continuation)

    url = "#{base}?#{encode_query(params)}"
    signed = sign(dest, "GET", url, base_headers(url), "")

    case Req.get(url, headers: signed) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {page_prefixes, page_files, next_token} = parse_prefixes(body)
        prefixes = prefixes ++ page_prefixes
        files = files ++ page_files

        if next_token do
          list_prefixes_paginated(dest, prefix, next_token, prefixes, files)
        else
          {:ok, %{prefixes: prefixes, files: files}}
        end

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:s3_error, status, response_body}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
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

    query = encode_query(params)
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
    |> Enum.map(&uri_escape/1)
    |> Enum.join("/")
  end

  # RFC 3986 percent-encoding of a single component (everything but the
  # unreserved set). Used for both object-key path segments and query
  # values so they match the SigV4 canonical request S3 recomputes.
  defp uri_escape(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # SigV4-correct query encoding. Unlike URI.encode_query/1 (which is
  # x-www-form-urlencoded — space becomes "+"), this percent-encodes per
  # RFC 3986, so the query we send canonicalizes identically on S3's side.
  defp encode_query(params) do
    params
    |> Enum.map(fn {key, value} ->
      uri_escape(to_string(key)) <> "=" <> uri_escape(to_string(value))
    end)
    |> Enum.join("&")
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

    # `object_url/2` already percent-encodes each key segment per the
    # SigV4/S3 canonical rules (everything but unreserved chars + "/"),
    # so we pass `uri_encode_path: false` to stop aws_signature from
    # encoding a second time — otherwise keys containing spaces or
    # parentheses (e.g. "Family Backups (IMPORTANT)/…") double-encode
    # and the signature fails to match.
    :aws_signature.sign_v4(
      dest.access_key_id,
      dest.secret_access_key,
      dest.region,
      "s3",
      datetime,
      method,
      url,
      headers,
      body,
      uri_encode_path: false
    )
  end

  @doc false
  def parse_upload_id(xml) when is_binary(xml) do
    case Regex.run(~r{<UploadId>(.*?)</UploadId>}s, xml) do
      [_, upload_id] -> upload_id
      _ -> nil
    end
  end

  @doc false
  def parse_complete_etag(xml) when is_binary(xml) do
    case Regex.run(~r{<ETag>(.*?)</ETag>}s, xml) do
      [_, etag] -> etag
      _ -> nil
    end
  end

  @doc false
  def build_complete_xml(parts) do
    body =
      parts
      |> Enum.map(fn {part_number, etag} ->
        "<Part><PartNumber>#{part_number}</PartNumber><ETag>#{etag}</ETag></Part>"
      end)
      |> Enum.join()

    "<CompleteMultipartUpload>#{body}</CompleteMultipartUpload>"
  end

  # One-level (delimiter=/) listing: CommonPrefixes are the sub-folders,
  # Contents are the files at this level (with size + last-modified).
  @doc false
  def parse_prefixes(xml) when is_binary(xml) do
    prefixes =
      ~r{<CommonPrefixes>.*?<Prefix>(.*?)</Prefix>.*?</CommonPrefixes>}s
      |> Regex.scan(xml, capture: :all_but_first)
      |> Enum.map(fn [prefix] -> prefix end)

    files =
      ~r{<Contents>(.*?)</Contents>}s
      |> Regex.scan(xml, capture: :all_but_first)
      |> Enum.map(fn [content] ->
        %{
          key: extract(content, "Key"),
          size: extract(content, "Size") |> String.to_integer(),
          last_modified: parse_datetime(extract(content, "LastModified"))
        }
      end)

    next_token =
      case Regex.run(~r{<NextContinuationToken>(.*?)</NextContinuationToken>}s, xml) do
        [_, token] -> token
        _ -> nil
      end

    {prefixes, files, next_token}
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
