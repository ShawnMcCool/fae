defmodule Fae.Backups.SchedulerTest do
  use Fae.DataCase, async: false
  use Oban.Testing, repo: Fae.Repo

  alias Fae.Backups.{Destinations, Jobs, RunWorker, Scheduler}

  # Oban testing mode is process-local (Process.put), so the assertions
  # must run in the same process as the Oban.insert call. We invoke
  # Scheduler.do_reconcile/1 directly in the test process; production
  # routes via the Scheduler GenServer's PubSub handler, which calls
  # the same function.
  defp with_manual_oban(test_fn) do
    Oban.Testing.with_testing_mode(:manual, test_fn)
  end

  defp create_destination! do
    {:ok, dest} =
      Destinations.create(%{
        name: "Test #{System.unique_integer()}",
        driver: "s3",
        endpoint_url: "https://example.com",
        region: "us",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: "s"
      })

    dest
  end

  defp job_attrs(destination, overrides \\ %{}) do
    Map.merge(
      %{
        name: "Test",
        slug: "test-#{System.unique_integer([:positive])}",
        source_kind: "file",
        source_path: "/tmp/x",
        destination_id: destination.id,
        package_format: "as_is",
        recurrence_kind: "daily",
        time_of_day: "03:00",
        retention_strategy: "keep_last_n",
        retention_params: %{"n" => 5}
      },
      overrides
    )
  end

  test "reconcile/1 inserts a scheduled RunWorker for an enabled job" do
    with_manual_oban(fn ->
      dest = create_destination!()
      {:ok, job} = Jobs.create(job_attrs(dest))

      Scheduler.do_reconcile(job.id)

      assert_enqueued(worker: RunWorker, args: %{"job_id" => job.id, "kind" => "scheduled"})
    end)
  end

  test "reconcile/1 is idempotent — repeated calls leave one queued worker" do
    with_manual_oban(fn ->
      dest = create_destination!()
      {:ok, job} = Jobs.create(job_attrs(dest))

      Scheduler.do_reconcile(job.id)
      Scheduler.do_reconcile(job.id)
      Scheduler.do_reconcile(job.id)

      jobs =
        all_enqueued(worker: RunWorker)
        |> Enum.filter(fn j -> j.args["job_id"] == job.id end)

      assert length(jobs) == 1
    end)
  end

  test "reconcile/1 with a disabled job cancels the queued worker" do
    with_manual_oban(fn ->
      dest = create_destination!()
      {:ok, job} = Jobs.create(job_attrs(dest))
      Scheduler.do_reconcile(job.id)
      assert_enqueued(worker: RunWorker, args: %{"job_id" => job.id})

      {:ok, disabled} = Jobs.update(job, %{enabled: false})
      Scheduler.do_reconcile(disabled.id)

      refute_enqueued(worker: RunWorker, args: %{"job_id" => job.id, "kind" => "scheduled"})
    end)
  end

  test "reconcile/1 with a missing job cancels any queued worker" do
    with_manual_oban(fn ->
      dest = create_destination!()
      {:ok, job} = Jobs.create(job_attrs(dest))
      Scheduler.do_reconcile(job.id)
      assert_enqueued(worker: RunWorker, args: %{"job_id" => job.id})

      {:ok, _} = Jobs.delete(job)
      Scheduler.do_reconcile(job.id)

      refute_enqueued(worker: RunWorker, args: %{"job_id" => job.id})
    end)
  end
end
