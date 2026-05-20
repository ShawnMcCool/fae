defmodule Fae.Backups.SuspendWatcherTest do
  use ExUnit.Case, async: true

  alias Fae.Backups.SuspendWatcher

  defp start_watcher(opts) do
    # Disable auto-tick by default; tests send :tick manually to control
    # timing. Bypass `enabled?()` (disabled in test config) by starting
    # the GenServer directly, mirroring NotifierTest.
    opts = Keyword.put_new(opts, :tick_interval_ms, :infinity)
    {:ok, pid} = GenServer.start_link(SuspendWatcher, opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  describe "tick handling" do
    test "invokes on_resume callback when wall-clock skew exceeds the threshold" do
      parent = self()
      on_resume = fn -> send(parent, :resumed) end

      pid = start_watcher(on_resume: on_resume, skew_threshold_seconds: 10)

      # Replace previous reading with a synthetic one that makes the
      # next read look like a large wall-clock jump with no monotonic
      # progress — exactly the post-suspend signature.
      {curr_mono, curr_wall} =
        {System.monotonic_time(:second), System.system_time(:second)}

      synthetic_previous = {curr_mono, curr_wall - 120}
      :sys.replace_state(pid, fn state -> %{state | previous: synthetic_previous} end)

      send(pid, :tick)

      assert_receive :resumed, 200
    end

    test "does not invoke on_resume on normal ticks (no skew)" do
      parent = self()
      on_resume = fn -> send(parent, :resumed) end

      pid = start_watcher(on_resume: on_resume, skew_threshold_seconds: 10)

      send(pid, :tick)

      refute_receive :resumed, 100
    end

    test "does not invoke on_resume when wall-monotonic skew is below threshold" do
      parent = self()
      on_resume = fn -> send(parent, :resumed) end

      pid = start_watcher(on_resume: on_resume, skew_threshold_seconds: 60)

      {curr_mono, curr_wall} =
        {System.monotonic_time(:second), System.system_time(:second)}

      # 30s of wall skew with no monotonic progress — under the 60s threshold.
      synthetic_previous = {curr_mono, curr_wall - 30}
      :sys.replace_state(pid, fn state -> %{state | previous: synthetic_previous} end)

      send(pid, :tick)

      refute_receive :resumed, 100
    end
  end
end
