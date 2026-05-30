defmodule Fae.Dotfiles.Migration do
  @moduledoc """
  Guided migration from the legacy *dot-filer* layout to bare-repo-in-place.

  Dot-filer kept a list of absolute paths in `~/src/dotfiles/target.paths` and
  *moved* each real file or directory into a mirror tree under
  `~/src/dotfiles/files/<absolute-path>`, replacing the original location with a
  symlink into that mirror tree.

  Fae's model is bare-repo-in-place: the real bytes live at their original
  locations under `$HOME`, tracked by a bare git repo. This module:

    1. Previews each target, classifying it as symlinked-into-the-old-repo,
       already-real, or missing.
    2. Takes a timestamped safety copy of the current state of every target.
    3. De-references symlinks **in place** — replacing each symlink with a real
       copy of the bytes it pointed at — while leaving the old mirror tree intact
       as an archive.
    4. Initializes the new bare repo, configures it, and sets the remote.
    5. Stages and commits every target.
    6. Records a `TrackedPath` per target and flips the `Configs` singleton.

  Every filesystem location is injectable via `opts` so the whole flow can run
  against a fake `$HOME` under a temp directory in tests. The real locations are
  used only as defaults when an option is omitted.

  Recognized opts:

    * `:target_file` — path to `target.paths`
    * `:work_tree`   — the work-tree (`$HOME`) the targets live under
    * `:git_dir`     — git-dir for the new bare repo
    * `:safety_dir`  — directory to hold timestamped safety copies
    * `:remote_url`  — remote URL to attach as `origin` (optional)
    * `:stamp`       — timestamp string for the safety-copy directory name
  """

  require Logger

  alias Fae.Dotfiles.Configs
  alias Fae.Dotfiles.Git
  alias Fae.Dotfiles.Paths
  alias Fae.Dotfiles.TrackedPaths

  @default_target_file Path.expand("~/src/dotfiles/target.paths")
  @default_old_files_dir Path.expand("~/src/dotfiles/files")

  @doc """
  Classify each target listed in `target.paths`.

  Returns a list of `%{path: String.t(), kind: :file | :directory | nil,
  state: state}` where `state` is one of:

    * `:symlinked_into_old_repo` — a symlink whose target is under the old
      repo's `files/` directory (the normal dot-filer case)
    * `:real` — exists and is not a symlink
    * `:missing` — does not exist
  """
  def preview(opts \\ []) do
    opts
    |> target_paths()
    |> Enum.map(&classify(&1, opts))
  end

  @doc """
  Run the full migration.

  Returns `{:ok, report}` where `report` is a map with `:imported`,
  `:safety_copy`, `:skipped`, and `:commit_sha`; or `{:error, reason}`.

  Refuses to run (returning `{:error, :already_initialized}`) once the dotfiles
  tool has been initialized, so it is safe to expose pre-migration only.
  """
  def run(opts \\ []) do
    if Configs.get().initialized do
      {:error, :already_initialized}
    else
      do_run(opts)
    end
  end

  defp do_run(opts) do
    previews = preview(opts)
    {present, missing} = Enum.split_with(previews, &(&1.state != :missing))

    Enum.each(missing, fn %{path: path} ->
      Logger.warning("Dotfiles migration: skipping missing target #{path}")
    end)

    safety_copy = copy_to_safety(present, opts)

    Enum.each(present, fn
      %{state: :symlinked_into_old_repo, path: path} -> dereference_in_place(path)
      %{state: :real} -> :ok
    end)

    target_paths = Enum.map(present, & &1.path)

    with :ok <- Git.init_bare(opts),
         :ok <- Git.configure(opts),
         :ok <- maybe_set_remote(opts),
         :ok <- Git.stage(target_paths, opts),
         {:ok, commit_sha} <- Git.commit("Import from dot-filer", opts) do
      record_tracked_paths(present)

      {:ok, _} =
        Configs.update(%{initialized: true, remote_url: Keyword.get(opts, :remote_url)})

      {:ok,
       %{
         imported: length(present),
         skipped: Enum.map(missing, & &1.path),
         safety_copy: safety_copy,
         commit_sha: commit_sha
       }}
    end
  end

  # --- Classification --------------------------------------------------------

  defp classify(path, opts) do
    case File.read_link(path) do
      {:ok, link_target} ->
        state =
          if symlinked_into_old_repo?(link_target, opts),
            do: :symlinked_into_old_repo,
            else: :real

        %{path: path, kind: kind_of(resolve(path, link_target)), state: state}

      {:error, _} ->
        if File.exists?(path) do
          %{path: path, kind: kind_of(path), state: :real}
        else
          %{path: path, kind: nil, state: :missing}
        end
    end
  end

  defp symlinked_into_old_repo?(link_target, opts) do
    old_files = old_files_dir(opts)
    expanded = Path.expand(link_target)
    String.starts_with?(expanded, Path.expand(old_files) <> "/")
  end

  defp resolve(_path, link_target), do: Path.expand(link_target)

  defp kind_of(path) do
    if File.dir?(path), do: :directory, else: :file
  end

  # --- Safety copy -----------------------------------------------------------

  defp copy_to_safety(present, opts) do
    dest_root = Path.join(safety_dir(opts), "import-backup-#{stamp(opts)}")

    Enum.each(present, fn %{path: path} ->
      relative = String.trim_leading(path, "/")
      dest = Path.join(dest_root, relative)
      File.mkdir_p!(Path.dirname(dest))
      # Copy through symlinks so we capture the real bytes, not the link.
      copy_real(path, dest)
    end)

    dest_root
  end

  # Copy the *contents* a target resolves to (following symlinks) to `dest`.
  defp copy_real(source, dest) do
    real_source =
      case File.read_link(source) do
        {:ok, link_target} -> resolve(source, link_target)
        {:error, _} -> source
      end

    File.cp_r!(real_source, dest)
  end

  # --- De-reference ----------------------------------------------------------

  # Replace the symlink at `path` with a real copy of the bytes it points at,
  # leaving the old mirror tree (the link target) untouched.
  defp dereference_in_place(path) do
    link_target = resolve(path, File.read_link!(path))

    staging = path <> ".fae-migration-#{System.unique_integer([:positive])}"
    File.cp_r!(link_target, staging)

    File.rm!(path)
    File.rename!(staging, path)
  end

  # --- Recording -------------------------------------------------------------

  defp record_tracked_paths(present) do
    Enum.each(present, fn %{path: path} ->
      {:ok, _} = TrackedPaths.add(%{path: path, kind: kind_string(path)})
    end)
  end

  # TrackedPath.kind is persisted as a string ("directory"/"file").
  defp kind_string(path), do: Atom.to_string(kind_of(path))

  defp maybe_set_remote(opts) do
    case Keyword.get(opts, :remote_url) do
      nil -> :ok
      url -> Git.set_remote("origin", url, opts)
    end
  end

  # --- Targets & options -----------------------------------------------------

  defp target_paths(opts) do
    opts
    |> target_file()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp target_file(opts), do: Keyword.get(opts, :target_file, @default_target_file)

  # The old dot-filer mirror tree. Defaults to the real location but is derived
  # from the target file's directory so a fake target.paths under a temp dir
  # points at the matching fake `files/` tree in tests.
  defp old_files_dir(opts) do
    Keyword.get_lazy(opts, :old_files_dir, fn ->
      case Keyword.get(opts, :target_file) do
        nil -> @default_old_files_dir
        file -> Path.join(Path.dirname(file), "files")
      end
    end)
  end

  defp safety_dir(opts), do: Keyword.get(opts, :safety_dir, default_safety_dir())
  defp stamp(opts), do: Keyword.get(opts, :stamp) || default_stamp()

  # The new bare repo's git-dir lives at `<data>/dotfiles/repo.git`; park safety
  # copies alongside it under `<data>/dotfiles/import-backups`.
  defp default_safety_dir do
    Paths.git_dir()
    |> Path.dirname()
    |> Path.join("import-backups")
  end

  defp default_stamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9T]/, "")
  end
end
