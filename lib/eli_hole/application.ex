defmodule EliHole.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{})

    children = [
      EliHoleWeb.Telemetry,
      EliHole.Repo,
      {DNSCluster, query: Application.get_env(:eli_hole, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: EliHole.PubSub},
      EliHole.DNS.Cache,
      EliHole.DNS.Blocklist,
      EliHole.DNS.SpeedTracker,
      EliHole.DNS.Gravity,
      EliHole.DNS.QueryLog,
      {EliHole.DNS.Server, port: Application.get_env(:eli_hole, :dns_port, 5354)},
      EliHoleWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EliHole.Supervisor]
    result = Supervisor.start_link(children, opts)
    EliHole.Accounts.ensure_env_admin()
    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EliHoleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
