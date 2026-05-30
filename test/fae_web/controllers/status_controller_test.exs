defmodule FaeWeb.StatusControllerTest do
  # Not async: the endpoint's snapshot reads global, non-sandboxed process
  # state (SystemStatus + the SelfUpdate/UpdateChecker :persistent_term cache),
  # which would race tests asserting on it — see StatusTest.
  use FaeWeb.ConnCase, async: false

  alias Fae.Backups.{Jobs, Runs}
  alias Fae.Storage.Destinations

  describe "GET /api/status" do
    test "returns 200 with a JSON status snapshot", %{conn: conn} do
      conn = get(conn, "/api/status")

      assert conn.status == 200
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      body = json_response(conn, 200)
      assert body["schema"] == 1

      for key <- ["generated_at", "health", "system", "backups", "activity", "dotfiles"] do
        assert Map.has_key?(body, key), "expected top-level key #{key}"
      end
    end

    test "reflects a seeded enabled job and its last run", %{conn: conn} do
      destination = create_destination!()
      job = create_job!(destination)
      {:ok, _run} = Runs.start(job.id, ~U[2026-05-30 06:00:00.000000Z])

      body = conn |> get("/api/status") |> json_response(200)

      row = Enum.find(body["backups"]["jobs"], &(&1["id"] == job.id))
      assert row, "expected the seeded job to appear in backups.jobs"
      assert row["name"] == job.name
      assert row["status"] == "running"
      assert body["backups"]["enabled_count"] >= 1
    end
  end

  defp create_destination!(overrides \\ []) do
    attrs =
      Map.merge(
        %{
          name: "Test Dest #{System.unique_integer([:positive])}",
          driver: "s3",
          endpoint_url: "https://example.com",
          region: "us",
          bucket: "test-bucket",
          access_key_id: "k",
          secret_access_key: "s"
        },
        Map.new(overrides)
      )

    {:ok, destination} = Destinations.create(attrs)
    destination
  end

  defp create_job!(destination, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          name: "Daily Fae DB",
          slug: "daily-fae-db-#{System.unique_integer([:positive])}",
          source_kind: "file",
          source_path: "/tmp/fae.db",
          destination_id: destination.id,
          package_format: "as_is",
          recurrence_kind: "daily",
          time_of_day: "03:00",
          retention_strategy: "keep_last_n",
          retention_params: %{"n" => 7}
        },
        Map.new(overrides)
      )

    {:ok, job} = Jobs.create(attrs)
    job
  end
end
