defmodule Fae.SettingsTest do
  # async: false — exercises a shared PubSub topic, and parallel tests would
  # observe each other's broadcasts.
  use Fae.DataCase, async: false

  alias Fae.Settings

  describe "put/2 and get_by_key/1" do
    test "put inserts when key is new" do
      assert {:ok, _entry} = Settings.put("test.key.new", %{"v" => 1})
      assert {:ok, %{value: %{"v" => 1}}} = Settings.get_by_key("test.key.new")
    end

    test "put updates value when key already exists" do
      {:ok, %{id: id}} = Settings.put("test.key.update", %{"v" => 1})
      {:ok, %{id: ^id}} = Settings.put("test.key.update", %{"v" => 2})

      assert {:ok, %{value: %{"v" => 2}}} = Settings.get_by_key("test.key.update")
    end

    test "get_by_key returns nil for an unknown key" do
      assert {:ok, nil} = Settings.get_by_key("test.key.nonexistent.#{System.unique_integer()}")
    end
  end

  describe "delete/1" do
    test "removes the entry and is idempotent" do
      {:ok, _} = Settings.put("test.key.delete", %{"v" => 1})
      assert :ok = Settings.delete("test.key.delete")
      assert {:ok, nil} = Settings.get_by_key("test.key.delete")

      # Idempotent — deleting again is a no-op
      assert :ok = Settings.delete("test.key.delete")
    end
  end

  describe "broadcast" do
    test "put broadcasts {:setting_changed, key, value} on the settings topic" do
      :ok = Settings.subscribe()

      Settings.put("test.key.broadcast.put", %{"v" => 1})

      assert_receive {:setting_changed, "test.key.broadcast.put", %{"v" => 1}}
    end

    test "delete broadcasts {:setting_changed, key, nil}" do
      {:ok, _} = Settings.put("test.key.broadcast.delete", %{"v" => 1})
      :ok = Settings.subscribe()

      Settings.delete("test.key.broadcast.delete")

      assert_receive {:setting_changed, "test.key.broadcast.delete", nil}
    end
  end
end
