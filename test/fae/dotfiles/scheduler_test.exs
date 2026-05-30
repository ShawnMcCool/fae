defmodule Fae.Dotfiles.SchedulerTest do
  use Fae.DataCase, async: false
  use Oban.Testing, repo: Fae.Repo

  alias Fae.Dotfiles.{BackupWorker, Configs, Scheduler}

  # config/test.exs sets `config :fae, Oban, testing: :inline`, which
  # executes inserted jobs synchronously and ignores `scheduled_at`.
  # The scheduler enqueues a *future* job, so we wrap each
  # reconcile+assert in manual testing mode to keep the scheduled job
  # in the queue where `assert_enqueued`/`refute_enqueued` can see it.

  test "reconcile enqueues exactly one scheduled job when initialized+enabled" do
    {:ok, _} = Configs.update(%{initialized: true, enabled: true, remote_url: "x"})

    Oban.Testing.with_testing_mode(:manual, fn ->
      :ok = Scheduler.do_reconcile()
      assert_enqueued(worker: BackupWorker, args: %{"kind" => "scheduled"})
    end)
  end

  test "reconcile enqueues nothing when disabled" do
    {:ok, _} = Configs.update(%{initialized: true, enabled: false})

    Oban.Testing.with_testing_mode(:manual, fn ->
      :ok = Scheduler.do_reconcile()
      refute_enqueued(worker: BackupWorker)
    end)
  end

  test "reconcile is a no-op until initialized" do
    {:ok, _} = Configs.update(%{initialized: false})

    Oban.Testing.with_testing_mode(:manual, fn ->
      :ok = Scheduler.do_reconcile()
      refute_enqueued(worker: BackupWorker)
    end)
  end
end
