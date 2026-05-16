defmodule Fae.Backups.RunRegistryTest do
  use ExUnit.Case, async: true

  alias Fae.Backups.RunRegistry

  defp unique_id, do: Ecto.UUID.generate()

  test "register/1 returns :ok the first time" do
    assert :ok = RunRegistry.register(unique_id())
  end

  test "running?/1 reflects registration state" do
    id = unique_id()
    refute RunRegistry.running?(id)
    :ok = RunRegistry.register(id)
    assert RunRegistry.running?(id)
    RunRegistry.unregister(id)
    refute RunRegistry.running?(id)
  end

  test "second register from a different process returns {:error, :overlap}" do
    id = unique_id()
    parent = self()

    pid =
      spawn(fn ->
        :ok = RunRegistry.register(id)
        send(parent, :locked)

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end
      end)

    assert_receive :locked
    assert {:error, :overlap} = RunRegistry.register(id)

    send(pid, :release)
  end

  test "lock is auto-released when the holder process exits" do
    id = unique_id()
    parent = self()

    pid =
      spawn(fn ->
        :ok = RunRegistry.register(id)
        send(parent, :locked)
      end)

    assert_receive :locked
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert :ok = RunRegistry.register(id)
  end
end
