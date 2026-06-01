defmodule EliHole.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{})

    cluster_role = Application.get_env(:eli_hole, :cluster_role, :standalone)

    cluster_children =
      case cluster_role do
        :master -> [EliHole.DNS.ClusterManager]
        :slave -> [EliHole.DNS.ClusterSync]
        _ -> []
      end

    children =
      [
        EliHoleWeb.Telemetry,
        EliHole.Repo,
        {Task.Supervisor, name: EliHole.TaskSupervisor},
        {DNSCluster, query: Application.get_env(:eli_hole, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: EliHole.PubSub},
        EliHole.DNS.Cache,
        EliHole.DNSSEC.Client,
        EliHole.DNSSEC.Config,
        EliHole.DNS.Blocklist,
        EliHole.DNS.Whitelist,
        EliHole.DNS.PauseControl,
        EliHole.DNS.LocalDNS,
        EliHole.DNS.SpeedTracker,
        EliHole.DNS.RateLimiter,
        EliHole.DNS.Gravity,
        EliHole.DNS.QueryLog,
        {EliHole.DNS.Server, port: Application.get_env(:eli_hole, :dns_port, 5354)},
        EliHoleWeb.Endpoint
      ] ++ dot_server_children() ++ cluster_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EliHole.Supervisor]
    result = Supervisor.start_link(children, opts)
    EliHole.Accounts.ensure_env_admin()
    result
  end

  # The DoT listener binds a fixed TLS port, so it is skipped when
  # `start_dot_server?` is false (test env): the suite would otherwise collide
  # with a running dev server, and dot_server_test starts its own listener on an
  # ephemeral port. Returns a (possibly empty) child list.
  defp dot_server_children do
    if Application.get_env(:eli_hole, :start_dot_server?, true) do
      [
        {EliHole.DNS.DoTServer,
         port: Application.get_env(:eli_hole, :dot_port, 853),
         certfile: Application.get_env(:eli_hole, :dot_certfile),
         keyfile: Application.get_env(:eli_hole, :dot_keyfile)}
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EliHoleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
