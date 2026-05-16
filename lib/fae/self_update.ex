defmodule Fae.SelfUpdate do
  @moduledoc """
  In-app release check + self-update for Fae.

  Owns the relationship between the running release and the
  `ShawnMcCool/fae` GitHub repository: polls the GitHub Releases API
  for the latest tag, caches the result, and (in later phases) will
  drive the download → verify → stage → hand-off pipeline that
  applies an update.

  ## Trust model

  Trust is anchored to GitHub's account and release process for
  `ShawnMcCool/fae`. TLS verification is always on, the download URL
  is built from a fixed template (never pulled from API response
  fields), and `tag_name` values are validated against a strict semver
  regex before being used anywhere. A compromised GitHub account
  defeats these checks — release signing is a follow-up.
  """

  alias Fae.SelfUpdate.{CheckerJob, Storage, UpdateChecker}
  alias Fae.Topics

  @boot_check_delay_seconds 30

  @doc """
  True only when update checks should run. Returns false in dev and
  test — dev builds update by rebuilding from source; tests never hit
  the network.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:fae, :environment, :dev) == :prod
  end

  @doc """
  Subscribes the caller to `self_update:status` — `{:check_started}`
  and `{:check_complete, outcome}` messages fire here when the
  scheduled or manual check runs.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Fae.PubSub, Topics.self_update_status())
  end

  @doc """
  Enqueues a one-off update check immediately. Deduplicates against an
  already-scheduled job via Oban `replace`.
  """
  @spec check_now() :: {:ok, Oban.Job.t()} | {:error, term()}
  def check_now, do: CheckerJob.enqueue_now()

  @doc """
  Returns the last known release — either freshly cached in
  `:persistent_term` or hydrated from `Fae.Settings` at boot — or
  `:none` when nothing has been observed yet.
  """
  @spec cached_release() :: {:ok, map()} | :none
  def cached_release do
    case UpdateChecker.cached_latest_release() do
      {:fresh, {:ok, release}} -> {:ok, release}
      {:fresh, {:error, _}} -> :none
      :stale -> :none
    end
  end

  @doc """
  Records the outcome of a release check into both the durable store
  and the hot-path cache. See `Storage.record_check_result/1`.
  """
  @spec record_check_result({:ok, map()} | {:error, term()}) ::
          {:ok, UpdateChecker.classification(), map()} | {:error, term()}
  def record_check_result(outcome), do: Storage.record_check_result(outcome)

  @doc """
  App-boot hydration. Reads the persisted `latest_known` entry into
  the hot-path `:persistent_term` cache and enqueues a delayed fresh
  check.

  The boot check is unconditional: `CheckerJob`'s 1-hour `unique`
  constraint dedupes with a cron tick that just fired, so this can't
  spam the GitHub API.
  """
  @spec boot!() :: :ok
  def boot! do
    :ok = Storage.hydrate_cache()
    _ = CheckerJob.enqueue_after(@boot_check_delay_seconds)
    :ok
  end
end
