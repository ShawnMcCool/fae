defmodule Fae.Dotfiles.MigrationTest do
  use Fae.DataCase, async: false

  alias Fae.Dotfiles.Configs
  alias Fae.Dotfiles.Git
  alias Fae.Dotfiles.Migration
  alias Fae.Dotfiles.TrackedPaths

  # Build a fully isolated fake environment under System.tmp_dir!().
  #
  # Layout mirrors the dot-filer world:
  #
  #   <base>/home/                         -> fake $HOME (work_tree)
  #   <base>/home/.config/nvim             -> symlink into old repo (dir)
  #   <base>/home/.bashrc                  -> symlink into old repo (file)
  #   <base>/home/.real_file               -> a real file (already migrated)
  #   <base>/src/dotfiles/files/<home>/... -> old mirror tree with the real bytes
  #   <base>/target.paths                  -> lists the fake-home paths
  #   <base>/git.git                       -> new bare repo git-dir
  #   <base>/safety                        -> safety copies
  #   <base>/remote.git                    -> fake remote
  setup do
    base =
      Path.join(System.tmp_dir!(), "dotfiles_migration_#{System.unique_integer([:positive])}")

    home = Path.join(base, "home")
    old_repo = Path.join(base, "src/dotfiles")
    old_files = Path.join(old_repo, "files")
    target_file = Path.join(base, "target.paths")
    git_dir = Path.join(base, "git.git")
    safety_dir = Path.join(base, "safety")
    remote_dir = Path.join(base, "remote.git")

    File.mkdir_p!(home)

    # Old mirror tree: real bytes live here. The mirror path mimics the absolute
    # original path rooted under files/ (dot-filer strips the leading slash).
    nvim_original = Path.join(home, ".config/nvim")
    bashrc_original = Path.join(home, ".bashrc")
    real_original = Path.join(home, ".real_file")
    missing_original = Path.join(home, ".gone")

    nvim_mirror = Path.join(old_files, String.trim_leading(nvim_original, "/"))
    bashrc_mirror = Path.join(old_files, String.trim_leading(bashrc_original, "/"))

    # Populate the mirror with real bytes (a dir with a file, and a plain file).
    File.mkdir_p!(nvim_mirror)
    File.write!(Path.join(nvim_mirror, "init.lua"), "vim.opt.number = true\n")
    File.mkdir_p!(Path.dirname(bashrc_mirror))
    File.write!(bashrc_mirror, "export EDITOR=nvim\n")

    # Symlink the original locations into the mirror (dot-filer state).
    File.mkdir_p!(Path.dirname(nvim_original))
    File.ln_s!(nvim_mirror, nvim_original)
    File.ln_s!(bashrc_mirror, bashrc_original)

    # A target that is already a real file in place.
    File.write!(real_original, "already real\n")

    # target.paths lists all four absolute paths.
    File.write!(
      target_file,
      Enum.join([nvim_original, bashrc_original, real_original, missing_original], "\n") <> "\n"
    )

    # Fake remote to attach as origin.
    System.cmd("git", ["init", "--bare", remote_dir])

    on_exit(fn -> File.rm_rf!(base) end)

    opts = [
      target_file: target_file,
      work_tree: home,
      git_dir: git_dir,
      safety_dir: safety_dir,
      old_files_dir: old_files,
      remote_url: "file://" <> remote_dir,
      stamp: "20260530-120000"
    ]

    %{
      base: base,
      home: home,
      old_files: old_files,
      opts: opts,
      nvim_original: nvim_original,
      bashrc_original: bashrc_original,
      real_original: real_original,
      missing_original: missing_original,
      nvim_mirror: nvim_mirror,
      bashrc_mirror: bashrc_mirror
    }
  end

  describe "preview/1" do
    test "classifies each target path", %{opts: opts} = ctx do
      preview = Migration.preview(opts)

      by_path = Map.new(preview, &{&1.path, &1})

      assert by_path[ctx.nvim_original].state == :symlinked_into_old_repo
      assert by_path[ctx.bashrc_original].state == :symlinked_into_old_repo
      assert by_path[ctx.real_original].state == :real
      assert by_path[ctx.missing_original].state == :missing

      assert by_path[ctx.nvim_original].kind == :directory
      assert by_path[ctx.bashrc_original].kind == :file
    end
  end

  describe "run/1" do
    test "de-references symlinks in place into real files", %{opts: opts} = ctx do
      assert {:ok, _report} = Migration.run(opts)

      # The symlinked targets are now real files/dirs in place.
      assert {:error, _} = File.read_link(ctx.nvim_original)
      assert {:error, _} = File.read_link(ctx.bashrc_original)

      assert File.dir?(ctx.nvim_original)
      assert File.read!(Path.join(ctx.nvim_original, "init.lua")) == "vim.opt.number = true\n"
      assert File.read!(ctx.bashrc_original) == "export EDITOR=nvim\n"

      # The real target is left as-is.
      assert File.read!(ctx.real_original) == "already real\n"

      # The old mirror tree is left intact as an archive.
      assert File.read!(Path.join(ctx.nvim_mirror, "init.lua")) == "vim.opt.number = true\n"
      assert File.read!(ctx.bashrc_mirror) == "export EDITOR=nvim\n"
    end

    test "initializes the new bare repo with a commit containing the targets",
         %{opts: opts} = ctx do
      assert {:ok, _report} = Migration.run(opts)

      assert {:ok, sha} = Git.head_sha(opts)
      assert is_binary(sha) and sha != ""

      assert {:ok, files} = Git.ls_files([ctx.home], opts)
      assert files != []
      assert Enum.any?(files, &(&1 =~ "init.lua"))
      assert Enum.any?(files, &(&1 =~ ".bashrc"))
    end

    test "records a TrackedPath per existing target", %{opts: opts} = ctx do
      assert {:ok, report} = Migration.run(opts)

      paths = TrackedPaths.list() |> Enum.map(& &1.path) |> MapSet.new()

      assert MapSet.member?(paths, ctx.nvim_original)
      assert MapSet.member?(paths, ctx.bashrc_original)
      assert MapSet.member?(paths, ctx.real_original)
      refute MapSet.member?(paths, ctx.missing_original)

      assert report.imported == 3
    end

    test "flips Configs to initialized and stores remote_url", %{opts: opts} do
      assert {:ok, _report} = Migration.run(opts)

      config = Configs.get()
      assert config.initialized == true
      assert config.remote_url == Keyword.fetch!(opts, :remote_url)
    end

    test "writes a safety copy of the pre-migration content", %{opts: opts} = ctx do
      assert {:ok, report} = Migration.run(opts)

      assert File.dir?(report.safety_copy)

      # The safety copy holds the pre-migration bytes for each target.
      nvim_rel = String.trim_leading(ctx.nvim_original, "/")
      bashrc_rel = String.trim_leading(ctx.bashrc_original, "/")

      assert File.read!(Path.join([report.safety_copy, nvim_rel, "init.lua"])) ==
               "vim.opt.number = true\n"

      assert File.read!(Path.join(report.safety_copy, bashrc_rel)) == "export EDITOR=nvim\n"
    end

    test "returns {:error, :already_initialized} when already initialized", %{opts: opts} do
      {:ok, _} = Configs.update(%{initialized: true})

      assert {:error, :already_initialized} = Migration.run(opts)
    end
  end
end
