defmodule Fae.Dotfiles.GitHubTest do
  use ExUnit.Case, async: true
  alias Fae.Dotfiles.GitHub

  describe "available?/1" do
    # `available?/1` is gated by `System.find_executable("gh")`, which cannot
    # be faked. These tests exercise the `gh auth status` branch via the
    # injected cmd. When `gh` is on PATH (CI/dev machines that have it), the
    # find_executable gate passes and the injected exit code decides the
    # result; when `gh` is absent, the gate forces false regardless of cmd.
    @gh_present System.find_executable("gh") != nil

    test "true when gh resolves and `gh auth status` exits 0 (when gh is on PATH)" do
      auth_ok = fn "gh", ["auth", "status"], _ -> {"", 0} end

      if @gh_present do
        assert GitHub.available?(auth_ok)
      else
        # gh not on PATH: find_executable gate forces false.
        refute GitHub.available?(auth_ok)
      end
    end

    test "false when `gh auth status` exits non-zero" do
      auth_fail = fn "gh", ["auth", "status"], _ -> {"not logged in", 1} end
      refute GitHub.available?(auth_fail)
    end
  end

  describe "default_repo_name/1" do
    test "slugifies the injected hostname" do
      assert GitHub.default_repo_name("Shawn-Desktop.local") == "dotfiles-shawn-desktop-local"
    end

    test "trims leading/trailing dashes produced by sanitizing" do
      assert GitHub.default_repo_name(".Weird..Host.") == "dotfiles-weird-host"
    end

    test "collapses runs of disallowed characters into a single dash" do
      assert GitHub.default_repo_name("Foo   Bar___baz") == "dotfiles-foo-bar-baz"
    end

    test "derives a name from the real hostname when none is injected" do
      name = GitHub.default_repo_name()
      assert String.starts_with?(name, "dotfiles-")
      assert name =~ ~r/^dotfiles-[a-z0-9-]*$/
    end
  end

  describe "create_private_repo/2" do
    test "happy path creates the repo and resolves the ssh url" do
      ssh = "git@github.com:owner/dotfiles-x.git"

      cmd = fn
        "gh", ["repo", "create", "dotfiles-x", "--private"], _ ->
          {"", 0}

        "gh", ["repo", "view", "dotfiles-x", "--json", "sshUrl", "-q", ".sshUrl"], _ ->
          {ssh <> "\n", 0}
      end

      assert GitHub.create_private_repo("dotfiles-x", cmd) == {:ok, ssh}
    end

    test "returns {:error, :already_exists} when gh reports the repo exists" do
      cmd = fn
        "gh", ["repo", "create", "dotfiles-x", "--private"], _ ->
          {"GraphQL: Name already exists on this account", 1}
      end

      assert GitHub.create_private_repo("dotfiles-x", cmd) == {:error, :already_exists}
    end

    test "returns {:error, trimmed_output} for other create failures" do
      cmd = fn
        "gh", ["repo", "create", "dotfiles-x", "--private"], _ ->
          {"  boom: bad credentials  \n", 1}
      end

      assert GitHub.create_private_repo("dotfiles-x", cmd) == {:error, "boom: bad credentials"}
    end

    test "propagates an error when resolving the ssh url fails" do
      cmd = fn
        "gh", ["repo", "create", "dotfiles-x", "--private"], _ ->
          {"", 0}

        "gh", ["repo", "view", "dotfiles-x", "--json", "sshUrl", "-q", ".sshUrl"], _ ->
          {"no remote\n", 1}
      end

      assert GitHub.create_private_repo("dotfiles-x", cmd) == {:error, "no remote"}
    end
  end
end
