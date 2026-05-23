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

    test "delete removes the job", %{conn: conn} do
      dest = create_destination!()
      job = create_job!(dest)

      {:ok, view, _html} = live(conn, ~p"/backups")
      view |> element("button[phx-click='delete'][phx-value-id='#{job.id}']") |> render_click()

      refute Jobs.get(job.id)
    end

    test "run_now triggers a run (side-effect visible in run history)", %{conn: conn} do
      dest = create_destination!()
      job = create_job!(dest)

      # Oban's :inline test mode means the click runs the pipeline
      # synchronously. The source path doesn't exist so the run row
      # ends up "failed" — which is fine; we just need to see that a
      # run was attempted.
      {:ok, view, _html} = live(conn, ~p"/backups")

      view
      |> element("button[phx-click='run_now'][phx-value-id='#{job.id}']")
      |> render_click()

      assert [_ | _] = Fae.Backups.Runs.list_recent(job.id, 10)
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

  describe "JobShow" do
    test "renders job details and an empty run history", %{conn: conn} do
      dest = create_destination!()
      job = create_job!(dest)

      {:ok, _view, html} = live(conn, ~p"/backups/#{job.id}")
      assert html =~ job.name
      assert html =~ job.slug
      assert html =~ "No runs yet"
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
