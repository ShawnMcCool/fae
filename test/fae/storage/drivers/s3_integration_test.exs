defmodule Fae.Storage.Drivers.S3IntegrationTest do
  @moduledoc """
  Exercises the real `put_stream/4` upload paths against a local MinIO
  — the provider-neutral S3 reference implementation. Excluded from the
  default hermetic suite; run with:

      mix test --include integration

  Expects MinIO reachable at `FAE_TEST_S3_ENDPOINT`
  (default `http://127.0.0.1:9100`) with creds minioadmin/minioadmin,
  e.g.:

      docker run -d --name fae-minio -p 9100:9000 \\
        -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \\
        minio/minio server /data
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Fae.Storage.Destination
  alias Fae.Storage.Drivers.S3

  @endpoint System.get_env("FAE_TEST_S3_ENDPOINT", "http://127.0.0.1:9100")
  @bucket "fae-archive-test"

  setup_all do
    dest = %Destination{
      driver: "s3",
      endpoint_url: @endpoint,
      region: "us-east-1",
      bucket: @bucket,
      force_path_style: true,
      access_key_id: System.get_env("FAE_TEST_S3_KEY", "minioadmin"),
      secret_access_key: System.get_env("FAE_TEST_S3_SECRET", "minioadmin"),
      path_prefix: ""
    }

    :ok = ensure_bucket(dest)
    {:ok, dest: dest}
  end

  @tag :tmp_dir
  test "single-PUT path round-trips a small file with a matching SHA256", %{
    dest: dest,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "small.bin")
    data = :crypto.strong_rand_bytes(1024)
    File.write!(path, data)
    expected_sha = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    assert {:ok, result} = S3.put_stream(dest, "test/single/small.bin", path, [])
    assert result.byte_size == byte_size(data)
    assert result.sha256 == expected_sha
    assert is_binary(result.etag) and result.etag != ""

    assert {:ok, objects} = S3.list(dest, "test/single/")
    assert Enum.any?(objects, &(&1.key == "test/single/small.bin" and &1.size == byte_size(data)))
  end

  @tag :tmp_dir
  test "multipart path round-trips a file larger than the part size", %{
    dest: dest,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "large.bin")
    # 6 MiB body with a 5 MiB part size -> 2 parts (5 MiB + 1 MiB),
    # exercising the multipart path while respecting S3's 5 MiB minimum
    # for non-final parts.
    part_size = 5 * 1024 * 1024
    data = :crypto.strong_rand_bytes(6 * 1024 * 1024)
    File.write!(path, data)
    expected_sha = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    assert {:ok, result} =
             S3.put_stream(dest, "test/multi/large.bin", path, part_size_bytes: part_size)

    assert result.byte_size == byte_size(data)
    assert result.sha256 == expected_sha
    assert is_binary(result.etag) and result.etag != ""

    assert {:ok, objects} = S3.list(dest, "test/multi/")
    assert Enum.any?(objects, &(&1.key == "test/multi/large.bin" and &1.size == byte_size(data)))
  end

  @tag :tmp_dir
  test "keys with spaces and parentheses survive encoding + signing", %{
    dest: dest,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "note.txt")
    File.write!(path, "hi")

    key =
      "Family Backups (IMPORTANT)/Pictures Videos/2004/2004-04-15 family reunion/note.txt"

    assert {:ok, result} = S3.put_stream(dest, key, path, [])
    assert result.byte_size == 2

    assert {:ok, objects} = S3.list(dest, "Family Backups (IMPORTANT)/")
    assert Enum.any?(objects, &(&1.key == key))
  end

  @tag :tmp_dir
  test "list_prefixes returns one level of folders and files", %{dest: dest, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "f")
    File.write!(path, "1")

    {:ok, _} = S3.put_stream(dest, "lp/top.txt", path, [])
    {:ok, _} = S3.put_stream(dest, "lp/a/x.txt", path, [])
    {:ok, _} = S3.put_stream(dest, "lp/a/b/y.txt", path, [])

    {:ok, %{prefixes: prefixes, files: files}} = S3.list_prefixes(dest, "lp/")
    assert "lp/a/" in prefixes
    assert Enum.any?(files, &(&1.key == "lp/top.txt"))
    # Nested entries are NOT flattened into this level.
    refute Enum.any?(files, &(&1.key == "lp/a/x.txt"))

    {:ok, %{prefixes: sub_prefixes}} = S3.list_prefixes(dest, "lp/a/")
    assert "lp/a/b/" in sub_prefixes
  end

  # CreateBucket via a signed PUT on the bucket URL. 409 means the
  # bucket already exists and is owned by us — fine to proceed.
  defp ensure_bucket(%Destination{} = dest) do
    url = "#{String.trim_trailing(dest.endpoint_url, "/")}/#{dest.bucket}"
    %URI{host: host, port: port} = URI.parse(url)
    host_header = if port in [nil, 80, 443], do: host, else: "#{host}:#{port}"
    headers = [{"host", host_header}]

    signed =
      :aws_signature.sign_v4(
        dest.access_key_id,
        dest.secret_access_key,
        dest.region,
        "s3",
        :calendar.universal_time(),
        "PUT",
        url,
        headers,
        ""
      )

    case Req.put(url, body: "", headers: signed) do
      {:ok, %Req.Response{status: status}} when status in [200, 409] -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
