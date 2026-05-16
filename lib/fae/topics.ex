defmodule Fae.Topics do
  @moduledoc """
  PubSub topic constants. Centralises all topic strings so typos
  become compile-time failures instead of silent subscription misses.
  """

  def settings_updates, do: "settings"
  def self_update_status, do: "self_update:status"
  def self_update_progress, do: "self_update:progress"
end
