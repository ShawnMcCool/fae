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

    live_session :default, on_mount: [FaeWeb.SidebarScope, FaeWeb.DisplayScope] do
      live "/", DashboardLive
      live "/update", UpdateLive
      live "/settings", SettingsLive, :index

      scope "/backups" do
        live "/", BackupsLive.Index, :index
        live "/new", BackupsLive.JobForm, :new
        live "/destinations", BackupsLive.DestinationsIndex, :index
        live "/destinations/new", BackupsLive.DestinationForm, :new
        live "/destinations/:id/edit", BackupsLive.DestinationForm, :edit
        live "/:id", BackupsLive.JobShow, :show
        live "/:id/edit", BackupsLive.JobForm, :edit
      end

      scope "/archive" do
        live "/", ArchiveLive.Index, :index
        live "/new", ArchiveLive.Form, :new
        live "/:id", ArchiveLive.Show, :show
        live "/:id/edit", ArchiveLive.Form, :edit
      end
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", FaeWeb do
  #   pipe_through :api
  # end
end
