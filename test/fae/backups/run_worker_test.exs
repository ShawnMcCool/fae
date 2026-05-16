defmodule Fae.Backups.RunWorkerTest do
  use Fae.DataCase, async: false
  use Oban.Testing, repo: Fae.Repo

  import Mox

  alias Fae.Backups.Drivers.DriverMock
  alias Fae.Backups.{Destinations, Jobs, RunRegistry, Runs, RunWorker}

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    Application.put_env(:fae, :backups_drivers, %{"s3" => DriverMock})
    on_exit(fn -> Application.delete_env(:fae, :backups_drivers) end)

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
      |> expect(:put, fn _dest, _key, _path -> {:ok, %{byte_size: 5, sha256: "x"}} end)
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
end
