defmodule Fae.SelfUpdate.HandoffTest do
  use ExUnit.Case, async: true

  alias Fae.SelfUpdate.Handoff

  test "spawn_detached passes the installer + log path as positional argv, not in the script body" do
    captured = self()

    spawn_fn = fn args ->
      send(captured, {:argv, args})
      :ok
    end

    env_getter = fn
      "XDG_RUNTIME_DIR" -> "/run/user/1000"
      "DBUS_SESSION_BUS_ADDRESS" -> "unix:path=/run/user/1000/bus"
      _ -> nil
    end

    :ok =
      Handoff.spawn_detached("/staged/root",
        spawn_fn: spawn_fn,
        home: "/home/shawn",
        env_getter: env_getter
      )

    assert_receive {:argv, args}

    # The script body is just a parameterised shell template; the
    # installer and log path are positional args after `--`.
    assert "/staged/root/bin/fae-install" in args
    assert "/staged/root/handoff.log" in args

    # Environment hardening: env -i with explicit HOME + minimal PATH,
    # plus the systemd-required passthrough vars.
    assert "env" in args
    assert "-i" in args
    assert "HOME=/home/shawn" in args
    assert "PATH=/usr/bin:/bin" in args
    assert "XDG_RUNTIME_DIR=/run/user/1000" in args
    assert "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus" in args

    # Detachment: setsid --fork before sh -c
    assert "setsid" in args
    assert "--fork" in args
    assert "sh" in args
    assert "-c" in args
  end

  test "omits passthrough env vars that aren't set in the caller's environment" do
    captured = self()

    spawn_fn = fn args ->
      send(captured, {:argv, args})
      :ok
    end

    env_getter = fn _ -> nil end

    :ok =
      Handoff.spawn_detached("/staged",
        spawn_fn: spawn_fn,
        home: "/home/shawn",
        env_getter: env_getter
      )

    assert_receive {:argv, args}
    refute Enum.any?(args, &String.starts_with?(&1, "XDG_RUNTIME_DIR="))
    refute Enum.any?(args, &String.starts_with?(&1, "DBUS_SESSION_BUS_ADDRESS="))
  end
end
