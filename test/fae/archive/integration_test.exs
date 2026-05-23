defmodule Fae.Archive.IntegrationTest do
  @moduledoc """
  End-to-end archive against a local MinIO: the worker uses the REAL S3
  driver (no mock) to scan, upload, verify, and finalize, exercising the
  user's space-and-parenthesis key layout all the way to the bucket.

  Excluded by default; run with `mix test --include integration` and a
  MinIO at FAE_TEST_S3_ENDPOINT (default http://127.0.0.1:9100).
  """
  use Fae.DataCase, async: false
  use Oban.Testing, repo: Fae.Repo

  @moduletag :integration
  @moduletag :tmp_dir

  alias Fae.Archive.ArchiveWorker
  alias Fae.Archive.Items
  alias Fae.Archive.Runs
  alias Fae.Storage.Destination
  alias Fae.Storage.Destinations
  alias Fae.Storage.Drivers.S3

  @endpoint System.get_env("FAE_TEST_S3_ENDPOINT", "http://127.0.0.1:9100")
  @bucket "fae-archive-e2e"

  setup %{tmp_dir: tmp_dir} do
    {:ok, dest} =
      Destinations.create(%{
        name: "MinIO #{System.unique_integer([:positive])}",
        driver: "s3",
        endpoint_url: @endpoint,
        region: "us-east-1",
        bucket: @bucket,
        force_path_style: true,
        path_prefix: "Family Backups (IMPORTANT)",
        access_key_id: System.get_env("FAE_TEST_S3_KEY", "minioadmin"),
        secret_access_key: System.get_env("FAE_TEST_S3_SECRET", "minioadmin")
      })

    :ok = ensure_bucket(dest)

    File.mkdir_p!(Path.join(tmp_dir, "2004/2004-04-15 family reunion"))
    File.write!(Path.join(tmp_dir, "2004/2004-04-15 family reunion/note.txt"), "hello")
    big = :crypto.strong_rand_bytes(3 * 1024 * 1024)
    File.write!(Path.join(tmp_dir, "2004/big.bin"), big)

    {:ok, run} =
      Runs.create(%{
        name: "Pictures Videos",
        source_path: tmp_dir,
        label: "Pictures Videos",
        destination_id: dest.id
      })

    {:ok, run: run, dest: dest, big_sha: Base.encode16(:crypto.hash(:sha256, big), case: :lower)}
  end

  test "uploads the whole tree to MinIO and finalizes completed", %{
    run: run,
    dest: dest,
    big_sha: big_sha
  } do
    assert :ok = perform_job(ArchiveWorker, %{"run_id" => run.id})

    run = Runs.get(run.id)
    assert run.status == "completed"
    assert run.total_files == 2
    assert run.failed_files == 0

    items = Items.list_for_run(run.id)
    assert Enum.all?(items, &(&1.status == "uploaded"))

    big_item = Enum.find(items, &(&1.relative_path == "2004/big.bin"))
    assert big_item.sha256 == big_sha

    {:ok, objects} = S3.list(dest, "Family Backups (IMPORTANT)/Pictures Videos/")
    keys = Enum.map(objects, & &1.key)
    assert "Family Backups (IMPORTANT)/Pictures Videos/2004/big.bin" in keys

    assert "Family Backups (IMPORTANT)/Pictures Videos/2004/2004-04-15 family reunion/note.txt" in keys
  end

  defp ensure_bucket(%Destination{} = dest) do
    url = "#{String.trim_trailing(dest.endpoint_url, "/")}/#{dest.bucket}"
    %URI{host: host, port: port} = URI.parse(url)
    host_header = if port in [nil, 80, 443], do: host, else: "#{host}:#{port}"

    signed =
      :aws_signature.sign_v4(
        dest.access_key_id,
        dest.secret_access_key,
        dest.region,
        "s3",
        :calendar.universal_time(),
        "PUT",
        url,
        [{"host", host_header}],
        ""
      )

    case Req.put(url, body: "", headers: signed) do
      {:ok, %Req.Response{status: status}} when status in [200, 409] -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
