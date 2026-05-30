defmodule Fae.SelfUpdate.UpdateCheckerTest do
  # Not async: writes the VM-global :persistent_term cache ({UpdateChecker,
  # :cache} / :client), which is shared across modules — running async races
  # other SelfUpdate tests that read/write it (e.g. StorageTest).
  use ExUnit.Case, async: false

  alias Fae.SelfUpdate.UpdateChecker

  defp stub_client(fun) do
    Req.new(base_url: "https://api.github.com", plug: fun)
  end

  describe "validate_tag/1" do
    test "accepts standard semver" do
      assert UpdateChecker.validate_tag("v1.2.3") == :ok
      assert UpdateChecker.validate_tag("v0.0.0") == :ok
      assert UpdateChecker.validate_tag("v10.20.30") == :ok
    end

    test "accepts prerelease suffix" do
      assert UpdateChecker.validate_tag("v1.2.3-rc.1") == :ok
      assert UpdateChecker.validate_tag("v1.2.3-alpha") == :ok
    end

    test "rejects anything else" do
      for bad <- ["1.2.3", "vX.Y.Z", "v1.2", "v1.2.3.4", "v1.2.3;rm -rf /", "../etc/passwd"] do
        assert UpdateChecker.validate_tag(bad) == {:error, :invalid_tag},
               "expected #{bad} to be rejected"
      end
    end
  end

  describe "compare/2" do
    test "classifies a newer remote as :update_available" do
      release = %{version: "1.1.0", tag: "v1.1.0"}
      assert UpdateChecker.compare(release, "1.0.0") == :update_available
    end

    test "classifies equal versions as :up_to_date" do
      release = %{version: "1.0.0", tag: "v1.0.0"}
      assert UpdateChecker.compare(release, "1.0.0") == :up_to_date
    end

    test "classifies an older remote as :ahead_of_release" do
      release = %{version: "0.9.0", tag: "v0.9.0"}
      assert UpdateChecker.compare(release, "1.0.0") == :ahead_of_release
    end
  end

  describe "latest_release/1 with a stubbed client" do
    test "returns a normalised release map on 200" do
      client =
        stub_client(fn conn ->
          Req.Test.json(conn, %{
            "tag_name" => "v1.0.0",
            "published_at" => "2026-05-16T12:00:00Z",
            "html_url" => "https://github.com/ShawnMcCool/fae/releases/tag/v1.0.0",
            "body" => "Initial release"
          })
        end)

      assert {:ok, release} = UpdateChecker.latest_release(client)
      assert release.version == "1.0.0"
      assert release.tag == "v1.0.0"
      assert release.body == "Initial release"
      assert %DateTime{} = release.published_at
    end

    test "rejects an invalid tag at the parse step" do
      client =
        stub_client(fn conn ->
          Req.Test.json(conn, %{
            "tag_name" => "v1.2.3;rm",
            "published_at" => "2026-05-16T12:00:00Z"
          })
        end)

      assert {:error, :invalid_tag} = UpdateChecker.latest_release(client)
    end

    test "rewrites an attacker-controlled html_url to the canonical repo path" do
      client =
        stub_client(fn conn ->
          Req.Test.json(conn, %{
            "tag_name" => "v1.0.0",
            "published_at" => "2026-05-16T12:00:00Z",
            "html_url" => "https://evil.example/releases/tag/v1.0.0"
          })
        end)

      assert {:ok, release} = UpdateChecker.latest_release(client)
      assert release.html_url == "https://github.com/ShawnMcCool/fae/releases/tag/v1.0.0"
    end

    test "caps body at 20KB" do
      huge_body = String.duplicate("x", 25_000)

      client =
        stub_client(fn conn ->
          Req.Test.json(conn, %{
            "tag_name" => "v1.0.0",
            "published_at" => "2026-05-16T12:00:00Z",
            "body" => huge_body
          })
        end)

      assert {:ok, release} = UpdateChecker.latest_release(client)
      assert byte_size(release.body) == 20_000
    end

    test "returns {:error, :not_found} on 404" do
      client =
        stub_client(fn conn ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
        end)

      assert {:error, :not_found} = UpdateChecker.latest_release(client)
    end

    test "returns {:error, :malformed} when tag_name is absent" do
      client =
        stub_client(fn conn ->
          Req.Test.json(conn, %{"name" => "no tag here"})
        end)

      assert {:error, :malformed} = UpdateChecker.latest_release(client)
    end

    test "detects rate-limit on 403 with x-ratelimit-remaining: 0" do
      client =
        stub_client(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
          |> Plug.Conn.put_resp_header("x-ratelimit-reset", "1747400000")
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(%{"message" => "API rate limit exceeded"})
        end)

      assert {:error, {:rate_limited, %DateTime{}}} = UpdateChecker.latest_release(client)
    end
  end

  describe "cache" do
    setup do
      UpdateChecker.clear_cache()
      on_exit(fn -> UpdateChecker.clear_cache() end)
      :ok
    end

    test "starts stale" do
      assert UpdateChecker.cached_latest_release() == :stale
    end

    test "cache_result then cached_latest_release returns the cached value" do
      release = %{
        version: "1.0.0",
        tag: "v1.0.0",
        published_at: DateTime.utc_now(),
        html_url: "",
        body: ""
      }

      :ok = UpdateChecker.cache_result({:ok, release})

      assert {:fresh, {:ok, ^release}} = UpdateChecker.cached_latest_release()
    end
  end
end
