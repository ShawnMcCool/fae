defmodule Fae.Backups.RunPipelineTest do
  use Fae.DataCase, async: false

  import Mox

  alias Fae.Storage.Drivers.DriverMock
  alias Fae.Backups.{Jobs, Runs, RunPipeline}
  alias Fae.Storage.Destinations

  setup :verify_on_exit!

  setup do
    Application.put_env(:fae, :storage_drivers, %{"s3" => DriverMock})
    on_exit(fn -> Application.delete_env(:fae, :storage_drivers) end)

    {:ok, destination} =
      Destinations.create(%{
        name: "Test #{System.unique_integer()}",
        driver: "s3",
        endpoint_url: "https://example.com",
        region: "us",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: "s"
      })

    %{destination: destination}
  end

  defp tmp_file(content) do
    path = Path.join(System.tmp_dir!(), "fae-test-#{Ecto.UUID.generate()}.txt")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp create_job(destination, overrides \\ %{}) do
    base = %{
      name: "Test",
      slug: "test-#{System.unique_integer([:positive])}",
      source_kind: "file",
      source_path: tmp_file("hello"),
      destination_id: destination.id,
      prefix: "",
      package_format: "as_is",
      recurrence_kind: "daily",
      time_of_day: "03:00",
      retention_strategy: "keep_last_n",
      retention_params: %{"n" => 5}
    }

    {:ok, job} = Jobs.create(Map.merge(base, overrides))
    Jobs.get!(job.id)
  end

  describe "successful run" do
    test "uploads via the streaming (multipart-capable) driver path, not in-memory put", %{
      destination: destination
    } do
      job = create_job(destination)

      DriverMock
      |> expect(:put_stream, fn ^destination, key, upload_path, opts ->
        assert String.starts_with?(key, "#{job.slug}/")
        assert File.read!(upload_path) == "hello"
        assert is_list(opts)
        {:ok, %{byte_size: 5, sha256: "abc123", etag: "\"e\""}}
      end)
      |> expect(:list, fn _dest, _prefix -> {:ok, []} end)

      assert {:ok, finished} = RunPipeline.run(job)
      assert finished.status == "success"
      assert finished.byte_size == 5
      assert finished.sha256 == "abc123"
    end

    test "records success, builds expected object key, broadcasts events", %{
      destination: destination
    } do
      job = create_job(destination)

      DriverMock
      |> expect(:put_stream, fn ^destination, key, upload_path, _opts ->
        assert String.starts_with?(key, "#{job.slug}/")
        assert String.ends_with?(key, ".txt")
        assert File.read!(upload_path) == "hello"
        {:ok, %{byte_size: 5, sha256: "abc123"}}
      end)
      |> expect(:list, fn ^destination, prefix ->
        assert prefix == "#{job.slug}/"
        {:ok, []}
      end)

      Fae.Backups.subscribe_runs()
      assert {:ok, finished} = RunPipeline.run(job)

      assert finished.status == "success"
      assert finished.byte_size == 5
      assert finished.sha256 == "abc123"
      assert String.starts_with?(finished.object_key, "#{job.slug}/")

      assert_received {:run_started, _id}
      assert_received {:run_finished, _id, :success, %{object_key: _, byte_size: 5}}
    end

    test "applies destination prefix to object key", %{destination: destination} do
      {:ok, destination} = Destinations.update(destination, %{name: destination.name})
      # Use a fresh job whose destination has a prefix; emulate prefix via job.prefix? No,
      # design says destination.prefix exists. Looking at the schema — `prefix` lives on Job.
      job = create_job(destination, %{prefix: "vault"})

      DriverMock
      |> expect(:put_stream, fn _dest, key, _path, _opts ->
        assert String.starts_with?(key, "vault/#{job.slug}/")
        {:ok, %{byte_size: 5, sha256: "x"}}
      end)
      |> expect(:list, fn _dest, prefix ->
        assert prefix == "vault/#{job.slug}/"
        {:ok, []}
      end)

      assert {:ok, _} = RunPipeline.run(job)
    end

    test "applies destination.path_prefix to object key", %{destination: destination} do
      {:ok, destination} =
        Destinations.update(destination, %{path_prefix: "fae/shawn"})

      job = create_job(destination)

      DriverMock
      |> expect(:put_stream, fn _dest, key, _path, _opts ->
        assert String.starts_with?(key, "fae/shawn/#{job.slug}/")
        {:ok, %{byte_size: 5, sha256: "x"}}
      end)
      |> expect(:list, fn _dest, prefix ->
        assert prefix == "fae/shawn/#{job.slug}/"
        {:ok, []}
      end)

      assert {:ok, _} = RunPipeline.run(job)
    end

    test "stacks destination.path_prefix with job.prefix", %{destination: destination} do
      {:ok, destination} =
        Destinations.update(destination, %{path_prefix: "fae/shawn"})

      job = create_job(destination, %{prefix: "databases"})

      DriverMock
      |> expect(:put_stream, fn _dest, key, _path, _opts ->
        assert String.starts_with?(key, "fae/shawn/databases/#{job.slug}/")
        {:ok, %{byte_size: 5, sha256: "x"}}
      end)
      |> expect(:list, fn _dest, prefix ->
        assert prefix == "fae/shawn/databases/#{job.slug}/"
        {:ok, []}
      end)

      assert {:ok, _} = RunPipeline.run(job)
    end

    test "uses tar.gz extension when package_format is tar_gz", %{destination: destination} do
      job = create_job(destination, %{package_format: "tar_gz"})

      DriverMock
      |> expect(:put_stream, fn _dest, key, _path, _opts ->
        assert String.ends_with?(key, ".tar.gz")
        {:ok, %{byte_size: 12, sha256: "x"}}
      end)
      |> expect(:list, fn _dest, _prefix -> {:ok, []} end)

      assert {:ok, _} = RunPipeline.run(job)
    end

    test "drops obsolete objects per keep_last_n", %{destination: destination} do
      job = create_job(destination, %{retention_params: %{"n" => 1}})

      old_objects = [
        %{
          key: "#{job.slug}/20260514T030000Z.txt",
          last_modified: ~U[2026-05-14 03:00:00Z],
          size: 5
        },
        %{
          key: "#{job.slug}/20260515T030000Z.txt",
          last_modified: ~U[2026-05-15 03:00:00Z],
          size: 5
        }
      ]

      test_pid = self()

      DriverMock
      |> expect(:put_stream, fn _dest, _key, _path, _opts ->
        {:ok, %{byte_size: 5, sha256: "x"}}
      end)
      |> expect(:list, fn _dest, _prefix -> {:ok, old_objects} end)
      |> expect(:delete, fn _dest, key ->
        send(test_pid, {:deleted, key})
        :ok
      end)

      assert {:ok, _} = RunPipeline.run(job)
      assert_received {:deleted, deleted_key}
      assert deleted_key == "#{job.slug}/20260514T030000Z.txt"
    end
  end

  describe "failure paths" do
    test "marks run failed when driver.put returns error", %{destination: destination} do
      job = create_job(destination)

      DriverMock
      |> expect(:put_stream, fn _dest, _key, _path, _opts -> {:error, :boom} end)

      Fae.Backups.subscribe_runs()
      assert {:failed, :boom} = RunPipeline.run(job)

      assert_received {:run_started, _}
      assert_received {:run_finished, _id, :failed, :boom}

      [run] = Runs.list_recent(job.id, 10)
      assert run.status == "failed"
      assert run.error_message =~ "boom"
    end

    test "marks run failed when source is missing", %{destination: destination} do
      job = create_job(destination, %{source_path: "/nonexistent/path/here"})

      Fae.Backups.subscribe_runs()
      assert {:failed, _} = RunPipeline.run(job)

      [run] = Runs.list_recent(job.id, 10)
      assert run.status == "failed"
      assert run.error_message =~ "enoent"
    end
  end

  describe "transient error handling" do
    test "snoozes when last_attempt? is false and error is transient", %{
      destination: destination
    } do
      job = create_job(destination)
      transport_error = %Finch.TransportError{reason: :nxdomain}

      DriverMock
      |> expect(:put_stream, fn _dest, _key, _path, _opts -> {:error, transport_error} end)

      Fae.Backups.subscribe_runs()
      assert {:snoozed, ^transport_error} = RunPipeline.run(job, last_attempt?: false)

      assert_received {:run_started, _}
      assert_received {:run_finished, _id, :snoozed, ^transport_error}

      [run] = Runs.list_recent(job.id, 10)
      assert run.status == "snoozed"
      assert run.error_message =~ "nxdomain"
    end

    test "fails when last_attempt? is true even if error is transient", %{
      destination: destination
    } do
      job = create_job(destination)
      transport_error = %Finch.TransportError{reason: :nxdomain}

      DriverMock
      |> expect(:put_stream, fn _dest, _key, _path, _opts -> {:error, transport_error} end)

      Fae.Backups.subscribe_runs()
      assert {:failed, ^transport_error} = RunPipeline.run(job, last_attempt?: true)

      assert_received {:run_finished, _id, :failed, ^transport_error}

      [run] = Runs.list_recent(job.id, 10)
      assert run.status == "failed"
    end

    test "fails (no snooze) when error is permanent even with attempts remaining", %{
      destination: destination
    } do
      job = create_job(destination)
      permanent_error = {:s3_error, 403, "Forbidden"}

      DriverMock
      |> expect(:put_stream, fn _dest, _key, _path, _opts -> {:error, permanent_error} end)

      assert {:failed, ^permanent_error} = RunPipeline.run(job, last_attempt?: false)

      [run] = Runs.list_recent(job.id, 10)
      assert run.status == "failed"
    end
  end

  describe "classify_error/1" do
    test "transport, http, timeout, and 5xx/429 are transient" do
      assert RunPipeline.classify_error(%Finch.TransportError{reason: :nxdomain}) == :transient
      assert RunPipeline.classify_error(%Mint.TransportError{reason: :closed}) == :transient

      assert RunPipeline.classify_error(%Finch.HTTPError{reason: :closed}) == :transient

      assert RunPipeline.classify_error(:timeout) == :transient
      assert RunPipeline.classify_error({:timeout, :upload}) == :transient
      assert RunPipeline.classify_error({:network, :econnrefused}) == :transient
      assert RunPipeline.classify_error({:s3_error, 500, ""}) == :transient
      assert RunPipeline.classify_error({:s3_error, 503, ""}) == :transient
      assert RunPipeline.classify_error({:s3_error, 429, ""}) == :transient
    end

    test "auth/missing/4xx and unknown atoms are permanent" do
      assert RunPipeline.classify_error({:s3_error, 403, ""}) == :permanent
      assert RunPipeline.classify_error({:s3_error, 404, ""}) == :permanent
      assert RunPipeline.classify_error({:s3_error, 400, ""}) == :permanent
      assert RunPipeline.classify_error(:enoent) == :permanent
      assert RunPipeline.classify_error(:unauthorized) == :permanent
      assert RunPipeline.classify_error(:boom) == :permanent
    end
  end
end
