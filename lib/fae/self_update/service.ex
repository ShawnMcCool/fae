defmodule Fae.SelfUpdate.Service do
  @moduledoc """
  Systemd-aware controls for the running fae user unit.

  Two detection signals:

  * **`under_systemd`** — whether this BEAM is actually supervised by
    systemd. Read from `INVOCATION_ID`, which systemd sets for every
    unit execution.
  * **`unit_name`** — the specific unit this BEAM belongs to. Parsed
    from `/proc/self/cgroup`, whose last `*.service` segment is the
    unit name under both cgroup v2 and v1.

  ## Process model

  Restart and stop use `systemctl --user --no-block …`. `--no-block`
  queues the job and returns immediately — important for restart:
  without it, `systemctl` would wait for ExecStop, but ExecStop kills
  the very BEAM that spawned it.

  ## Injection

  All external effects are injectable for tests:

  * `:cmd_fn` — `(binary, [args]) -> {output, exit_code}`
  * `:env_fn` — `(name) -> value | nil` (default `System.get_env/1`)
  * `:cgroup_reader` — `() -> {:ok, binary} | {:error, term}` (default
    `File.read("/proc/self/cgroup")`)
  """

  require Logger

  @default_unit "fae.service"

  @type state :: %{
          under_systemd: boolean(),
          unit_name: String.t() | nil,
          systemd_available: boolean(),
          unit_installed: boolean(),
          active: boolean(),
          enabled: boolean()
        }

  @spec state(keyword()) :: state()
  def state(opts \\ []) do
    cmd_fn = Keyword.get(opts, :cmd_fn, &default_cmd/2)
    env_fn = Keyword.get(opts, :env_fn, &System.get_env/1)
    cgroup_reader = Keyword.get(opts, :cgroup_reader, &default_cgroup_reader/0)

    under = under_systemd?(env_fn)
    detected_unit = if under, do: detect_unit(cgroup_reader)
    unit = detected_unit || @default_unit
    available = systemd_available?(cmd_fn)

    %{
      under_systemd: under,
      unit_name: detected_unit,
      systemd_available: available,
      unit_installed: available and unit_installed?(cmd_fn, unit),
      active: available and active?(cmd_fn, unit),
      enabled: available and enabled?(cmd_fn, unit)
    }
  end

  @doc """
  Returns the systemd unit this BEAM is supervised by, or `nil` if it
  isn't under systemd.

  Cheap: only reads `INVOCATION_ID` and `/proc/self/cgroup`. Safe to
  call from hot paths like LiveView mount.
  """
  @spec detected_unit(keyword()) :: String.t() | nil
  def detected_unit(opts \\ []) do
    env_fn = Keyword.get(opts, :env_fn, &System.get_env/1)
    cgroup_reader = Keyword.get(opts, :cgroup_reader, &default_cgroup_reader/0)

    if under_systemd?(env_fn), do: detect_unit(cgroup_reader)
  end

  @spec restart(keyword()) :: :ok | {:error, term()}
  def restart(opts \\ []) do
    cmd_fn = Keyword.get(opts, :cmd_fn, &default_cmd/2)
    unit = resolve_unit(opts)
    Logger.info("restarting #{unit} via systemctl --user")

    case cmd_fn.("systemctl", ["--user", "--no-block", "restart", unit]) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:systemctl_failed, code, String.trim(output)}}
    end
  end

  @spec stop(keyword()) :: :ok | {:error, term()}
  def stop(opts \\ []) do
    cmd_fn = Keyword.get(opts, :cmd_fn, &default_cmd/2)
    unit = resolve_unit(opts)
    Logger.info("stopping #{unit} via systemctl --user")

    case cmd_fn.("systemctl", ["--user", "--no-block", "stop", unit]) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:systemctl_failed, code, String.trim(output)}}
    end
  end

  @spec status_output(keyword()) :: {:ok, String.t()} | {:error, term()}
  def status_output(opts \\ []) do
    cmd_fn = Keyword.get(opts, :cmd_fn, &default_cmd/2)
    unit = resolve_unit(opts)

    try do
      {output, _code} = cmd_fn.("systemctl", ["--user", "status", unit, "--no-pager"])
      {:ok, output}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp resolve_unit(opts) do
    cgroup_reader = Keyword.get(opts, :cgroup_reader, &default_cgroup_reader/0)
    detect_unit(cgroup_reader) || @default_unit
  end

  defp under_systemd?(env_fn) do
    case env_fn.("INVOCATION_ID") do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp detect_unit(cgroup_reader) do
    case cgroup_reader.() do
      {:ok, contents} -> parse_cgroup_unit(contents)
      _ -> nil
    end
  end

  defp parse_cgroup_unit(contents) when is_binary(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.map(&extract_service_from_line/1)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp parse_cgroup_unit(_), do: nil

  defp extract_service_from_line(line) do
    line
    |> String.split("/")
    |> Enum.reverse()
    |> Enum.find(&String.ends_with?(&1, ".service"))
  end

  defp default_cgroup_reader, do: File.read("/proc/self/cgroup")

  defp systemd_available?(cmd_fn) do
    case cmd_fn.("systemctl", ["--user", "show-environment"]) do
      {_output, 0} -> true
      _ -> false
    end
  catch
    _, _ -> false
  end

  defp unit_installed?(cmd_fn, unit) do
    case cmd_fn.("systemctl", ["--user", "list-unit-files", unit, "--no-pager"]) do
      {output, 0} -> String.contains?(output, unit)
      _ -> false
    end
  end

  defp active?(cmd_fn, unit) do
    case cmd_fn.("systemctl", ["--user", "is-active", unit]) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp enabled?(cmd_fn, unit) do
    case cmd_fn.("systemctl", ["--user", "is-enabled", unit]) do
      {_output, 0} -> true
      _ -> false
    end
  end

  # Forward the env vars systemctl needs while blanking the app's own
  # secret out of the child's environment.
  defp default_cmd(binary, args) do
    resolved = System.find_executable(binary) || binary

    keep =
      Enum.flat_map(["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"], fn name ->
        case System.get_env(name) do
          nil -> []
          "" -> []
          value -> [{name, value}]
        end
      end)

    redacted = [{"SECRET_KEY_BASE", ""}]

    System.cmd(resolved, args, stderr_to_stdout: true, env: keep ++ redacted)
  rescue
    ErlangError -> {"", 127}
  end
end
