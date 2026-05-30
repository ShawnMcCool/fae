defmodule Fae.Backups.RunWorkerTest do
  use Fae.DataCase, async: false
  use Oban.Testing, repo: Fae.Repo

  import Mox

  alias Fae.Storage.Drivers.DriverMock
  alias Fae.Backups.{Jobs, RunRegistry, Runs, RunWorker}
  alias Fae.Storage.Destinations

  setup :verify_on_exit!
  setup :set_mox_global

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

    src = Path.join(System.tmp_dir!(), "fae-test-#{Ecto.UUID.generate()}.txt")
    File.write!(src, "hello")
    on_exit(fn -> File.rm(src) end)

    {:ok, job} =
      Jobs.create(%{
        name: "Test",
        slug: "test-#{System.unique_integer([:positive])}",
        source_kind: "file",
        source_path: src,
        destination_id: destination.id,
        prefix: "",
        package_format: "as_is",
        recurrence_kind: "daily",
        time_of_day: "03:00",
        retention_strategy: "keep_last_n",
        retention_params: %{"n" => 5}
      })

    %{job: job}
  end

  describe "manual kind" do
    test "runs the pipeline and records success", %{job: job} do
      DriverMock
      |> expect(:put_stream, fn _dest, _key, _path, _opts -> {:ok, %{byte_size: 5, sha256: "x"}} end)
      |> expect(:list, fn _dest, _prefix -> {:ok, []} end)

      assert :ok = perform_job(RunWorker, %{"job_id" => job.id, "kind" => "manual"})

      [run] = Runs.list_recent(job.id, 10)
      assert run.status == "success"
    end
  end

  describe "skip-if-overlapping" do
    test "second concurrent perform writes a skipped row", %{job: job} do
      # Hold the lock from another process to simulate an in-flight run.
      parent = self()

      holder =
        spawn(fn ->
          :ok = RunRegistry.register(job.id)
          send(parent, :held)

          receive do
            :release -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive :held

      assert {:cancel, :overlap} =
               perform_job(RunWorker, %{"job_id" => job.id, "kind" => "manual"})

      [run] = Runs.list_recent(job.id, 10)
      assert run.status == "skipped"
      assert run.error_message =~ "overlap"

      send(holder, :release)
    end
  end

  describe "missing or disabled job" do
    test "cancels when the job no longer exists" do
      missing_id = Ecto.UUID.generate()

      assert {:cancel, :job_deleted} =
               perform_job(RunWorker, %{"job_id" => missing_id, "kind" => "manual"})
    end

    test "cancels when the job is disabled", %{job: job} do
      {:ok, _} = Jobs.update(job, %{enabled: false})

      assert {:cancel, :disabled} =
               perform_job(RunWorker, %{"job_id" => job.id, "kind" => "manual"})
    end
  end

  describe "retry behaviour" do
    test "transient error on non-final attempt returns {:error, _} and snoozes the row", %{
      job: job
    } do
      DriverMock
      |> expect(:put_stream, fn _dest, _key, _path, _opts ->
        {:error, %Finch.TransportError{reason: :nxdomain}}
      end)

      assert {:error, {:transient, %Finch.TransportError{reason: :nxdomain}}} =
               perform_job(RunWorker, %{"job_id" => job.id, "kind" => "manual"},
                 attempt: 1,
                 max_attempts: 5
               )

      [run] = Runs.list_recent(job.id, 10)
      assert run.status == "snoozed"
      assert run.error_message =~ "nxdomain"
    end

    test "transient error on final attempt cancels with failed row", %{job: job} do
      DriverMock
      |> expect(:put_stream, fn _dest, _key, _path, _opts ->
        {:error, %Finch.TransportError{reason: :nxdomain}}
      end)

      assert {:cancel, %Finch.TransportError{reason: :nxdomain}} =
               perform_job(RunWorker, %{"job_id" => job.id, "kind" => "manual"},
                 attempt: 5,
                 max_attempts: 5
               )

      [run] = Runs.list_recent(job.id, 10)
      assert run.status == "failed"
    end

    test "permanent error cancels immediately with failed row even mid-attempt-budget", %{
      job: job
    } do
      DriverMock
      |> expect(:put_stream, fn _dest, _key, _path, _opts -> {:error, {:s3_error, 403, "Forbidden"}} end)

      assert {:cancel, {:s3_error, 403, "Forbidden"}} =
               perform_job(RunWorker, %{"job_id" => job.id, "kind" => "manual"},
                 attempt: 1,
                 max_attempts: 5
               )

      [run] = Runs.list_recent(job.id, 10)
      assert run.status == "failed"
    end

    test "backoff schedule grows then plateaus" do
      assert RunWorker.backoff(%Oban.Job{attempt: 1}) == 30
      assert RunWorker.backoff(%Oban.Job{attempt: 2}) == 120
      assert RunWorker.backoff(%Oban.Job{attempt: 3}) == 600
      assert RunWorker.backoff(%Oban.Job{attempt: 4}) == 1800
      assert RunWorker.backoff(%Oban.Job{attempt: 5}) == 1800
    end
  end
end
