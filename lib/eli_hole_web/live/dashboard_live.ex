defmodule EliHoleWeb.DashboardLive do
  use EliHoleWeb, :live_view

  alias EliHole.DNS.{Cache, QueryLog, SpeedTracker}

  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:queries")
      schedule_refresh()
    end

    {:ok, socket |> assign(:active_nav, :dashboard) |> assign_stats()}
  end

  @impl true
  def handle_info({:new_query, _entry}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_stats(socket)}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp assign_stats(socket) do
    stats = QueryLog.stats()
    breakdown = QueryLog.status_breakdown()
    cache_stats = Cache.stats()
    speed = SpeedTracker.stats()
    fastest = List.first(speed)

    socket
    |> assign(:stats, stats)
    |> assign(:breakdown, breakdown)
    |> assign(:cache_stats, cache_stats)
    |> assign(:top_domains, QueryLog.top_domains(10))
    |> assign(:top_clients, QueryLog.top_clients(10))
    |> assign(:qps, QueryLog.recent_rate())
    |> assign(:fastest_upstream, fastest)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="space-y-6">
        <h1 class="text-2xl font-bold">Dashboard</h1>

        <div class="grid grid-cols-2 md:grid-cols-5 gap-4">
          <div class="bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Total Queries</div>
            <div class="text-3xl font-bold">{@stats.total}</div>
          </div>
          <div class="bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Resolved</div>
            <div class="text-3xl font-bold text-success">{@breakdown.ok}</div>
          </div>
          <div class="bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Blocked</div>
            <div class="text-3xl font-bold text-warning">{@breakdown.blocked}</div>
          </div>
          <div class="bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Failed</div>
            <div class="text-3xl font-bold text-error">{@breakdown.error}</div>
          </div>
          <div class="bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Queries/sec</div>
            <div class="text-3xl font-bold">{@qps}</div>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="bg-base-200 rounded-xl p-4 space-y-3">
            <h2 class="text-lg font-semibold">Top Queried Domains</h2>
            <div :if={@top_domains == []} class="text-sm opacity-40">No queries yet</div>
            <div :for={d <- @top_domains} class="flex items-center gap-3">
              <div class="flex-1 min-w-0">
                <div class="font-mono text-sm truncate">{d.domain}</div>
                <div class="w-full bg-base-300 rounded-full h-1.5 mt-1">
                  <div
                    class="bg-primary rounded-full h-1.5"
                    style={"width: #{bar_width(d.count, @top_domains)}%"}
                  >
                  </div>
                </div>
              </div>
              <span class="text-sm font-bold tabular-nums shrink-0">{d.count}</span>
            </div>
          </div>

          <div class="bg-base-200 rounded-xl p-4 space-y-3">
            <h2 class="text-lg font-semibold">Top Clients</h2>
            <div :if={@top_clients == []} class="text-sm opacity-40">No queries yet</div>
            <div :for={c <- @top_clients} class="flex items-center gap-3">
              <div class="flex-1 min-w-0">
                <div class="font-mono text-sm truncate">{c.client}</div>
                <div class="w-full bg-base-300 rounded-full h-1.5 mt-1">
                  <div
                    class="bg-secondary rounded-full h-1.5"
                    style={"width: #{bar_width(c.count, @top_clients)}%"}
                  >
                  </div>
                </div>
              </div>
              <span class="text-sm font-bold tabular-nums shrink-0">{c.count}</span>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="bg-base-200 rounded-xl p-4 space-y-3">
            <h2 class="text-lg font-semibold">Cache</h2>
            <div class="grid grid-cols-3 gap-4 text-center">
              <div>
                <div class="text-sm opacity-60">Active</div>
                <div class="text-xl font-bold">{@cache_stats.active}</div>
              </div>
              <div>
                <div class="text-sm opacity-60">Expired</div>
                <div class="text-xl font-bold opacity-40">{@cache_stats.expired}</div>
              </div>
              <div>
                <div class="text-sm opacity-60">TTL</div>
                <div class="text-xl font-bold">{@cache_stats.ttl}s</div>
              </div>
            </div>
          </div>

          <div :if={@fastest_upstream} class="bg-base-200 rounded-xl p-4 space-y-3">
            <h2 class="text-lg font-semibold">Fastest Upstream</h2>
            <div class="flex items-center gap-4">
              <div class="font-mono text-lg">
                {Cache.format_upstream(@fastest_upstream.upstream)}
              </div>
              <span class={[
                "text-2xl font-bold",
                cond do
                  @fastest_upstream.avg_ms == nil -> "opacity-40"
                  @fastest_upstream.avg_ms < 50 -> "text-success"
                  @fastest_upstream.avg_ms < 200 -> "text-warning"
                  true -> "text-error"
                end
              ]}>
                {@fastest_upstream.avg_ms || "—"}ms
              </span>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp bar_width(_count, []), do: 0

  defp bar_width(count, items) do
    max = items |> List.first() |> Map.get(:count, 1)
    if max == 0, do: 0, else: round(count / max * 100)
  end
end
