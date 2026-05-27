defmodule EliHole.DNS.ClusterManager do
  @moduledoc """
  Master-side GenServer. Watches config changes via PubSub
  and pushes updates to all registered slave nodes.
  Stores latest stats received from slaves in ETS.
  Debounces rapid config changes into a single push.
  """
  use GenServer

  alias EliHole.DNS.Cluster

  require Logger

  @stats_table :cluster_node_stats
  @health_check_interval :timer.seconds(60)
  @offline_threshold_seconds 120
  @debounce_ms 3_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_node_stats(node_name) do
    case :ets.lookup(@stats_table, node_name) do
      [{^node_name, stats, received_at}] -> {:ok, stats, received_at}
      [] -> :miss
    end
  end

  def all_node_stats do
    :ets.tab2list(@stats_table)
    |> Enum.map(fn {name, stats, received_at} ->
      %{name: name, stats: stats, received_at: received_at}
    end)
  end

  def receive_stats(node_name, stats) do
    GenServer.cast(__MODULE__, {:stats, node_name, stats})
  end

  @impl true
  def init(_opts) do
    :ets.new(@stats_table, [:set, :named_table, :public, read_concurrency: true])

    Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:blocklist")
    Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:gravity")
    Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:local_dns")
    Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:adlists")
    Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:cache_settings")

    schedule_health_check()
    Logger.info("ClusterManager started (master mode)")
    {:ok, %{push_timer: nil}}
  end

  @impl true
  def handle_info(:blocklist_changed, state) do
    {:noreply, schedule_push(state)}
  end

  def handle_info(:gravity_updated, state) do
    {:noreply, schedule_push(state)}
  end

  def handle_info(:local_dns_changed, state) do
    {:noreply, schedule_push(state)}
  end

  def handle_info(:adlists_changed, state) do
    {:noreply, schedule_push(state)}
  end

  def handle_info({:ttl_changed, _ttl}, state) do
    {:noreply, schedule_push(state)}
  end

  def handle_info({:upstreams_changed, _upstreams}, state) do
    {:noreply, schedule_push(state)}
  end

  def handle_info(:do_push, state) do
    Task.Supervisor.start_child(EliHole.TaskSupervisor, fn ->
      Cluster.push_config_to_all()
    end)

    {:noreply, %{state | push_timer: nil}}
  end

  def handle_info({:gravity_status, _status}, state) do
    {:noreply, state}
  end

  def handle_info(:cache_flushed, state) do
    {:noreply, state}
  end

  def handle_info(:health_check, state) do
    check_node_health()
    schedule_health_check()
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:stats, node_name, stats}, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    :ets.insert(@stats_table, {node_name, stats, now})

    case Cluster.get_node_by_name(node_name) do
      nil -> :ok
      node -> Cluster.touch_node(node)
    end

    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:cluster", {:stats_updated, node_name})
    {:noreply, state}
  end

  defp schedule_push(%{push_timer: nil} = state) do
    ref = Process.send_after(self(), :do_push, @debounce_ms)
    %{state | push_timer: ref}
  end

  defp schedule_push(state), do: state

  defp check_node_health do
    now = DateTime.utc_now()

    Cluster.list_nodes()
    |> Enum.each(fn node ->
      if node.status == "online" && node.last_seen_at do
        diff = DateTime.diff(now, node.last_seen_at, :second)

        if diff > @offline_threshold_seconds do
          Cluster.mark_offline(node)
          Logger.warning("Node #{node.name} marked offline (#{diff}s since last seen)")
        end
      end
    end)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end
end
