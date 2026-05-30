defmodule FaeWeb.DotfilesViewTest do
  use ExUnit.Case, async: true
  alias FaeWeb.DotfilesView
  alias Fae.Dotfiles.{Config, TrackedPath}

  defp tp(path, kind, opts \\ []),
    do: %TrackedPath{path: path, kind: kind, first_backed_up_at: opts[:first]}

  test "groups by parent dir and classifies status" do
    home = System.tmp_dir!()
    nvim = Path.join(home, ".config/nvim")
    File.mkdir_p!(nvim)
    missing = Path.join(home, ".config/gone")
    paths = [tp(nvim, "directory", first: DateTime.utc_now()), tp(missing, "file")]

    view =
      DotfilesView.build(%{
        config: %Config{enabled: true, interval_seconds: 3600},
        tracked: paths,
        runs: [],
        now: DateTime.utc_now()
      })

    group = Enum.find(view.groups, &(&1.header == Path.join(home, ".config") <> "/"))
    statuses = Map.new(group.items, &{&1.name, &1.status})
    assert statuses["nvim"] == :ok
    assert statuses["gone"] == :missing
  end

  test "pending when tracked but never backed up and exists" do
    home = System.tmp_dir!()
    p = Path.join(home, ".config/new")
    File.mkdir_p!(p)

    view =
      DotfilesView.build(%{
        config: %Config{},
        tracked: [tp(p, "directory")],
        runs: [],
        now: DateTime.utc_now()
      })

    item = view.groups |> Enum.flat_map(& &1.items) |> Enum.find(&(&1.name == "new"))
    assert item.status == :pending
  end
end
