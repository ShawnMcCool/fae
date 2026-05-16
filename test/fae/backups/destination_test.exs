defmodule Fae.Backups.DestinationTest do
  use Fae.DataCase, async: false

  import Mox

  alias Fae.Backups.{Destination, Destinations}
  alias Fae.Backups.Drivers.DriverMock

  setup :verify_on_exit!

  @valid_attrs %{
    name: "Hetzner Prod",
    driver: "s3",
    endpoint_url: "https://fsn1.your-objectstorage.com",
    region: "fsn1",
    bucket: "fae-backups",
    force_path_style: true,
    access_key_id: "AK",
    secret_access_key: "SK"
  }

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      assert %Ecto.Changeset{valid?: true} = Destination.changeset(%Destination{}, @valid_attrs)
    end

    test "required fields are required" do
      changeset = Destination.changeset(%Destination{}, %{})

      # `driver` defaults to "s3" so it doesn't appear as blank.
      for field <- ~w(name endpoint_url region bucket access_key_id secret_access_key)a do
        assert "can't be blank" in errors_on(changeset)[field]
      end
    end

    test "rejects unknown driver" do
      changeset = Destination.changeset(%Destination{}, %{@valid_attrs | driver: "ftp"})
      assert "is invalid" in errors_on(changeset).driver
    end

    test "rejects non-http endpoint URLs" do
      changeset =
        Destination.changeset(%Destination{}, %{@valid_attrs | endpoint_url: "fsn1.x.com"})

      assert "must start with http:// or https://" in errors_on(changeset).endpoint_url
    end

    test "enforces unique name" do
      assert {:ok, _} = Destinations.create(@valid_attrs)
      assert {:error, changeset} = Destinations.create(@valid_attrs)
      assert "has already been taken" in errors_on(changeset).name
    end
  end

  describe "path_prefix" do
    test "defaults to empty string" do
      {:ok, dest} = Destinations.create(@valid_attrs)
      assert dest.path_prefix == ""
    end

    test "accepts a value" do
      {:ok, dest} =
        Destinations.create(Map.put(@valid_attrs, :path_prefix, "fae/this-machine"))

      assert dest.path_prefix == "fae/this-machine"
    end

    test "strips leading and trailing slashes" do
      {:ok, dest} =
        Destinations.create(Map.put(@valid_attrs, :path_prefix, "/fae/this-machine/"))

      assert dest.path_prefix == "fae/this-machine"
    end

    test "strips surrounding whitespace" do
      {:ok, dest} =
        Destinations.create(Map.put(@valid_attrs, :path_prefix, "  fae/machine  "))

      assert dest.path_prefix == "fae/machine"
    end
  end

  describe "create_with_verification/1" do
    setup do
      Application.put_env(:fae, :backups_drivers, %{"s3" => DriverMock})
      on_exit(fn -> Application.delete_env(:fae, :backups_drivers) end)
      :ok
    end

    test "persists when verify returns :ok" do
      expect(DriverMock, :verify, fn _dest -> :ok end)

      assert {:ok, %Destination{name: "Hetzner Prod"}} =
               Destinations.create_with_verification(@valid_attrs)

      assert [_] = Destinations.list()
    end

    test "rejects with :unauthorized → access_key_id error" do
      expect(DriverMock, :verify, fn _dest -> {:error, :unauthorized} end)
      assert {:error, cs} = Destinations.create_with_verification(@valid_attrs)
      assert errors_on(cs).access_key_id |> Enum.any?(&(&1 =~ "rejected"))
      assert Destinations.list() == []
    end

    test "rejects with :forbidden → access_key_id error" do
      expect(DriverMock, :verify, fn _dest -> {:error, :forbidden} end)
      assert {:error, cs} = Destinations.create_with_verification(@valid_attrs)
      assert errors_on(cs).access_key_id |> Enum.any?(&(&1 =~ "lack permission"))
    end

    test "rejects with :no_bucket → bucket error" do
      expect(DriverMock, :verify, fn _dest -> {:error, :no_bucket} end)
      assert {:error, cs} = Destinations.create_with_verification(@valid_attrs)
      assert errors_on(cs).bucket |> Enum.any?(&(&1 =~ "no bucket"))
    end

    test "rejects with {:wrong_region, hint} → region error including hint" do
      expect(DriverMock, :verify, fn _dest -> {:error, {:wrong_region, "nbg1"}} end)
      assert {:error, cs} = Destinations.create_with_verification(@valid_attrs)
      assert errors_on(cs).region |> Enum.any?(&(&1 =~ "nbg1"))
    end

    test "rejects with {:network, _} → endpoint_url error" do
      expect(DriverMock, :verify, fn _dest -> {:error, {:network, :nxdomain}} end)
      assert {:error, cs} = Destinations.create_with_verification(@valid_attrs)
      assert errors_on(cs).endpoint_url |> Enum.any?(&(&1 =~ "could not reach"))
    end

    test "surfaces changeset validation errors without calling verify" do
      # No `expect` set — Mox.verify_on_exit! will fail if verify is called.
      bad_attrs = Map.put(@valid_attrs, :endpoint_url, "not-a-url")
      assert {:error, cs} = Destinations.create_with_verification(bad_attrs)
      refute cs.valid?
      assert Destinations.list() == []
    end
  end
end
