defmodule EliHoleWeb.Router do
  use EliHoleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EliHoleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_auth do
    plug EliHoleWeb.Plugs.RequireAuth
  end

  pipeline :redirect_if_authed do
    plug EliHoleWeb.Plugs.RedirectIfAuthed
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :cluster_auth do
    plug :accepts, ["json"]
    plug EliHoleWeb.Plugs.ClusterAuth
  end

  scope "/", EliHoleWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/setup", SetupLive
    delete "/logout", SessionController, :delete
  end

  scope "/", EliHoleWeb do
    pipe_through [:browser, :redirect_if_authed]

    live "/login", LoginLive
    post "/login", SessionController, :create
  end

  scope "/admin", EliHoleWeb do
    pipe_through [:browser, :require_auth]

    live "/", DashboardLive
    live "/queries", QueryLogLive
    live "/blocklist", BlocklistLive
    live "/settings", SettingsLive
    live "/gravity", GravityLive
    live "/local-dns", LocalDNSLive
    get "/teleporter/export", TeleporterController, :export
    live "/cluster", ClusterLive
  end

  scope "/api/cluster", EliHoleWeb do
    pipe_through :cluster_auth

    post "/register", ClusterController, :register
    post "/stats", ClusterController, :receive_stats
    post "/config", ClusterController, :receive_config
    get "/config", ClusterController, :get_config
  end

  if Application.compile_env(:eli_hole, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: EliHoleWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
