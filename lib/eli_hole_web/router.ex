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

  # DNS-over-HTTPS (RFC 8484). No browser/session plugs: the body is raw
  # `application/dns-message`, read directly in the controller.
  scope "/", EliHoleWeb do
    get "/dns-query", DohController, :query
    post "/dns-query", DohController, :query
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
    live "/whitelist", WhitelistLive
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

  scope "/api", EliHoleWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Prometheus scrape target. Plain GET, no session/auth — the controller sets
  # the `text/plain; version=0.0.4` exposition content-type itself.
  scope "/", EliHoleWeb do
    get "/metrics", MetricsController, :index
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
