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

  defp remote(config_attrs) do
    DotfilesView.build(%{
      config: struct(%Config{}, config_attrs),
      tracked: [],
      runs: [],
      now: DateTime.utc_now()
    }).health.remote
  end

  test "remote :none when no remote is configured" do
    r = remote(remote_url: nil)
    assert r.configured? == false
    assert r.url == nil
    assert r.status == :none
    assert r.message == "Backups are staying local — no remote set"
  end

  test "remote :none when remote_url is empty string" do
    r = remote(remote_url: "")
    assert r.configured? == false
    assert r.status == :none
  end

  test "remote :ok when configured and last push succeeded" do
    r = remote(remote_url: "git@github.com:me/dotfiles.git", last_push_ok: true)
    assert r.configured? == true
    assert r.url == "git@github.com:me/dotfiles.git"
    assert r.status == :ok
  end

  test "remote :failed with auth_failed maps to SSH message" do
    r =
      remote(
        remote_url: "git@github.com:me/dotfiles.git",
        last_push_ok: false,
        last_push_error: "auth_failed"
      )

    assert r.configured? == true
    assert r.status == :failed
    assert r.message == "GitHub rejected the key — check your SSH access"
  end

  test "remote :failed with not_found maps to repo message" do
    r =
      remote(
        remote_url: "git@github.com:me/dotfiles.git",
        last_push_ok: false,
        last_push_error: "not_found"
      )

    assert r.status == :failed
    assert r.message == "Repo not found — re-check the URL"
  end

  test "remote :failed with unreachable maps to retry message" do
    r =
      remote(
        remote_url: "git@github.com:me/dotfiles.git",
        last_push_ok: false,
        last_push_error: "unreachable"
      )

    assert r.status == :failed
    assert r.message == "Couldn't reach GitHub — will retry"
  end

  test "remote :failed with unknown reason falls back to generic message" do
    r =
      remote(
        remote_url: "git@github.com:me/dotfiles.git",
        last_push_ok: false,
        last_push_error: "something weird"
      )

    assert r.status == :failed
    assert r.message == "Last push failed — will retry"
  end
end
