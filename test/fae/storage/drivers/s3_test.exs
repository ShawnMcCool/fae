defmodule Fae.Storage.Drivers.S3Test do
  use ExUnit.Case, async: true

  alias Fae.Storage.Drivers.S3

  describe "parse_prefixes/1" do
    test "extracts sub-folders and files with size and last-modified" do
      xml = """
      <ListBucketResult>
        <CommonPrefixes><Prefix>lp/a/</Prefix></CommonPrefixes>
        <Contents>
          <Key>lp/top.txt</Key>
          <LastModified>2026-05-01T12:00:00.000Z</LastModified>
          <Size>42</Size>
        </Contents>
      </ListBucketResult>
      """

      {prefixes, files, next} = S3.parse_prefixes(xml)

      assert prefixes == ["lp/a/"]
      assert [%{key: "lp/top.txt", size: 42, last_modified: %DateTime{} = dt}] = files
      assert DateTime.to_date(dt) == ~D[2026-05-01]
      assert next == nil
    end

    test "returns a continuation token when present" do
      xml = """
      <ListBucketResult>
        <NextContinuationToken>tok</NextContinuationToken>
      </ListBucketResult>
      """

      assert {[], [], "tok"} = S3.parse_prefixes(xml)
    end
  end
end
