defmodule Fae.Backups.DriversTest do
  use ExUnit.Case, async: true

  import Mox

  alias Fae.Backups.Destination
  alias Fae.Backups.Drivers
  alias Fae.Backups.Drivers.{DriverMock, S3}

  setup :verify_on_exit!

  describe "driver_for/1" do
    test "returns Fae.Backups.Drivers.S3 by default" do
      assert Drivers.driver_for(%Destination{driver: "s3"}) == S3
    end

    test "uses :fae, :backups_drivers config override" do
      Application.put_env(:fae, :backups_drivers, %{"s3" => DriverMock})

      try do
        assert Drivers.driver_for(%Destination{driver: "s3"}) == DriverMock
      after
        Application.delete_env(:fae, :backups_drivers)
      end
    end
  end

  describe "S3.parse_list/1" do
    @list_xml """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult>
      <Name>fae-backups</Name>
      <Prefix>fae-db/</Prefix>
      <KeyCount>2</KeyCount>
      <IsTruncated>false</IsTruncated>
      <Contents>
        <Key>fae-db/20260516T030000Z.tar.gz</Key>
        <LastModified>2026-05-16T03:00:01.000Z</LastModified>
        <ETag>"abc"</ETag>
        <Size>12345</Size>
        <StorageClass>STANDARD</StorageClass>
      </Contents>
      <Contents>
        <Key>fae-db/20260515T030000Z.tar.gz</Key>
        <LastModified>2026-05-15T03:00:01.000Z</LastModified>
        <ETag>"def"</ETag>
        <Size>12000</Size>
        <StorageClass>STANDARD</StorageClass>
      </Contents>
    </ListBucketResult>
    """

    test "parses Contents into objects" do
      {objects, next_token} = S3.parse_list(@list_xml)
      assert next_token == nil

      assert [%{key: k1, size: 12_345}, %{key: k2, size: 12_000}] = objects
      assert k1 == "fae-db/20260516T030000Z.tar.gz"
      assert k2 == "fae-db/20260515T030000Z.tar.gz"

      assert %DateTime{year: 2026, month: 5, day: 16} = hd(objects).last_modified
    end

    test "extracts NextContinuationToken when present" do
      truncated =
        String.replace(
          @list_xml,
          "<IsTruncated>false</IsTruncated>",
          "<IsTruncated>true</IsTruncated><NextContinuationToken>opaque-token</NextContinuationToken>"
        )

      {_objects, next_token} = S3.parse_list(truncated)
      assert next_token == "opaque-token"
    end

    test "returns empty list when no Contents" do
      empty = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <Name>bucket</Name>
        <KeyCount>0</KeyCount>
        <IsTruncated>false</IsTruncated>
      </ListBucketResult>
      """

      assert {[], nil} = S3.parse_list(empty)
    end
  end
end
