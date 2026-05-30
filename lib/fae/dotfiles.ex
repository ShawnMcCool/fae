defmodule Fae.Dotfiles do
  @moduledoc """
  Dotfiles tool: backs up a curated set of `$HOME` config paths to a
  per-machine git remote on an Oban schedule. Bare repo, work-tree = $HOME,
  files tracked in place (no symlinks). DB persists config + history; the
  git repo and live files are the source of truth (decision 027).
  """
  alias Fae.Topics

  defdelegate get_config(), to: Fae.Dotfiles.Configs, as: :get
  defdelegate update_config(attrs), to: Fae.Dotfiles.Configs, as: :update
  defdelegate list_tracked(), to: Fae.Dotfiles.TrackedPaths, as: :list
  defdelegate last_run(), to: Fae.Dotfiles.Runs, as: :last
  defdelegate recent_runs(limit), to: Fae.Dotfiles.Runs, as: :list_recent

  def subscribe_status, do: Phoenix.PubSub.subscribe(Fae.PubSub, Topics.dotfiles_status())
  def subscribe_runs, do: Phoenix.PubSub.subscribe(Fae.PubSub, Topics.dotfiles_runs())

  @doc "Enqueues a one-off (manual) dotfiles backup cycle."
  def run_now, do: %{"kind" => "manual"} |> Fae.Dotfiles.BackupWorker.new() |> Oban.insert()

  @doc """
  Reconciles the scheduled backup job on application boot so the queue
  reflects the current config. No-op when the scheduler is disabled
  (e.g. in :test).
  """
  def boot! do
    if Fae.Dotfiles.Scheduler.enabled?(), do: Fae.Dotfiles.Scheduler.reconcile()
    :ok
  end
end
