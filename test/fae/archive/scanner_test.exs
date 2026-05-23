defmodule Fae.Archive.ScannerTest do
  use ExUnit.Case, async: true

  alias Fae.Archive.Scanner

  @moduletag :tmp_dir

  test "returns regular files with relative paths and sizes, sorted", %{tmp_dir: tmp} do
    File.mkdir_p!(Path.join(tmp, "2004/reunion"))
    File.write!(Path.join(tmp, "2004/reunion/a.jpg"), "12345")
    File.write!(Path.join(tmp, "top.txt"), "hi")
    File.write!(Path.join(tmp, ".hidden"), "x")

    assert Scanner.scan(tmp) == [
             %{relative_path: ".hidden", byte_size: 1},
             %{relative_path: "2004/reunion/a.jpg", byte_size: 5},
             %{relative_path: "top.txt", byte_size: 2}
           ]
  end

  test "includes empty files", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "empty.bin"), "")
    assert Scanner.scan(tmp) == [%{relative_path: "empty.bin", byte_size: 0}]
  end

  test "skips symlinks (loop/escape safety)", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "real.txt"), "hi")
    :ok = File.ln_s(Path.join(tmp, "real.txt"), Path.join(tmp, "link.txt"))

    assert Scanner.scan(tmp) == [%{relative_path: "real.txt", byte_size: 2}]
  end

  test "returns an empty list for an empty directory", %{tmp_dir: tmp} do
    assert Scanner.scan(tmp) == []
  end
end
