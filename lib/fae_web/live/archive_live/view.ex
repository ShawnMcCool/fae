defmodule FaeWeb.ArchiveLive.View do
  @moduledoc """
  Pure presentation helpers for the Archive LiveViews — percent
  complete, human-readable sizes, throughput, and status badge classes.
  Extracted per the LiveView-logic-extraction decision so the math is
  unit-tested without a socket.
  """

  @bytes_per_unit 1024
  @units ~w(B KiB MiB GiB TiB PiB)

  @doc "Percent complete (0..100) by bytes; 100 when there is nothing to move."
  @spec percent(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def percent(_done, 0), do: 100
  def percent(done, total) when total > 0, do: min(100, floor(done * 100 / total))

  @doc "Human-readable byte size in binary units (KiB, MiB, …)."
  @spec human_bytes(non_neg_integer()) :: String.t()
  def human_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    reduce_unit(bytes / 1, @units)
  end

  defp reduce_unit(value, [unit]), do: format_size(value, unit)

  defp reduce_unit(value, [unit | _rest]) when value < @bytes_per_unit,
    do: format_size(value, unit)

  defp reduce_unit(value, [_unit | rest]), do: reduce_unit(value / @bytes_per_unit, rest)

  defp format_size(value, "B"), do: "#{round(value)} B"
  defp format_size(value, unit), do: :erlang.float_to_binary(value, decimals: 1) <> " " <> unit

  @doc "Average throughput in bytes/sec over the elapsed window, or nil if unknown."
  @spec throughput_bytes_per_sec(non_neg_integer(), integer()) :: float() | nil
  def throughput_bytes_per_sec(_bytes, elapsed_ms) when elapsed_ms <= 0, do: nil
  def throughput_bytes_per_sec(bytes, elapsed_ms), do: bytes * 1000 / elapsed_ms

  @doc "daisyUI badge modifier class for a run or item status."
  @spec status_badge_class(String.t()) :: String.t()
  def status_badge_class("completed"), do: "badge-success"
  def status_badge_class("uploaded"), do: "badge-success"
  def status_badge_class("uploading"), do: "badge-info"
  def status_badge_class("scanning"), do: "badge-info"
  def status_badge_class("pending"), do: "badge-ghost"
  def status_badge_class("partial"), do: "badge-warning"
  def status_badge_class("failed"), do: "badge-error"
  def status_badge_class("canceled"), do: "badge-ghost"
  def status_badge_class(_other), do: "badge-ghost"
end
