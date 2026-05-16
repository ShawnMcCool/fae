defmodule Fae.VersionTest do
  use ExUnit.Case, async: true

  alias Fae.Version, as: V

  describe "compare_versions/2" do
    test "returns :gt when remote is newer" do
      assert V.compare_versions("1.2.0", "1.1.9") == :gt
    end

    test "returns :eq when versions match" do
      assert V.compare_versions("1.0.0", "1.0.0") == :eq
    end

    test "returns :lt when remote is older" do
      assert V.compare_versions("0.9.0", "1.0.0") == :lt
    end

    test "strips leading v from either side" do
      assert V.compare_versions("v1.2.0", "v1.1.9") == :gt
      assert V.compare_versions("v1.0.0", "1.0.0") == :eq
    end

    test "returns :error for malformed versions" do
      assert V.compare_versions("not-a-version", "1.0.0") == :error
      assert V.compare_versions("1.0.0", "garbage") == :error
    end
  end

  describe "current_version/0" do
    test "returns the running app's version as a string" do
      version = V.current_version()
      assert is_binary(version)
      assert version != "0.0.0", "expected mix.exs version, got the fallback"
      assert Regex.match?(~r/^\d+\.\d+\.\d+/, version)
    end
  end
end
