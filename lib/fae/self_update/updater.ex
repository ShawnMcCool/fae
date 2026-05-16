defmodule Fae.SelfUpdate.Updater do
  @moduledoc """
  GenServer that serialises release-apply operations.

  One update at a time. A call to `apply_pending/1` transitions the
  state machine from `:idle` → `:preparing` → `:downloading` →
  `:extracting` → `:handing_off`, broadcasting each phase on
  `self_update:progress`. The actual download/stage/handoff runs in a
  supervised `Task` so the call returns immediately — concurrent
  callers see `{:error, :already_running}`.

  ## Invariants

    * A release must have a tag that passes `UpdateChecker.validate_tag/1`.
      Anything else is rejected as `{:error, :invalid_tag}` before the
      downloader is ever contacted.
    * Download URLs are built from a fixed template using the
      validated tag + version. The API's `browser_download_url` is
      deliberately ignored.
    * A release classified as `:up_to_date`, `:ahead_of_release`, or
      unknown is rejected as `{:error, :no_update_pending}`. Silent
      downgrades never happen.

  ## Injectable dependencies

  `start_link/1` accepts `:downloader`, `:stager`, and `:handoff`
  modules so tests can substitute fakes.
  """

  use GenServer

  require Logger

  alias Fae.SelfUpdate.{Downloader, Handoff, Stager, UpdateChecker}
  alias Fae.Topics
  alias Fae.Version

  @repo_base "https://github.com/ShawnMcCool/fae/releases/download"

  defmodule State do
    @moduledoc false
    defstruct phase: :idle,
              release: nil,
              error: nil,
              task: nil,
              task_ref: nil,
              staging_dir: nil,
              deps: nil,
              staging_root: nil
  end

  @type phase ::
          :idle
          | :preparing
          | :downloading
          | :extracting
          | :handing_off
          | :done
          | :failed

  @type status :: %{phase: phase(), release: map() | nil, error: term() | nil}

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec apply_pending(atom() | pid()) ::
          :ok | {:error, :no_update_pending | :invalid_tag | :already_running}
  def apply_pending(server \\ __MODULE__) do
    GenServer.call(server, :apply_pending, 10_000)
  end

  @spec status(atom() | pid()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @spec cancel(atom() | pid()) ::
          :ok | {:error, :not_running | :past_point_of_no_return}
  def cancel(server \\ __MODULE__) do
    GenServer.call(server, :cancel)
  end

  # Phases where we can still abort safely — no detached installer has
  # been spawned. The worst consequence is a partial tarball in the
  # staging dir (cleaned on cancel).
  @cancellable_phases [:preparing, :downloading, :extracting]

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    deps = %{
      downloader: Keyword.get(opts, :downloader, Downloader),
      stager: Keyword.get(opts, :stager, Stager),
      handoff: Keyword.get(opts, :handoff, Handoff)
    }

    staging_root = Keyword.get(opts, :staging_root, default_staging_root())
    {:ok, %State{deps: deps, staging_root: staging_root}}
  end

  @impl GenServer
  def handle_call(:status, _from, %State{} = state) do
    {:reply, %{phase: state.phase, release: state.release, error: state.error}, state}
  end

  # Terminal phases we allow a fresh apply_pending to blow through.
  @resettable_phases [:idle, :failed, :done]

  def handle_call(:apply_pending, _from, %State{phase: phase} = state)
      when phase in @resettable_phases do
    with {:ok, release} <- fetch_pending_release(),
         :ok <- UpdateChecker.validate_tag(release.tag) do
      parent = self()
      worker_deps = state.deps
      staging = staging_dir(state.staging_root, release.version)

      task =
        Task.Supervisor.async_nolink(Fae.TaskSupervisor, fn ->
          run_apply(release, worker_deps, staging, parent)
        end)

      new_state = %{
        state
        | phase: :preparing,
          release: release,
          task: task,
          task_ref: task.ref,
          staging_dir: staging,
          error: nil
      }

      broadcast({:progress, :preparing, nil})

      {:reply, :ok, new_state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:apply_pending, _from, %State{} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call(:cancel, _from, %State{task: nil} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:cancel, _from, %State{phase: phase, task: %Task{} = task} = state)
      when phase in @cancellable_phases do
    _ = Task.shutdown(task, :brutal_kill)
    _ = rm_staging(state.staging_dir)

    broadcast({:apply_cancelled})
    Logger.info("update apply cancelled from phase #{phase}")

    {:reply, :ok,
     %{
       state
       | phase: :idle,
         task: nil,
         task_ref: nil,
         staging_dir: nil,
         release: nil,
         error: nil
     }}
  end

  def handle_call(:cancel, _from, %State{} = state) do
    {:reply, {:error, :past_point_of_no_return}, state}
  end

  @impl GenServer
  def handle_info({:phase, phase, pct}, %State{} = state) do
    broadcast({:progress, phase, pct})
    {:noreply, %{state | phase: phase}}
  end

  def handle_info({:apply_failed, reason}, %State{} = state) do
    broadcast({:apply_failed, reason})
    Logger.warning("update apply failed: #{inspect(reason)}")
    {:noreply, %{state | phase: :failed, error: reason}}
  end

  def handle_info({:apply_succeeded}, %State{} = state) do
    # Post-handoff the BEAM will die as systemd restarts the unit;
    # this message is informational for tests / inspection.
    {:noreply, %{state | phase: :done}}
  end

  # Task.async_nolink sends {ref, result} then {:DOWN, ref, ...}.
  def handle_info({ref, _result}, %State{task_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil, task_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, %State{task_ref: ref} = state) do
    {:noreply, %{state | task: nil, task_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{task_ref: ref} = state) do
    Logger.warning("update task crashed: #{inspect(reason)}")
    broadcast({:apply_failed, {:task_crashed, reason}})

    {:noreply,
     %{state | phase: :failed, error: {:task_crashed, reason}, task: nil, task_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Apply pipeline (runs in the Task) ---

  defp run_apply(release, deps, staging, parent) do
    tag = release.tag
    version = release.version
    filename = tarball_filename(version)
    tarball_url = "#{@repo_base}/#{tag}/#{filename}"
    sums_url = "#{@repo_base}/#{tag}/SHA256SUMS"

    progress_fn = fn bytes, total ->
      pct =
        if is_integer(total) and total > 0 do
          round(bytes / total * 100)
        end

      send(parent, {:phase, :downloading, pct})
    end

    send(parent, {:phase, :downloading, 0})

    case deps.downloader.run(tarball_url, sums_url,
           target_dir: staging,
           filename: filename,
           progress_fn: progress_fn
         ) do
      {:ok, %{tarball_path: tarball}} ->
        send(parent, {:phase, :extracting, nil})

        case deps.stager.extract(tarball, staging) do
          {:ok, staged_root} ->
            send(parent, {:phase, :handing_off, nil})

            case deps.handoff.spawn_detached(staged_root) do
              :ok ->
                send(parent, {:phase, :done, nil})
                send(parent, {:apply_succeeded})

              other ->
                send(parent, {:apply_failed, {:handoff, other}})
            end

          {:error, reason} ->
            send(parent, {:apply_failed, {:stage, reason}})
        end

      {:error, reason} ->
        send(parent, {:apply_failed, {:download, reason}})
    end
  end

  # --- Helpers ---

  defp fetch_pending_release do
    with {:fresh, {:ok, release}} <- UpdateChecker.cached_latest_release(),
         :update_available <- UpdateChecker.compare(release, Version.current_version()) do
      {:ok, release}
    else
      _ -> {:error, :no_update_pending}
    end
  end

  defp tarball_filename(version), do: "fae-#{version}-linux-x86_64.tar.gz"

  defp staging_dir(root, version) do
    unique = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    Path.join(root, "#{version}-#{unique}")
  end

  defp default_staging_root do
    Path.join([System.user_home!(), ".cache", "fae", "upgrade-staging"])
  end

  defp rm_staging(nil), do: :ok

  defp rm_staging(dir) when is_binary(dir) do
    case File.rm_rf(dir) do
      {:ok, _} -> :ok
      {:error, _, _} -> :ok
    end
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Fae.PubSub, Topics.self_update_progress(), message)
  end
end
