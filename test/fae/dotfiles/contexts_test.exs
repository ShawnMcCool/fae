defmodule Fae.Dotfiles.ContextsTest do
  use Fae.DataCase, async: true
  alias Fae.Dotfiles.{Configs, TrackedPaths, Runs}

  test "Configs.get/0 creates the singleton then updates it" do
    c = Configs.get()
    assert c.id == 1 and c.enabled
    {:ok, c2} = Configs.update(%{interval_seconds: 1800})
    assert c2.interval_seconds == 1800
    assert Configs.get().interval_seconds == 1800
  end

  test "TrackedPaths add/list/remove + broadcast" do
    Phoenix.PubSub.subscribe(Fae.PubSub, Fae.Topics.dotfiles_status())
    {:ok, tp} = TrackedPaths.add(%{path: "/home/x/.config/nvim", kind: "directory"})
    assert_receive {:dotfiles_changed}
    assert Enum.map(TrackedPaths.list(), & &1.path) == ["/home/x/.config/nvim"]
    :ok = TrackedPaths.remove(tp)
    assert TrackedPaths.list() == []
  end

  test "Runs lifecycle" do
    {:ok, run} = Runs.create_started()
    assert run.status == "running"

    {:ok, done} =
      Runs.finalize(run, %{
        status: "success",
        finished_at: DateTime.utc_now(),
        files_changed: 2,
        pushed: true
      })

    assert done.status == "success" and done.pushed
    assert [^done] = Runs.list_recent(5) |> Enum.filter(&(&1.id == done.id))
  end
end
