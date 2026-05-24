defmodule FaeWeb.BackupsLiveTest do
  use FaeWeb.ConnCase, async: false
  use Oban.Testing, repo: Fae.Repo

  import Mox
  import Phoenix.LiveViewTest

  alias Fae.Backups.Jobs
  alias Fae.Storage.Destinations
  alias Fae.Storage.Drivers.DriverMock

  setup :verify_on_exit!
  setup :set_mox_global

  defp create_destination! do
    {:ok, dest} =
      Destinations.create(%{
        name: "Test #{System.unique_integer()}",
        driver: "s3",
        endpoint_url: "https://example.com",
        region: "us",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: "s"
      })

    dest
  end

  defp create_job!(destination, overrides \\ %{}) do
    {:ok, job} =
      Jobs.create(
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
          overrides
        )
      )

    job
  end

  describe "Index" do
    test "renders 'no jobs' empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "Backup jobs"
      assert html =~ "No backup jobs yet"
    end

    test "lists jobs", %{conn: conn} do
      dest = create_destination!()
      job = create_job!(dest)

      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ job.name
      assert html =~ job.slug
      assert html =~ "Daily at 03:00"
    end

    test "the per-row browse button opens a view-only remote browser", %{conn: conn} do
      Application.put_env(:fae, :storage_drivers, %{"s3" => DriverMock})
      on_exit(fn -> Application.delete_env(:fae, :storage_drivers) end)

      dest = create_destination!()
      job = create_job!(dest, %{prefix: "Family", slug: "daily-db"})

      stub(DriverMock, :list_prefixes, fn _dest, prefix ->
        assert prefix == "Family/daily-db/"

        {:ok,
         %{
           prefixes: [],
           files: [
             %{
               key: "Family/daily-db/2026-05-01.tar.gz",
               size: 2048,
               last_modified: ~U[2026-05-01 12:00:00Z]
             }
           ]
         }}
      end)

      {:ok, view, _html} = live(conn, ~p"/backups")

      view
      |> element("button[phx-click='open_browser'][phx-value-id='#{job.id}']")
      |> render_click()

      html = render_async(view)

      assert html =~ "2026-05-01.tar.gz"
      assert html =~ "2.0 KiB"
      refute html =~ "Use this folder"
    end
  end

  describe "DestinationsIndex" do
    test "renders the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups/destinations")
      assert html =~ "No destinations yet"
    end

    test "lists destinations", %{conn: conn} do
      dest = create_destination!()
      {:ok, _view, html} = live(conn, ~p"/backups/destinations")
      assert html =~ dest.name
      assert html =~ dest.endpoint_url
    end
  end

  describe "JobForm new" do
    test "blocks creation when there are no destinations", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups/new")
      assert html =~ "No destinations configured"
    end

    test "creates a job", %{conn: conn} do
      dest = create_destination!()
      {:ok, view, _html} = live(conn, ~p"/backups/new")

      view
      |> form("form",
        job: %{
          "name" => "Fae DB",
          "slug" => "fae-db",
          "source_kind" => "sqlite",
          "source_path" => "/home/me/.local/share/fae/fae.db",
          "destination_id" => dest.id,
          "package_format" => "as_is",
          "recurrence_kind" => "daily",
          "time_of_day" => "03:00",
          "retention_strategy" => "keep_last_n",
          "retention_n" => "10"
        }
      )
      |> render_submit()

      assert Jobs.get_by_slug("fae-db")
    end
  end

  describe "JobForm edit" do
    # Regression: editing a job whose strategy isn't keep_last_n then
    # triggering validate crashed with `KeyError key :retention_n` because
    # the edit mount only assigned the active strategy's retention input,
    # while the validate path reads every retention_* assign as a fallback.
    test "editing a keep_for_days job and validating does not crash", %{conn: conn} do
      dest = create_destination!()

      job =
        create_job!(dest, %{
          retention_strategy: "keep_for_days",
          retention_params: %{"days" => 14}
        })

      {:ok, view, html} = live(conn, ~p"/backups/#{job.id}/edit")
      assert html =~ "Edit backup job"

      html = view |> form("form", job: %{"name" => "Renamed Job"}) |> render_change()
      assert html =~ ~s(name="job[retention_days]")
    end

    test "editing a gfs job and validating does not crash", %{conn: conn} do
      dest = create_destination!()

      job =
        create_job!(dest, %{
          retention_strategy: "gfs",
          retention_params: %{"daily" => 7, "weekly" => 4, "monthly" => 12}
        })

      {:ok, view, _html} = live(conn, ~p"/backups/#{job.id}/edit")

      html = view |> form("form", job: %{"name" => "Renamed Job"}) |> render_change()
      assert html =~ "Daily buckets"
    end

    test "editing a keep_last_n job and validating does not crash", %{conn: conn} do
      dest = create_destination!()
      job = create_job!(dest, %{retention_strategy: "keep_last_n", retention_params: %{"n" => 5}})

      {:ok, view, _html} = live(conn, ~p"/backups/#{job.id}/edit")

      html = view |> form("form", job: %{"name" => "Renamed Job"}) |> render_change()
      assert html =~ ~s(name="job[retention_n]")
    end
  end

  describe "JobShow" do
    test "renders job details and an empty run history", %{conn: conn} do
      dest = create_destination!()
      job = create_job!(dest)

      {:ok, _view, html} = live(conn, ~p"/backups/#{job.id}")
      assert html =~ job.name
      assert html =~ job.slug
      assert html =~ "No runs yet"
    end

    test "opens a view-only remote browser scoped to the job's prefix", %{conn: conn} do
      Application.put_env(:fae, :storage_drivers, %{"s3" => DriverMock})
      on_exit(fn -> Application.delete_env(:fae, :storage_drivers) end)

      dest = create_destination!()
      job = create_job!(dest, %{prefix: "Family", slug: "daily-db"})

      # Expect a listing relative to the destination prefix at
      # "<job.prefix>/<job.slug>/", i.e. "Family/daily-db/".
      stub(DriverMock, :list_prefixes, fn _dest, prefix ->
        assert prefix == "Family/daily-db/"

        {:ok,
         %{
           prefixes: [],
           files: [
             %{
               key: "Family/daily-db/2026-05-01.tar.gz",
               size: 2048,
               last_modified: ~U[2026-05-01 12:00:00Z]
             }
           ]
         }}
      end)

      {:ok, view, _html} = live(conn, ~p"/backups/#{job.id}")

      view |> element("button", "Browse backups") |> render_click()
      html = render_async(view)

      assert html =~ "2026-05-01.tar.gz"
      assert html =~ "2.0 KiB"
      # View-only: no selection affordance.
      refute html =~ "Use this folder"
    end

    test "run_now triggers a run (side-effect visible in run history)", %{conn: conn} do
      dest = create_destination!()
      job = create_job!(dest)

      # Oban's :inline test mode means the click runs the pipeline
      # synchronously. The source path doesn't exist so the run row
      # ends up "failed" — which is fine; we just need to see that a
      # run was attempted.
      {:ok, view, _html} = live(conn, ~p"/backups/#{job.id}")

      view
      |> element("button[phx-click='run_now'][phx-value-id='#{job.id}']")
      |> render_click()

      assert [_ | _] = Fae.Backups.Runs.list_recent(job.id, 10)
    end

    test "delete removes the job and returns to the index", %{conn: conn} do
      dest = create_destination!()
      job = create_job!(dest)

      {:ok, view, _html} = live(conn, ~p"/backups/#{job.id}")

      assert {:error, {:live_redirect, %{to: "/backups"}}} =
               view |> element("button[phx-click='delete']") |> render_click()

      refute Jobs.get(job.id)
    end
  end

  describe "DestinationForm new" do
    setup do
      Application.put_env(:fae, :storage_drivers, %{"s3" => DriverMock})
      on_exit(fn -> Application.delete_env(:fae, :storage_drivers) end)
      :ok
    end

    @form_attrs %{
      "name" => "Hetzner Prod",
      "driver" => "s3",
      "endpoint_url" => "https://fsn1.your-objectstorage.com",
      "region" => "fsn1",
      "bucket" => "fae-backups",
      "force_path_style" => "true",
      "access_key_id" => "AK",
      "secret_access_key" => "SK"
    }

    test "creates a destination when the driver verifies successfully", %{conn: conn} do
      expect(DriverMock, :verify, fn _dest -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/backups/destinations/new")
      view |> form("form", destination: @form_attrs) |> render_submit()

      [dest | _] = Destinations.list()
      assert dest.name == "Hetzner Prod"
      assert dest.force_path_style
    end

    test "refuses to create when verification fails (forbidden)", %{conn: conn} do
      expect(DriverMock, :verify, fn _dest -> {:error, :forbidden} end)

      {:ok, view, _html} = live(conn, ~p"/backups/destinations/new")
      html = view |> form("form", destination: @form_attrs) |> render_submit()

      assert Destinations.list() == []
      assert html =~ "credentials lack permission"
    end

    test "refuses to create when bucket is missing (404)", %{conn: conn} do
      expect(DriverMock, :verify, fn _dest -> {:error, :no_bucket} end)

      {:ok, view, _html} = live(conn, ~p"/backups/destinations/new")
      html = view |> form("form", destination: @form_attrs) |> render_submit()

      assert Destinations.list() == []
      assert html =~ "no bucket with this name"
    end

    test "refuses to create on network failure", %{conn: conn} do
      expect(DriverMock, :verify, fn _dest -> {:error, {:network, :nxdomain}} end)

      {:ok, view, _html} = live(conn, ~p"/backups/destinations/new")
      html = view |> form("form", destination: @form_attrs) |> render_submit()

      assert Destinations.list() == []
      assert html =~ "could not reach the endpoint"
    end
  end
end
