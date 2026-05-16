defmodule Fae.SelfUpdate.DownloaderTest do
  use ExUnit.Case, async: true

  alias Fae.SelfUpdate.Downloader

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "fae-downloader-test-#{name}-#{System.unique_integer()}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp stub_client(routes) when is_map(routes) do
    Req.new(
      plug: fn conn ->
        case Map.get(routes, conn.request_path) do
          nil ->
            Plug.Conn.send_resp(conn, 404, "not found")

          {status, body} ->
            conn |> Plug.Conn.put_status(status) |> Req.Test.text(body)
        end
      end
    )
  end

  describe "run/3 — success path" do
    test "downloads, verifies checksum, writes the tarball" do
      target = tmp_dir("ok")
      filename = "fae-1.0.0-linux-x86_64.tar.gz"
      tarball = "totally-not-a-real-tarball"
      sha = sha256_hex(tarball)
      sums = "#{sha}  #{filename}\n"

      client =
        stub_client(%{
          "/tarball" => {200, tarball},
          "/sums" => {200, sums}
        })

      assert {:ok, %{tarball_path: path, sha256: ^sha}} =
               Downloader.run("http://x/tarball", "http://x/sums",
                 target_dir: target,
                 filename: filename,
                 client: client
               )

      assert File.read!(path) == tarball
    end

    test "accepts the binary-mode SHA format (`*filename`)" do
      target = tmp_dir("binmode")
      filename = "fae-1.0.0-linux-x86_64.tar.gz"
      tarball = "anything"
      sha = sha256_hex(tarball)
      sums = "#{sha} *#{filename}\n"

      client =
        stub_client(%{
          "/tarball" => {200, tarball},
          "/sums" => {200, sums}
        })

      assert {:ok, _} =
               Downloader.run("http://x/tarball", "http://x/sums",
                 target_dir: target,
                 filename: filename,
                 client: client
               )
    end
  end

  describe "run/3 — failure paths" do
    test "{:error, :checksum_mismatch} when tarball bytes don't hash to the SUMS entry" do
      target = tmp_dir("mismatch")
      filename = "fae-1.0.0-linux-x86_64.tar.gz"
      wrong_sha = sha256_hex("wrong content")
      sums = "#{wrong_sha}  #{filename}\n"

      client =
        stub_client(%{
          "/tarball" => {200, "actual content"},
          "/sums" => {200, sums}
        })

      assert {:error, :checksum_mismatch} =
               Downloader.run("http://x/tarball", "http://x/sums",
                 target_dir: target,
                 filename: filename,
                 client: client
               )

      refute File.exists?(Path.join(target, filename))
    end

    test "{:error, :checksum_missing} when filename is absent from SUMS" do
      target = tmp_dir("missing")
      sums = "deadbeef  something-else.tar.gz\n"

      client =
        stub_client(%{
          "/tarball" => {200, "irrelevant"},
          "/sums" => {200, sums}
        })

      assert {:error, :checksum_missing} =
               Downloader.run("http://x/tarball", "http://x/sums",
                 target_dir: target,
                 filename: "fae-1.0.0-linux-x86_64.tar.gz",
                 client: client
               )
    end

    test "{:error, :not_found} when SUMS file 404s" do
      target = tmp_dir("404sums")

      client = stub_client(%{"/tarball" => {200, "x"}})

      assert {:error, :not_found} =
               Downloader.run("http://x/tarball", "http://x/sums",
                 target_dir: target,
                 filename: "fae-1.0.0-linux-x86_64.tar.gz",
                 client: client
               )
    end

    test "{:error, :too_large} when tarball exceeds max_bytes" do
      target = tmp_dir("toobig")
      filename = "fae-1.0.0-linux-x86_64.tar.gz"
      big = String.duplicate("x", 5_000)
      sha = sha256_hex(big)
      sums = "#{sha}  #{filename}\n"

      client =
        stub_client(%{
          "/tarball" => {200, big},
          "/sums" => {200, sums}
        })

      assert {:error, :too_large} =
               Downloader.run("http://x/tarball", "http://x/sums",
                 target_dir: target,
                 filename: filename,
                 max_bytes: 1_000,
                 client: client
               )
    end
  end
end
