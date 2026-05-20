defmodule Fae.Backups.SuspendWatcher do
  @moduledoc """
  Detects resume from suspend / hibernate by polling the skew between
  wall clock and monotonic clock. On detection, asks the scheduler to
  restage any overdue backup jobs with a stagger so they don't all
  fire back-to-back.

  ## How detection works

  On Linux, `CLOCK_MONOTONIC` (the source for `System.monotonic_time/1`)
  is paused while the system is suspended; `CLOCK_REALTIME` (the source
  for `System.system_time/1`) keeps ticking. So if the wall-clock delta
  between two ticks is meaningfully larger than the monotonic delta,
  the BEAM was frozen — laptop suspend, hibernate, VM pause.

  ## Why this matters

  Without staggering, all overdue jobs fire at once when the queue
  resumes — drives get hammered and the first failures (commonly
  network-not-ready) burn through the retry budget set in
  `Fae.Backups.RunWorker`.

  See also `Fae.Backups.Scheduler.restage_overdue/0`.
  """

  use GenServer

  require Logger

  @tick_interval_ms 30_000
  @suspend_skew_threshold_seconds 60

  def start_link(opts \\ []) do
    if enabled?() do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @doc "Whether the watcher should run in this environment."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:fae, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @impl true
  def init(opts) do
    on_resume = Keyword.get(opts, :on_resume, &Fae.Backups.Scheduler.restage_overdue/0)
    tick_interval_ms = Keyword.get(opts, :tick_interval_ms, @tick_interval_ms)

    skew_threshold_seconds =
      Keyword.get(opts, :skew_threshold_seconds, @suspend_skew_threshold_seconds)

    state = %{
      previous: read_clocks(),
      on_resume: on_resume,
      tick_interval_ms: tick_interval_ms,
      skew_threshold_seconds: skew_threshold_seconds
    }

    schedule_tick(tick_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    current = read_clocks()
    {prev_mono, prev_wall} = state.previous
    {curr_mono, curr_wall} = current

    mono_delta = curr_mono - prev_mono
    wall_delta = curr_wall - prev_wall

    if wall_delta - mono_delta > state.skew_threshold_seconds do
      Logger.info(
        "Resume from suspend detected (wall +#{wall_delta}s, monotonic +#{mono_delta}s); " <>
          "restaging overdue backups"
      )

      state.on_resume.()
    end

    schedule_tick(state.tick_interval_ms)
    {:noreply, %{state | previous: current}}
  end

  defp read_clocks do
    {System.monotonic_time(:second), System.system_time(:second)}
  end

  defp schedule_tick(:infinity), do: :ok
  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)
end
