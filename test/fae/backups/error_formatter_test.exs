defmodule Fae.Backups.ErrorFormatterTest do
  use ExUnit.Case, async: true

  alias Fae.Backups.ErrorFormatter

  describe "summarize/1 — network transport errors" do
    test "nxdomain mentions DNS and network-not-ready" do
      summary = ErrorFormatter.summarize(%Finch.TransportError{reason: :nxdomain})
      assert summary =~ "DNS"
      assert summary =~ "nxdomain"
      assert summary =~ "network"
    end

    test "translates well-known POSIX network reasons via both Finch and Mint" do
      for reason <- [:econnrefused, :ehostunreach, :enetunreach, :etimedout, :closed, :econnreset] do
        assert ErrorFormatter.summarize(%Finch.TransportError{reason: reason}) =~
                 to_string(reason)

        assert ErrorFormatter.summarize(%Mint.TransportError{reason: reason}) =~ to_string(reason)
      end
    end

    test "timeout phrases the wait, not the atom" do
      assert ErrorFormatter.summarize(%Finch.TransportError{reason: :timeout}) =~ "Timed out"
    end

    test "{:network, reason} routes through the same translator" do
      assert ErrorFormatter.summarize({:network, :nxdomain}) =~ "DNS"
    end

    test "Finch.HTTPError is described as a protocol error" do
      assert ErrorFormatter.summarize(%Finch.HTTPError{reason: :closed}) =~ "HTTP protocol error"
    end
  end

  describe "summarize/1 — HTTP status codes" do
    test "401 names credentials" do
      assert ErrorFormatter.summarize({:s3_error, 401, ""}) =~ "credentials"
    end

    test "403 mentions bucket policy" do
      assert ErrorFormatter.summarize({:s3_error, 403, ""}) =~ "bucket policy"
    end

    test "404 mentions bucket or path" do
      assert ErrorFormatter.summarize({:s3_error, 404, ""}) =~ "404"
    end

    test "429 mentions rate-limit and retry" do
      summary = ErrorFormatter.summarize({:s3_error, 429, ""})
      assert summary =~ "rate-limited"
      assert summary =~ "retried"
    end

    test "5xx mentions server error and retry" do
      summary = ErrorFormatter.summarize({:s3_error, 503, ""})
      assert summary =~ "503"
      assert summary =~ "retried"
    end

    test "other 4xx falls back to generic rejected wording" do
      assert ErrorFormatter.summarize({:s3_error, 422, ""}) =~ "422"
    end
  end

  describe "summarize/1 — source and packaging errors" do
    test "translates source-adapter stat errors via file_message" do
      assert ErrorFormatter.summarize({:stat, :enoent}) =~ "Couldn't find"
      assert ErrorFormatter.summarize({:stat, :eacces}) =~ "Permission denied"
    end

    test "explains type mismatches" do
      assert ErrorFormatter.summarize({:not_a_directory, :regular}) =~ "not a directory"
      assert ErrorFormatter.summarize({:not_a_regular_file, :directory}) =~ "not a regular file"
    end

    test "explains unknown source kind" do
      assert ErrorFormatter.summarize({:unknown_source_kind, "tape"}) =~ "tape"
    end

    test "packager errors" do
      assert ErrorFormatter.summarize(:folder_requires_tar_gz) =~ "tar.gz"

      assert ErrorFormatter.summarize({:tar_failed, 2, "bad file\nmore"}) =~
               "tar exited with code 2"

      assert ErrorFormatter.summarize({:tar_failed, 2, "bad file\nmore"}) =~ "bad file"
      refute ErrorFormatter.summarize({:tar_failed, 2, "bad file\nmore"}) =~ "more"

      assert ErrorFormatter.summarize({:unsupported_packaging, "folder", "as_is"}) =~
               "cannot be packaged"
    end
  end

  describe "summarize/1 — bare atoms" do
    test "bare POSIX errnos route to file_message" do
      assert ErrorFormatter.summarize(:enoent) =~ "Couldn't find"
      assert ErrorFormatter.summarize(:enospc) =~ "Disk full"
      assert ErrorFormatter.summarize(:eisdir) =~ "directory"
    end

    test "bare :timeout" do
      assert ErrorFormatter.summarize(:timeout) == "Operation timed out"
    end

    test "unknown atoms fall back to a generic line that includes the atom" do
      assert ErrorFormatter.summarize(:boom) == "Backup failed: boom"
    end

    test "unknown tuples fall back to inspect" do
      assert ErrorFormatter.summarize({:weird, "stuff"}) =~ ":weird"
    end
  end

  describe "format/1" do
    test "appends inspect after a blank line so the dashboard preview can split on it" do
      out = ErrorFormatter.format(%Finch.TransportError{reason: :nxdomain})

      [summary, detail] = String.split(out, "\n\n", parts: 2)
      assert summary =~ "DNS"
      assert detail =~ "Finch.TransportError"
      assert detail =~ "nxdomain"
    end

    test "summary line never contains a newline (so preview-split is deterministic)" do
      for reason <- [
            %Finch.TransportError{reason: :nxdomain},
            {:s3_error, 403, "<AccessDenied/>"},
            {:stat, :enoent},
            :enoent,
            :boom,
            {:weird, "stuff"}
          ] do
        summary = ErrorFormatter.summarize(reason)
        refute summary =~ "\n", "summary for #{inspect(reason)} contained a newline: #{summary}"
      end
    end
  end
end
