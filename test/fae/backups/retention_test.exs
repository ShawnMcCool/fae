defmodule Fae.Backups.RetentionTest do
  use ExUnit.Case, async: true

  alias Fae.Backups.Retention

  defp obj(key, iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso <> "Z")
    %{key: key, last_modified: dt}
  end

  defp now!(iso), do: elem(DateTime.from_iso8601(iso <> "Z"), 1)

  describe "keep_last_n" do
    test "keeps the N newest, deletes the rest" do
      objects = [
        obj("a", "2026-06-01T00:00:00"),
        obj("b", "2026-06-02T00:00:00"),
        obj("c", "2026-06-03T00:00:00"),
        obj("d", "2026-06-04T00:00:00"),
        obj("e", "2026-06-05T00:00:00")
      ]

      {keep, delete} =
        Retention.partition(objects, "keep_last_n", %{"n" => 2}, now!("2026-06-10T00:00:00"))

      assert Enum.map(keep, & &1.key) == ~w(e d)
      assert Enum.map(delete, & &1.key) |> Enum.sort() == ~w(a b c)
    end

    test "keep_last_n with n >= count keeps everything" do
      objects = [obj("a", "2026-06-01T00:00:00")]

      assert {[%{key: "a"}], []} =
               Retention.partition(
                 objects,
                 "keep_last_n",
                 %{"n" => 5},
                 now!("2026-06-10T00:00:00")
               )
    end

    test "keep_last_n with n = 0 deletes everything" do
      objects = [obj("a", "2026-06-01T00:00:00"), obj("b", "2026-06-02T00:00:00")]

      assert {[], to_delete} =
               Retention.partition(
                 objects,
                 "keep_last_n",
                 %{"n" => 0},
                 now!("2026-06-10T00:00:00")
               )

      assert length(to_delete) == 2
    end
  end

  describe "keep_for_days" do
    test "keeps objects newer than the cutoff" do
      now = now!("2026-06-10T00:00:00")

      objects = [
        obj("a", "2026-06-01T00:00:00"),
        obj("b", "2026-06-05T00:00:00"),
        obj("c", "2026-06-09T00:00:00")
      ]

      {keep, delete} = Retention.partition(objects, "keep_for_days", %{"days" => 7}, now)

      assert Enum.map(keep, & &1.key) |> Enum.sort() == ~w(b c)
      assert Enum.map(delete, & &1.key) == ~w(a)
    end

    test "keep_for_days = 0 deletes everything older than now" do
      now = now!("2026-06-10T00:00:00")
      objects = [obj("a", "2026-06-09T00:00:00")]

      assert {[], [%{key: "a"}]} =
               Retention.partition(objects, "keep_for_days", %{"days" => 0}, now)
    end
  end

  describe "gfs" do
    test "keeps the latest in each daily bucket, up to N daily buckets" do
      # Three days; two backups on the most recent day.
      objects = [
        obj("d1-am", "2026-06-08T03:00:00"),
        obj("d1-pm", "2026-06-08T15:00:00"),
        obj("d2", "2026-06-07T03:00:00"),
        obj("d3", "2026-06-06T03:00:00")
      ]

      {keep, _delete} =
        Retention.partition(
          objects,
          "gfs",
          %{"daily" => 2, "weekly" => 0, "monthly" => 0},
          now!("2026-06-10T00:00:00")
        )

      keys = Enum.map(keep, & &1.key) |> Enum.sort()
      # Two most-recent daily buckets are 06-08 (latest = d1-pm) and 06-07 (d2).
      assert keys == ~w(d1-pm d2)
    end

    test "daily + weekly + monthly union" do
      objects = [
        # Three days, two ISO weeks, two months.
        obj("apr-old", "2026-04-15T03:00:00"),
        obj("may-w20-mon", "2026-05-11T03:00:00"),
        obj("may-w20-tue", "2026-05-12T03:00:00"),
        obj("may-w21-thu", "2026-05-21T03:00:00")
      ]

      {keep, _delete} =
        Retention.partition(
          objects,
          "gfs",
          %{"daily" => 1, "weekly" => 1, "monthly" => 1},
          now!("2026-05-25T00:00:00")
        )

      keys = Enum.map(keep, & &1.key) |> Enum.sort()
      # daily-1 = may-w21-thu (latest single day).
      # weekly-1 = may-w21-thu (latest ISO-week's latest).
      # monthly-1 = may-w21-thu (latest month's latest).
      # All three pick the same object — keep set has one entry.
      assert keys == ~w(may-w21-thu)
    end

    test "gfs with all zeros deletes everything" do
      objects = [obj("a", "2026-06-01T00:00:00")]

      assert {[], [%{key: "a"}]} =
               Retention.partition(
                 objects,
                 "gfs",
                 %{"daily" => 0, "weekly" => 0, "monthly" => 0},
                 now!("2026-06-10T00:00:00")
               )
    end
  end
end
