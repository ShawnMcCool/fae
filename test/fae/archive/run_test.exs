defmodule Fae.Archive.RunTest do
  use Fae.DataCase, async: true

  alias Fae.Archive.Run

  @tag :tmp_dir
  test "valid attrs produce a valid changeset", %{tmp_dir: tmp_dir} do
    changeset =
      Run.create_changeset(%Run{}, %{
        name: "Camera Backup",
        source_path: tmp_dir,
        label: "Pictures Videos",
        destination_id: Ecto.UUID.generate()
      })

    assert changeset.valid?
  end

  test "name, source_path, and destination_id are required" do
    changeset = Run.create_changeset(%Run{}, %{})
    assert "can't be blank" in errors_on(changeset).name
    assert "can't be blank" in errors_on(changeset).source_path
    assert "can't be blank" in errors_on(changeset).destination_id
  end

  @tag :tmp_dir
  test "a blank name is rejected", %{tmp_dir: tmp_dir} do
    changeset =
      Run.create_changeset(%Run{}, %{
        name: "   ",
        source_path: tmp_dir,
        destination_id: Ecto.UUID.generate()
      })

    assert "can't be blank" in errors_on(changeset).name
  end

  test "rejects a source_path that is not an existing directory" do
    changeset =
      Run.create_changeset(%Run{}, %{
        name: "X",
        source_path: "/no/such/directory/anywhere",
        destination_id: Ecto.UUID.generate()
      })

    assert "is not an existing directory" in errors_on(changeset).source_path
  end

  @tag :tmp_dir
  test "label (remote folder) defaults to empty string when omitted", %{tmp_dir: tmp_dir} do
    changeset =
      Run.create_changeset(%Run{}, %{
        name: "X",
        source_path: tmp_dir,
        destination_id: Ecto.UUID.generate()
      })

    assert changeset.valid?
    assert Ecto.Changeset.apply_changes(changeset).label == ""
  end

  @tag :tmp_dir
  test "trims surrounding whitespace on name, source_path, and label", %{tmp_dir: tmp_dir} do
    changeset =
      Run.create_changeset(%Run{}, %{
        name: "  Camera Backup  ",
        source_path: "  #{tmp_dir}  ",
        label: "  Pictures Videos  ",
        destination_id: Ecto.UUID.generate()
      })

    assert changeset.valid?
    applied = Ecto.Changeset.apply_changes(changeset)
    assert applied.name == "Camera Backup"
    assert applied.source_path == tmp_dir
    assert applied.label == "Pictures Videos"
  end
end
