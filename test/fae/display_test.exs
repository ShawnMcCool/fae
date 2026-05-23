defmodule Fae.DisplayTest do
  # async: false — writes go through Fae.Settings, which shares a PubSub
  # topic and a DB table across the suite.
  use Fae.DataCase, async: false

  alias Fae.Display

  describe "timezone/0" do
    test "defaults to UTC when nothing is stored" do
      assert Display.timezone() == "UTC"
    end

    test "returns the stored timezone after put_timezone/1" do
      {:ok, "Europe/Amsterdam"} = Display.put_timezone("Europe/Amsterdam")
      assert Display.timezone() == "Europe/Amsterdam"
    end
  end

  describe "put_timezone/1" do
    test "rejects an unknown zone and leaves the current value untouched" do
      assert {:error, :invalid_timezone} = Display.put_timezone("Mars/Phobos")
      assert Display.timezone() == "UTC"
    end

    test "broadcasts a settings change on the \"settings\" topic" do
      :ok = Fae.Settings.subscribe()
      {:ok, _} = Display.put_timezone("America/New_York")
      assert_receive {:setting_changed, "display", %{"timezone" => "America/New_York"}}
    end
  end

  describe "valid_timezone?/1" do
    test "accepts UTC and a real IANA zone, rejects junk" do
      assert Display.valid_timezone?("UTC")
      assert Display.valid_timezone?("Europe/Amsterdam")
      refute Display.valid_timezone?("Mars/Phobos")
      refute Display.valid_timezone?(nil)
    end
  end

  describe "zone_options/0" do
    test "is a non-empty list that includes a known zone" do
      options = Display.zone_options()
      assert is_list(options)
      assert "Europe/Amsterdam" in options
    end
  end
end
