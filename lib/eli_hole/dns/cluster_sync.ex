defmodule EliHole.DNS.ClusterSync do
  @moduledoc """
  Slave-side GenServer. Registers with master on startup,
  periodically pushes stats to master.
  """
  use GenServer

  alias EliHole.DNS.{Cluster, QueryLog, Cache}

  require Logger

  @stats_push_interval :timer.seconds(30)
  @register_retry_interval :timer.seconds(15)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    send(self(), :register)
    Logger.info("ClusterSync started (slave mode)")
    {:ok, %{registered: false, last_push: nil, master_status: :connecting}}
  end

  @impl true
  def handle_info(:register, state) do
    case Cluster.register_with_master() do
      :ok ->
        Logger.info("Registered with master successfully")
        schedule_stats_push()
        {:noreply, %{state | registered: true, master_status: :connected}}

      {:error, reason} ->
        Logger.warning("Registration failed: #{inspect(reason)}, retrying...")
        Process.send_after(self(), :register, @register_retry_interval)
        {:noreply, %{state | master_status: :disconnected}}
    end
  end

  def handle_info(:push_stats, state) do
    stats = collect_stats()

    new_state =
      case Cluster.push_stats_to_master(stats) do
        :ok ->
          %{state | last_push: DateTime.utc_now(), master_status: :connected}

        {:error, _} ->
          %{state | master_status: :disconnected}
      end

    schedule_stats_push()
    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  defp collect_stats do
    query_stats = QueryLog.stats()
    breakdown = QueryLog.status_breakdown()
    cache_stats = Cache.stats()
    top_domains = QueryLog.top_domains(10)
    top_clients = QueryLog.top_clients(10)
    qps = QueryLog.recent_rate()

    %{
      total: query_stats.total,
      resolved: query_stats.resolved,
      blocked: query_stats.blocked,
      failed: query_stats.failed,
      ok: breakdown.ok,
      error: breakdown.error,
      blocked_count: breakdown.blocked,
      cache_active: cache_stats.active,
      cache_ttl: cache_stats.ttl,
      qps: qps,
      top_domains: top_domains,
      top_clients: top_clients
    }
  end

  defp schedule_stats_push do
    Process.send_after(self(), :push_stats, @stats_push_interval)
  end
end
