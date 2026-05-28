defmodule FaeWeb.DestinationsLiveTest do
  use FaeWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

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

  describe "Index" do
    test "renders the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/destinations")
      assert html =~ "No destinations yet"
    end

    test "lists destinations", %{conn: conn} do
      dest = create_destination!()
      {:ok, _view, html} = live(conn, ~p"/destinations")
      assert html =~ dest.name
      assert html =~ dest.endpoint_url
    end
  end

  describe "Form new" do
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

      {:ok, view, _html} = live(conn, ~p"/destinations/new")
      view |> form("form", destination: @form_attrs) |> render_submit()

      [dest | _] = Destinations.list()
      assert dest.name == "Hetzner Prod"
      assert dest.force_path_style
    end

    test "persists the Quick Archive subfolder", %{conn: conn} do
      expect(DriverMock, :verify, fn _dest -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/destinations/new")

      view
      |> form("form", destination: Map.put(@form_attrs, "quick_archive_prefix", "archive"))
      |> render_submit()

      [dest | _] = Destinations.list()
      assert dest.quick_archive_prefix == "archive"
    end

    test "refuses to create when verification fails (forbidden)", %{conn: conn} do
      expect(DriverMock, :verify, fn _dest -> {:error, :forbidden} end)

      {:ok, view, _html} = live(conn, ~p"/destinations/new")
      html = view |> form("form", destination: @form_attrs) |> render_submit()

      assert Destinations.list() == []
      assert html =~ "credentials lack permission"
    end

    test "refuses to create when bucket is missing (404)", %{conn: conn} do
      expect(DriverMock, :verify, fn _dest -> {:error, :no_bucket} end)

      {:ok, view, _html} = live(conn, ~p"/destinations/new")
      html = view |> form("form", destination: @form_attrs) |> render_submit()

      assert Destinations.list() == []
      assert html =~ "no bucket with this name"
    end

    test "refuses to create on network failure", %{conn: conn} do
      expect(DriverMock, :verify, fn _dest -> {:error, {:network, :nxdomain}} end)

      {:ok, view, _html} = live(conn, ~p"/destinations/new")
      html = view |> form("form", destination: @form_attrs) |> render_submit()

      assert Destinations.list() == []
      assert html =~ "could not reach the endpoint"
    end
  end
end
