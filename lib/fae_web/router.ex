defmodule FaeWeb.Router do
  use FaeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FaeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FaeWeb do
    pipe_through :browser

    live "/", DashboardLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", FaeWeb do
  #   pipe_through :api
  # end
end
