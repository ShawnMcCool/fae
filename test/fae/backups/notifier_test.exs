defmodule Fae.Backups.NotifierTest do
  use Fae.DataCase, async: false

  alias Fae.Backups.{Destinations, Jobs, Notifier, Runs}
  alias Fae.Topics

  setup do
    parent = self()

    runner = fn cmd, args ->
      send(parent, {:notify_cmd, cmd, args})
      {:ok, ""}
    end

    Application.put_env(:fae, :notify_runner, runner)

    on_exit(fn ->
      Application.delete_env(:fae, :notify_runner)
    end)

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

    {:ok, job} =
      Jobs.create(%{
        name: "Test Job",
        slug: "test-#{System.unique_integer([:positive])}",
        source_kind: "file",
        source_path: "/tmp/x",
        destination_id: destination.id,
        package_format: "as_is",
        recurrence_kind: "daily",
        time_of_day: "03:00",
        retention_strategy: "keep_last_n",
        retention_params: %{"n" => 5}
      })

    {:ok, pid} = GenServer.start_link(Notifier, [], name: Notifier)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{job: job, notifier: pid}
  end

  test "fires notify-send on a failed run", %{job: job, notifier: notifier} do
    {:ok, run} = Runs.start(job.id, DateTime.utc_now())

    {:ok, _} =
      Runs.finish(run, %{
        finished_at: DateTime.utc_now(),
        status: "failed",
        error_message: "destination unreachable"
      })

    Phoenix.PubSub.broadcast(
      Fae.PubSub,
      Topics.backups_runs(),
      {:run_finished, run.id, :failed, :boom}
    )

    # Sync the Notifier mailbox.
    :sys.get_state(notifier)

    assert_received {:notify_cmd, "notify-send",
                     [
                       "--urgency=critical",
                       "--icon=dialog-error",
                       "Fae backup failed",
                       body
                     ]}

    assert body =~ "Test Job"
    assert body =~ "destination unreachable"
  end

  test "ignores success events", %{job: job, notifier: notifier} do
    {:ok, run} = Runs.start(job.id, DateTime.utc_now())

    Phoenix.PubSub.broadcast(
      Fae.PubSub,
      Topics.backups_runs(),
      {:run_finished, run.id, :success, %{}}
    )

    :sys.get_state(notifier)

    refute_received {:notify_cmd, _, _}
  end

  test "ignores skipped events", %{job: job, notifier: notifier} do
    {:ok, run} = Runs.start(job.id, DateTime.utc_now())

    Phoenix.PubSub.broadcast(
      Fae.PubSub,
      Topics.backups_runs(),
      {:run_finished, run.id, :skipped, :overlap}
    )

    :sys.get_state(notifier)

    refute_received {:notify_cmd, _, _}
  end

  test "logs a warning when notify-send is missing", %{job: job, notifier: notifier} do
    Application.put_env(:fae, :notify_runner, fn _, _ -> {:error, :enoent} end)

    {:ok, run} = Runs.start(job.id, DateTime.utc_now())

    {:ok, _} =
      Runs.finish(run, %{
        finished_at: DateTime.utc_now(),
        status: "failed",
        error_message: "x"
      })

    import ExUnit.CaptureLog

    log =
      capture_log(fn ->
        Phoenix.PubSub.broadcast(
          Fae.PubSub,
          Topics.backups_runs(),
          {:run_finished, run.id, :failed, :boom}
        )

        :sys.get_state(notifier)
      end)

    assert log =~ "notify-send not available"
  end
end
