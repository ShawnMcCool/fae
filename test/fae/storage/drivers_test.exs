defmodule Fae.Storage.DriversTest do
  use ExUnit.Case, async: true

  import Mox

  alias Fae.Storage.Destination
  alias Fae.Storage.Drivers
  alias Fae.Storage.Drivers.{DriverMock, S3}

  setup :verify_on_exit!

  describe "driver_for/1" do
    test "returns Fae.Storage.Drivers.S3 by default" do
      assert Drivers.driver_for(%Destination{driver: "s3"}) == S3
    end

    test "uses :fae, :storage_drivers config override" do
      Application.put_env(:fae, :storage_drivers, %{"s3" => DriverMock})

      try do
        assert Drivers.driver_for(%Destination{driver: "s3"}) == DriverMock
      after
        Application.delete_env(:fae, :storage_drivers)
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

  describe "S3 multipart helpers" do
    test "parse_upload_id extracts the upload id" do
      xml =
        ~s(<?xml version="1.0"?><InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><UploadId>abc-123</UploadId></InitiateMultipartUploadResult>)

      assert S3.parse_upload_id(xml) == "abc-123"
    end

    test "parse_upload_id returns nil when absent" do
      assert S3.parse_upload_id("<Error/>") == nil
    end

    test "parse_complete_etag extracts the final etag (quotes preserved)" do
      xml =
        ~s(<CompleteMultipartUploadResult><Location>x</Location><ETag>"deadbeef-2"</ETag></CompleteMultipartUploadResult>)

      assert S3.parse_complete_etag(xml) == ~s("deadbeef-2")
    end

    test "build_complete_xml lists parts in order with their etags" do
      xml = S3.build_complete_xml([{1, ~s("a")}, {2, ~s("b")}])

      assert xml ==
               ~s(<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>"a"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>"b"</ETag></Part></CompleteMultipartUpload>)
    end
  end

  describe "S3.parse_prefixes/1" do
    @delimited_xml """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult>
      <Name>bucket</Name>
      <Prefix>Family/</Prefix>
      <Delimiter>/</Delimiter>
      <IsTruncated>false</IsTruncated>
      <Contents>
        <Key>Family/readme.txt</Key>
        <Size>3</Size>
      </Contents>
      <CommonPrefixes><Prefix>Family/Pictures Videos/</Prefix></CommonPrefixes>
      <CommonPrefixes><Prefix>Family/Documents/</Prefix></CommonPrefixes>
    </ListBucketResult>
    """

    test "extracts common prefixes (folders) and keys (files) at one level" do
      {prefixes, keys, next_token} = S3.parse_prefixes(@delimited_xml)
      assert prefixes == ["Family/Pictures Videos/", "Family/Documents/"]
      assert keys == ["Family/readme.txt"]
      assert next_token == nil
    end

    test "extracts the continuation token when truncated" do
      truncated =
        String.replace(
          @delimited_xml,
          "<IsTruncated>false</IsTruncated>",
          "<IsTruncated>true</IsTruncated><NextContinuationToken>tok-1</NextContinuationToken>"
        )

      {_prefixes, _keys, next_token} = S3.parse_prefixes(truncated)
      assert next_token == "tok-1"
    end
  end
end
