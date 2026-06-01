defmodule EliHoleWeb.DashboardLive do
  use EliHoleWeb, :live_view

  alias EliHole.DNS.{Cache, PauseControl, QueryLog, SpeedTracker}

  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:queries")
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:pause")
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:active_nav, :dashboard)
     |> assign(:pause, PauseControl.status())
     |> assign_stats()}
  end

  @impl true
  def handle_info({:new_query, _entry}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pause_changed, status}, socket) do
    {:noreply, assign(socket, :pause, status)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    # Recompute pause status each tick so the countdown ticks down even without
    # a PubSub message, and so it self-resets the instant the deadline passes.
    {:noreply, socket |> assign(:pause, PauseControl.status()) |> assign_stats()}
  end

  @impl true
  def handle_event("pause", %{"minutes" => minutes}, socket) do
    case Integer.parse(minutes) do
      {n, _} when n > 0 ->
        PauseControl.pause(n)
        {:noreply, assign(socket, :pause, PauseControl.status())}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("resume", _params, socket) do
    PauseControl.resume()
    {:noreply, assign(socket, :pause, PauseControl.status())}
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
    |> assign(:dnssec, QueryLog.dnssec_breakdown())
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

        <div
          id="pause-control"
          class={[
            "rounded-xl p-4 flex flex-wrap items-center justify-between gap-4 transition-colors",
            if(@pause.paused?, do: "bg-warning/20 border border-warning", else: "bg-base-200")
          ]}
        >
          <div class="flex items-center gap-3">
            <.icon
              name={if @pause.paused?, do: "hero-pause-circle", else: "hero-shield-check"}
              class={["size-6", if(@pause.paused?, do: "text-warning", else: "text-success")]}
            />
            <div>
              <div class="font-semibold">
                <%= if @pause.paused? do %>
                  Blocking paused
                <% else %>
                  Blocking active
                <% end %>
              </div>
              <div class="text-sm opacity-60">
                <%= if @pause.paused? do %>
                  Resumes in <span class="tabular-nums">{format_remaining(@pause.remaining)}</span>
                <% else %>
                  All blocklists enforced
                <% end %>
              </div>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <%= if @pause.paused? do %>
              <button id="resume-blocking" phx-click="resume" class="btn btn-sm btn-primary">
                Resume now
              </button>
            <% else %>
              <span class="text-sm opacity-60 shrink-0">Pause for</span>
              <button
                :for={m <- [1, 5, 15, 60]}
                id={"pause-#{m}m"}
                phx-click="pause"
                phx-value-minutes={m}
                class="btn btn-sm btn-outline"
              >
                {if m < 60, do: "#{m}m", else: "1h"}
              </button>
            <% end %>
          </div>
        </div>

        <div class="grid grid-cols-2 md:grid-cols-5 gap-4">
          <div class="bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Total Queries (today)</div>
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

        <div class="grid grid-cols-3 gap-4">
          <div class="bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">DNSSEC Secure</div>
            <div class="text-3xl font-bold text-success">{@dnssec.secure}</div>
          </div>
          <div class="bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">DNSSEC Insecure</div>
            <div class="text-3xl font-bold opacity-70">{@dnssec.insecure}</div>
          </div>
          <div class="bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">DNSSEC Bogus</div>
            <div class="text-3xl font-bold text-error">{@dnssec.bogus}</div>
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

  defp format_remaining(seconds) when seconds > 0 do
    "#{div(seconds, 60)}:#{seconds |> rem(60) |> to_string() |> String.pad_leading(2, "0")}"
  end

  defp format_remaining(_), do: "0:00"

  defp bar_width(_count, []), do: 0

  defp bar_width(count, items) do
    max = items |> List.first() |> Map.get(:count, 1)
    if max == 0, do: 0, else: round(count / max * 100)
  end
end
