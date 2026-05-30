defmodule Fae.Health do
  @moduledoc """
  Pure domain derivations for Fae's operational health: overall health level,
  failing-job count, soonest next backup fire, and self-update state
  classification.

  These are the single source of truth for "is Fae OK?" — consumed by both the
  LiveView dashboard presenter (`FaeWeb.DashboardView`) and the machine-facing
  status contract (`FaeWeb.StatusContract`). Keeping them here means the web UI
  and the `/api/status` endpoint can never disagree about health.

  Every function is side-effect-free.
  """

  alias Fae.Backups.{Job, Recurrence, Run}

  @type health_level :: :healthy | :degraded | :down
  @type health :: %{level: health_level(), reason: String.t() | nil}

  @type update_state :: :idle | :update_available | :applying | :failed

  @applying_phases [:preparing, :downloading, :extracting, :handing_off]

  @spec health([Job.t()], %{optional(Ecto.UUID.t()) => Run.t() | nil}, atom()) :: health()
  def health(enabled_jobs, last_runs, self_update_phase) do
    cond do
      self_update_phase == :failed ->
        %{level: :down, reason: "Self-update failed — see Updates page."}

      (failing = count_failing(enabled_jobs, last_runs)) > 0 ->
        %{level: :degraded, reason: failing_reason(failing)}

      true ->
        %{level: :healthy, reason: nil}
    end
  end

  @spec count_failing([Job.t()], %{optional(Ecto.UUID.t()) => Run.t() | nil}) :: non_neg_integer()
  def count_failing(enabled_jobs, last_runs) do
    Enum.count(enabled_jobs, fn job ->
      case Map.get(last_runs, job.id) do
        %Run{status: "failed"} -> true
        _ -> false
      end
    end)
  end

  @spec soonest_next_fire([Job.t()], DateTime.t()) :: DateTime.t() | nil
  def soonest_next_fire([], _now), do: nil

  def soonest_next_fire(enabled_jobs, now) do
    enabled_jobs
    |> Enum.map(&Recurrence.next_fire(&1, now))
    |> Enum.min(DateTime, fn -> nil end)
  end

  @doc """
  Classifies the self-update state from the updater phase, the cached release
  (if any), and the locally-installed version.
  """
  @spec classify_update(atom(), map() | nil, String.t()) :: update_state()
  def classify_update(:failed, _release, _local), do: :failed

  def classify_update(phase, _release, _local) when phase in @applying_phases, do: :applying

  def classify_update(_phase, nil, _local), do: :idle

  def classify_update(_phase, release, local) do
    case Fae.Version.compare_versions(release_version(release), local) do
      :gt -> :update_available
      _ -> :idle
    end
  end

  defp failing_reason(1), do: "1 job's last run failed."
  defp failing_reason(n) when n > 1, do: "#{n} jobs' last run failed."

  defp release_version(%{version: v}) when is_binary(v), do: v
  defp release_version(%{tag: tag}) when is_binary(tag), do: tag
  defp release_version(_), do: ""
end
