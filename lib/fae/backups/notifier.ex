defmodule Fae.Backups.Notifier do
  @moduledoc """
  Subscribes to `backups:runs` and posts a Linux desktop notification
  via `notify-send` (libnotify / D-Bus) when a run finishes in the
  `:failed` state.

  Best-effort: if `notify-send` is missing or the shell-out fails, a
  warning is logged and the GenServer continues. Successes and
  skipped runs do not fire notifications in v1.

  Command execution goes through an injectable runner —
  `Application.get_env(:fae, :notify_runner)` — so tests can capture
  the invocation without actually shelling out.
  """

  use GenServer

  require Logger

  alias Fae.Backups.Run
  alias Fae.Repo

  def start_link(opts \\ []) do
    if enabled?() do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @doc "Whether the Notifier should run in this environment."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:fae, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @impl true
  def init(_opts) do
    :ok = Fae.Backups.subscribe_runs()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:run_finished, run_id, :failed, _reason}, state) do
    notify_failure(run_id)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp notify_failure(run_id) do
    case fetch_run_with_job(run_id) do
      %Run{job: %{name: job_name}, error_message: error_message} ->
        body = "#{job_name}: #{truncate(error_message)}"

        run_command("notify-send", [
          "--urgency=critical",
          "--icon=dialog-error",
          "Fae backup failed",
          body
        ])

      nil ->
        :ok
    end
  end

  defp fetch_run_with_job(run_id) do
    case Repo.get(Run, run_id) do
      nil -> nil
      run -> Repo.preload(run, :job)
    end
  end

  defp truncate(nil), do: "(no error message)"

  defp truncate(message) when is_binary(message) do
    if String.length(message) > 200, do: String.slice(message, 0, 200) <> "…", else: message
  end

  defp run_command(cmd, args) do
    case runner().(cmd, args) do
      {:ok, _output} ->
        :ok

      {:error, :enoent} ->
        Logger.warning("notify-send not available; skipping desktop notification")

      {:error, reason} ->
        Logger.warning("notify-send invocation failed: #{inspect(reason)}")
    end
  end

  defp runner, do: Application.get_env(:fae, :notify_runner, &default_runner/2)

  defp default_runner(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> {:error, {:exit_code, exit_code, output}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end
end
