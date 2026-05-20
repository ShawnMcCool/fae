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

  describe "restage_overdue/0" do
    test "spaces overdue jobs 60s apart and leaves future-scheduled jobs alone" do
      with_manual_oban(fn ->
        dest = create_destination!()
        {:ok, job_a} = Jobs.create(job_attrs(dest))
        {:ok, job_b} = Jobs.create(job_attrs(dest))
        {:ok, job_future} = Jobs.create(job_attrs(dest))

        now = Fae.Clock.now()
        past_a = DateTime.add(now, -3600, :second)
        past_b = DateTime.add(now, -1800, :second)
        future = DateTime.add(now, 3600, :second)

        {:ok, _} =
          %{"job_id" => job_a.id, "kind" => "scheduled"}
          |> RunWorker.new(scheduled_at: past_a)
          |> Oban.insert()

        {:ok, _} =
          %{"job_id" => job_b.id, "kind" => "scheduled"}
          |> RunWorker.new(scheduled_at: past_b)
          |> Oban.insert()

        {:ok, _} =
          %{"job_id" => job_future.id, "kind" => "scheduled"}
          |> RunWorker.new(scheduled_at: future)
          |> Oban.insert()

        before_call = Fae.Clock.now()
        :ok = Scheduler.do_restage_overdue()

        restaged =
          all_enqueued(worker: RunWorker)
          |> Enum.filter(fn j ->
            j.args["job_id"] in [job_a.id, job_b.id]
          end)
          |> Enum.sort_by(& &1.scheduled_at, DateTime)

        assert length(restaged) == 2
        [first, second] = restaged

        assert DateTime.diff(first.scheduled_at, before_call, :second) >= 60
        assert DateTime.diff(first.scheduled_at, before_call, :second) <= 75
        assert DateTime.diff(second.scheduled_at, first.scheduled_at, :second) == 60

        # Future-scheduled untouched
        [untouched] =
          all_enqueued(worker: RunWorker)
          |> Enum.filter(fn j -> j.args["job_id"] == job_future.id end)

        assert DateTime.compare(untouched.scheduled_at, future) == :eq
      end)
    end

    test "is a no-op when nothing is overdue" do
      with_manual_oban(fn ->
        dest = create_destination!()
        {:ok, job} = Jobs.create(job_attrs(dest))

        future = DateTime.add(Fae.Clock.now(), 3600, :second)

        {:ok, _} =
          %{"job_id" => job.id, "kind" => "scheduled"}
          |> RunWorker.new(scheduled_at: future)
          |> Oban.insert()

        :ok = Scheduler.do_restage_overdue()

        [enqueued] =
          all_enqueued(worker: RunWorker)
          |> Enum.filter(fn j -> j.args["job_id"] == job.id end)

        assert DateTime.compare(enqueued.scheduled_at, future) == :eq
      end)
    end
  end
end
