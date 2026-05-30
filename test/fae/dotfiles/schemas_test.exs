defmodule Fae.Dotfiles.SchemasTest do
  use Fae.DataCase, async: true
  alias Fae.Dotfiles.{Config, TrackedPath, Run}

  test "tracked_path requires a valid kind" do
    refute TrackedPath.changeset(%TrackedPath{}, %{path: "/x", kind: "nope"}).valid?
    assert TrackedPath.changeset(%TrackedPath{}, %{path: "/x", kind: "directory"}).valid?
  end

  test "config rejects sub-300s interval" do
    refute Config.changeset(%Config{}, %{interval_seconds: 60}).valid?
    assert Config.changeset(%Config{}, %{interval_seconds: 3600}).valid?
  end

  test "run start requires status + started_at" do
    refute Run.start_changeset(%Run{}, %{}).valid?

    assert Run.start_changeset(%Run{}, %{status: "running", started_at: DateTime.utc_now()}).valid?
  end
end
