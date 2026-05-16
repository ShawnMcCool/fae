defmodule Fae.SystemStatusTest do
  # async: false — tests broadcast on a shared PubSub topic; parallel tests
  # would observe each other's messages.
  use ExUnit.Case, async: false

  alias Fae.SystemStatus

  describe "get_state/1" do
    test "after start, returns boot_at as a DateTime and uptime_seconds 0" do
      pid = start_supervised!({SystemStatus, name: nil, tick_interval_ms: :infinity})

      assert %{boot_at: %DateTime{}, uptime_seconds: 0} = SystemStatus.get_state(pid)
    end
  end

  describe "tick/1" do
    test "increments uptime_seconds by one" do
      pid = start_supervised!({SystemStatus, name: nil, tick_interval_ms: :infinity})
      assert %{uptime_seconds: 0} = SystemStatus.get_state(pid)

      SystemStatus.tick(pid)

      assert %{uptime_seconds: 1} = SystemStatus.get_state(pid)
    end

    test "broadcasts current state to subscribers on Fae.PubSub" do
      pid = start_supervised!({SystemStatus, name: nil, tick_interval_ms: :infinity})
      :ok = SystemStatus.subscribe()

      SystemStatus.tick(pid)

      assert_receive {:system_status, %{boot_at: %DateTime{}, uptime_seconds: 1}}
    end
  end

  describe "automatic ticking" do
    test "ticks repeatedly at the configured interval without manual prodding" do
      :ok = SystemStatus.subscribe()
      start_supervised!({SystemStatus, name: nil, tick_interval_ms: 10})

      assert_receive {:system_status, %{uptime_seconds: 1}}, 200
      assert_receive {:system_status, %{uptime_seconds: 2}}, 200
    end
  end
end
