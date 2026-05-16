defmodule Fae.SelfUpdate.Handoff do
  @moduledoc """
  Spawns the staged `bin/fae-install` as a detached process that
  outlives the current BEAM. That detached child swaps the install
  tree and restarts the systemd unit — which kills this BEAM, and the
  new release takes over.

  ## Security posture

    * The installer path is passed as a **positional** argv entry,
      never interpolated into the shell command string. A path
      containing `;`, `&&`, `$()`, quotes, or newlines is just a
      (nonsensical) argv value; it is not parsed as shell.
    * The command runs under `env -i` with a minimal `PATH` and only
      `HOME` plus the env vars `systemctl --user` needs.
    * `setsid --fork` creates a brand-new session with a grandchild
      process. Any SIGHUP from the parent BEAM's restart cannot reach
      the grandchild.
    * The spawning `Port.open` uses `:nouse_stdio` so Erlang never
      connects pipes to the child. `Port.close` therefore cannot
      SIGPIPE the chain.
    * The handoff script's first instruction redirects its own stdio
      to a log file inside the staging dir — durable diagnostic trail.

  ## Diagnosing a stuck handoff

  If the UI is stuck on "Restarting the service…" the
  `{staged_root}/handoff.log` file tells you how far the chain got.

  The `:spawn_fn` option lets tests assert the exact argv shape
  without executing a subprocess.
  """

  require Logger

  @spec spawn_detached(String.t(), keyword()) :: :ok
  def spawn_detached(staged_root, opts \\ []) do
    spawn_fn = Keyword.get(opts, :spawn_fn, &default_spawn/1)
    home = Keyword.get(opts, :home, System.user_home!())
    env_getter = Keyword.get(opts, :env_getter, &System.get_env/1)

    installer = Path.join(staged_root, "bin/fae-install")
    log_file = Path.join(staged_root, "handoff.log")

    script = ~S"""
    exec >>"$2" 2>&1
    printf 'handoff: started at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sleep 1
    printf 'handoff: execing %s\n' "$1"
    exec "$1"
    """

    systemd_env =
      Enum.reject(
        [
          pass_through(env_getter, "XDG_RUNTIME_DIR"),
          pass_through(env_getter, "DBUS_SESSION_BUS_ADDRESS"),
          pass_through(env_getter, "XDG_DATA_DIRS"),
          pass_through(env_getter, "XDG_CONFIG_DIRS")
        ],
        &is_nil/1
      )

    args =
      [
        "env",
        "-i",
        "HOME=" <> home,
        "PATH=/usr/bin:/bin"
      ] ++
        systemd_env ++
        [
          "setsid",
          "--fork",
          "sh",
          "-c",
          script,
          "--",
          installer,
          log_file
        ]

    Logger.info("handing off to staged installer at #{staged_root}")
    _ = spawn_fn.(args)
    :ok
  end

  defp pass_through(env_getter, name) do
    case env_getter.(name) do
      nil -> nil
      "" -> nil
      value -> "#{name}=#{value}"
    end
  end

  defp default_spawn(args) do
    [command | rest] = args

    port =
      Port.open({:spawn_executable, System.find_executable(command)}, [
        :binary,
        :hide,
        :nouse_stdio,
        {:args, rest}
      ])

    true = Port.close(port)
    :ok
  end
end
