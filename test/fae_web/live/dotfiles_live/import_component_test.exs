defmodule FaeWeb.DotfilesLive.ImportComponentTest do
  use ExUnit.Case, async: true

  alias FaeWeb.DotfilesLive.ImportComponent

  describe "disable_timer_command/1" do
    test "surfaces the exact systemctl command for the user to run" do
      assert ImportComponent.disable_timer_command("dot-filer.timer") ==
               "systemctl --user disable --now dot-filer.timer"
    end

    test "defaults to the dot-filer timer unit" do
      assert ImportComponent.disable_timer_command() ==
               "systemctl --user disable --now #{ImportComponent.dot_filer_timer_unit()}"
    end
  end

  describe "summarize_preview/1" do
    test "counts entries by state" do
      preview = [
        %{path: "/a", kind: :directory, state: :symlinked_into_old_repo},
        %{path: "/b", kind: :file, state: :symlinked_into_old_repo},
        %{path: "/c", kind: :file, state: :real},
        %{path: "/d", kind: nil, state: :missing}
      ]

      assert ImportComponent.summarize_preview(preview) == %{
               symlinked: 2,
               real: 1,
               missing: 1
             }
    end
  end

  describe "state_label/1 and error_message/1" do
    test "labels states for display" do
      assert ImportComponent.state_label(:symlinked_into_old_repo) == "symlink (dot-filer)"
      assert ImportComponent.state_label(:real) == "real file"
      assert ImportComponent.state_label(:missing) == "missing"
    end

    test "explains the already-initialized error" do
      assert ImportComponent.error_message(:already_initialized) =~ "already initialized"
    end
  end
end
