defmodule Fae.Backups.Retention do
  @moduledoc """
  Pure retention partitioning: given a list of remote objects and a
  policy, returns `{keep, delete}`.

  Object shape: a map with `:key` (binary) and `:last_modified`
  (`DateTime`).

  Strategies:

    * `"keep_last_n"` — params `%{"n" => integer}`.
    * `"keep_for_days"` — params `%{"days" => integer}`.
    * `"gfs"` — params `%{"daily" => i, "weekly" => i, "monthly" => i}`.
      Keeps the most-recent object in each of the most-recent N
      daily / ISO-weekly / year-month buckets; the union is the keep
      set.
  """

  @type object :: %{key: String.t(), last_modified: DateTime.t()}

  @spec partition([object], String.t(), map(), DateTime.t()) :: {[object], [object]}
  def partition(objects, "keep_last_n", %{"n" => n}, _now) when is_integer(n) and n >= 0 do
    objects
    |> Enum.sort_by(& &1.last_modified, {:desc, DateTime})
    |> Enum.split(n)
  end

  def partition(objects, "keep_for_days", %{"days" => days}, %DateTime{} = now)
      when is_integer(days) and days >= 0 do
    cutoff = DateTime.add(now, -days * 86_400, :second)

    Enum.split_with(objects, fn obj ->
      DateTime.compare(obj.last_modified, cutoff) != :lt
    end)
  end

  def partition(
        objects,
        "gfs",
        %{"daily" => daily, "weekly" => weekly, "monthly" => monthly},
        _now
      )
      when is_integer(daily) and is_integer(weekly) and is_integer(monthly) and
             daily >= 0 and weekly >= 0 and monthly >= 0 do
    keepers =
      bucket_keepers(objects, &daily_bucket/1, daily) ++
        bucket_keepers(objects, &weekly_bucket/1, weekly) ++
        bucket_keepers(objects, &monthly_bucket/1, monthly)

    keep_keys = MapSet.new(keepers, & &1.key)
    Enum.split_with(objects, fn obj -> MapSet.member?(keep_keys, obj.key) end)
  end

  defp bucket_keepers(_objects, _bucket_fn, 0), do: []

  defp bucket_keepers(objects, bucket_fn, n) do
    objects
    |> Enum.group_by(fn obj -> bucket_fn.(obj.last_modified) end)
    |> Enum.map(fn {bucket, group} ->
      latest = Enum.max_by(group, & &1.last_modified, DateTime)
      {bucket, latest}
    end)
    |> Enum.sort_by(fn {bucket, _} -> bucket end, :desc)
    |> Enum.take(n)
    |> Enum.map(fn {_, obj} -> obj end)
  end

  defp daily_bucket(dt), do: Date.to_iso8601(DateTime.to_date(dt))

  defp weekly_bucket(dt) do
    date = DateTime.to_date(dt)
    {year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
    {year, week}
  end

  defp monthly_bucket(dt) do
    date = DateTime.to_date(dt)
    {date.year, date.month}
  end
end
