defmodule Fae.SelfUpdate.ServiceTest do
  use ExUnit.Case, async: true

  alias Fae.SelfUpdate.Service

  describe "detected_unit/1" do
    test "returns nil when INVOCATION_ID is unset (not under systemd)" do
      env_fn = fn _ -> nil end

      cgroup_reader = fn ->
        {:ok, "0::/user.slice/user-1000.slice/user@1000.service/app.slice/fae.service\n"}
      end

      assert Service.detected_unit(env_fn: env_fn, cgroup_reader: cgroup_reader) == nil
    end

    test "parses the unit name from cgroup when INVOCATION_ID is set" do
      env_fn = fn
        "INVOCATION_ID" -> "abc123"
        _ -> nil
      end

      cgroup_reader = fn ->
        {:ok, "0::/user.slice/user-1000.slice/user@1000.service/app.slice/fae.service\n"}
      end

      assert Service.detected_unit(env_fn: env_fn, cgroup_reader: cgroup_reader) == "fae.service"
    end

    test "returns nil when cgroup file is unreadable" do
      env_fn = fn _ -> "x" end
      cgroup_reader = fn -> {:error, :enoent} end

      assert Service.detected_unit(env_fn: env_fn, cgroup_reader: cgroup_reader) == nil
    end
  end

  describe "state/1" do
    test "all-false snapshot when not under systemd and systemctl not available" do
      env_fn = fn _ -> nil end
      cgroup_reader = fn -> {:error, :enoent} end
      cmd_fn = fn _bin, _args -> {"", 1} end

      assert %{
               under_systemd: false,
               unit_name: nil,
               systemd_available: false,
               unit_installed: false,
               active: false,
               enabled: false
             } = Service.state(env_fn: env_fn, cgroup_reader: cgroup_reader, cmd_fn: cmd_fn)
    end

    test "populated snapshot when under systemd and systemctl succeeds" do
      env_fn = fn
        "INVOCATION_ID" -> "abc"
        _ -> nil
      end

      cgroup_reader = fn -> {:ok, "0::/user.slice/.../fae.service\n"} end

      cmd_fn = fn _bin, args ->
        cond do
          "show-environment" in args -> {"FOO=BAR\n", 0}
          "list-unit-files" in args -> {"fae.service enabled\n", 0}
          "is-active" in args -> {"active\n", 0}
          "is-enabled" in args -> {"enabled\n", 0}
          true -> {"", 0}
        end
      end

      state = Service.state(env_fn: env_fn, cgroup_reader: cgroup_reader, cmd_fn: cmd_fn)
      assert state.under_systemd
      assert state.unit_name == "fae.service"
      assert state.systemd_available
      assert state.unit_installed
      assert state.active
      assert state.enabled
    end
  end

  describe "restart/1" do
    test "calls systemctl --user --no-block restart with the resolved unit" do
      captured = self()

      cmd_fn = fn bin, args ->
        send(captured, {:cmd, bin, args})
        {"", 0}
      end

      :ok =
        Service.restart(
          cmd_fn: cmd_fn,
          cgroup_reader: fn ->
            {:ok, "0::/user.slice/user-1000.slice/user@1000.service/app.slice/fae.service\n"}
          end
        )

      assert_receive {:cmd, "systemctl", ["--user", "--no-block", "restart", "fae.service"]}
    end

    test "returns the structured error when systemctl exits non-zero" do
      cmd_fn = fn _bin, _args -> {"unit not found", 5} end

      assert {:error, {:systemctl_failed, 5, "unit not found"}} =
               Service.restart(cmd_fn: cmd_fn, cgroup_reader: fn -> {:error, :enoent} end)
    end
  end
end
