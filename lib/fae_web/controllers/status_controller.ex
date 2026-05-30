defmodule FaeWeb.StatusController do
  @moduledoc """
  Read-only JSON status endpoint for same-machine consumers (e.g. a quickshell
  bar/dock, scripts). Serves the `Fae.Status` snapshot shaped by
  `FaeWeb.StatusContract` at `GET /api/status`.

  No authentication: the endpoint binds `127.0.0.1` only (enforced in
  `runtime.exs`), which is Fae's trust model — see
  `docs/decisions/architecture/2026-05-16-028-no-application-layer-auth-on-single-user-desktop.md`.
  Decision-027 sanctions read-only health endpoints as a non-LiveView route.
  """

  use FaeWeb, :controller

  alias Fae.Status
  alias FaeWeb.StatusContract

  def show(conn, _params) do
    json(conn, StatusContract.build(Status.snapshot()))
  end
end
