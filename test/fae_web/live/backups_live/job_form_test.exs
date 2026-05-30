defmodule FaeWeb.BackupsLive.JobFormTest do
  use ExUnit.Case, async: true

  alias FaeWeb.BackupsLive.JobForm

  describe "source_picker_config/2" do
    test "folder kind picks a folder, files hidden" do
      config = JobForm.source_picker_config("folder", "/home/me")

      assert config == %{
               source: {:local, "/home/me"},
               mode: :pick,
               pick: :folder,
               show_files: false,
               title: "Choose a folder",
               return_to: :source_path
             }
    end

    test "file kind picks a file, files shown" do
      config = JobForm.source_picker_config("file", "/home/me")

      assert config.pick == :file
      assert config.show_files == true
      assert config.title == "Choose a file"
      assert config.source == {:local, "/home/me"}
      assert config.mode == :pick
      assert config.return_to == :source_path
    end

    test "sqlite kind picks a file with a database-flavored title" do
      config = JobForm.source_picker_config("sqlite", "/home/me")

      assert config.pick == :file
      assert config.show_files == true
      assert config.title == "Choose a SQLite database"
    end

    test "an unset source kind defaults to file picking" do
      config = JobForm.source_picker_config(nil, "/home/me")

      assert config.pick == :file
      assert config.show_files == true
      assert config.title == "Choose a file"
    end
  end
end
