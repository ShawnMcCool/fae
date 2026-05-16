defmodule Fae.Backups.DestinationTest do
  use Fae.DataCase, async: false

  alias Fae.Backups.{Destination, Destinations}

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
end
