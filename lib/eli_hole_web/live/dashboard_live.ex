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
     |> assign(:period, :today)
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

  @impl true
  def handle_event("set_period", %{"period" => period}, socket)
      when period in ~w(today week month) do
    {:noreply, socket |> assign(:period, String.to_existing_atom(period)) |> assign_stats()}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp assign_stats(socket) do
    range = period_range(socket.assigns.period)
    cache_stats = Cache.stats()
    speed = SpeedTracker.stats()
    fastest = List.first(speed)

    # Multi-day periods get a per-day trend chart; "today" leans on the 24h
    # intraday series chart instead, so skip the daily rollup there.
    daily = if socket.assigns.period == :today, do: [], else: QueryLog.daily_series(range)

    socket
    |> assign(:stats, QueryLog.stats(range))
    |> assign(:breakdown, QueryLog.status_breakdown(range))
    |> assign(:dnssec, QueryLog.dnssec_breakdown(range))
    |> assign(:cache_stats, cache_stats)
    |> assign(:top_domains, QueryLog.top_domains(10, range))
    |> assign(:top_clients, QueryLog.top_clients(10, range))
    |> assign(:qps, QueryLog.recent_rate())
    |> assign(:series, QueryLog.series())
    |> assign(:daily, daily)
    |> assign(:fastest_upstream, fastest)
  end

  # Inclusive UTC date range for the selected dashboard period. Bounded by the
  # 30-day daily-aggregate retention in QueryLog.
  defp period_range(:today), do: Date.range(Date.utc_today(), Date.utc_today())
  defp period_range(:week), do: trailing_range(7)
  defp period_range(:month), do: trailing_range(30)

  defp trailing_range(days) do
    today = Date.utc_today()
    Date.range(Date.add(today, -(days - 1)), today)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <h1 class="text-2xl font-bold">Dashboard</h1>
          <div class="join" role="group" aria-label="Statistics period">
            <button
              :for={{p, label} <- [today: "Today", week: "7 days", month: "30 days"]}
              id={"period-#{p}"}
              phx-click="set_period"
              phx-value-period={p}
              aria-pressed={@period == p}
              class={[
                "btn btn-sm join-item",
                if(@period == p, do: "btn-primary", else: "btn-outline")
              ]}
            >
              {label}
            </button>
          </div>
        </div>

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
            <div class="text-sm opacity-60">Total Queries ({period_label(@period)})</div>
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

        <div class="bg-base-200 rounded-xl p-4 space-y-3">
          <div class="flex items-center justify-between gap-4">
            <h2 class="text-lg font-semibold">Queries Over Time (24h)</h2>
            <div class="flex items-center gap-3 text-xs opacity-60">
              <span class="flex items-center gap-1">
                <span class="size-2 rounded-full bg-success"></span>Allowed
              </span>
              <span class="flex items-center gap-1">
                <span class="size-2 rounded-full bg-warning"></span>Blocked
              </span>
              <span class="flex items-center gap-1">
                <span class="size-2 rounded-full bg-error"></span>Failed
              </span>
            </div>
          </div>

          <% chart_data? = Enum.any?(@series, &(&1.total > 0)) %>

          <div :if={not chart_data?} class="text-sm opacity-40 py-12 text-center">
            No queries yet
          </div>

          <svg
            :if={chart_data?}
            viewBox={"0 0 #{length(@series)} 100"}
            preserveAspectRatio="none"
            class="w-full h-40"
            role="img"
            aria-label="Queries over the last 24 hours"
          >
            <% max = series_max(@series) %>
            <%= for {bucket, i} <- Enum.with_index(@series) do %>
              <% ok_h = bucket.ok / max * 100 %>
              <% blocked_h = bucket.blocked / max * 100 %>
              <% other_h = (bucket.error + bucket.rate_limited) / max * 100 %>
              <rect x={i} y="0" width="1" height="100" fill="transparent">
                <title>
                  {bucket_label(bucket.ts)} — {bucket.total} queries ({bucket.blocked} blocked, {bucket.error +
                    bucket.rate_limited} failed)
                </title>
              </rect>
              <rect
                :if={ok_h > 0}
                x={i + 0.1}
                width="0.8"
                y={100 - ok_h}
                height={ok_h}
                fill="currentColor"
                class="text-success"
              />
              <rect
                :if={blocked_h > 0}
                x={i + 0.1}
                width="0.8"
                y={100 - ok_h - blocked_h}
                height={blocked_h}
                fill="currentColor"
                class="text-warning"
              />
              <rect
                :if={other_h > 0}
                x={i + 0.1}
                width="0.8"
                y={100 - ok_h - blocked_h - other_h}
                height={other_h}
                fill="currentColor"
                class="text-error"
              />
            <% end %>
          </svg>

          <div :if={chart_data?} class="flex justify-between text-xs opacity-40 tabular-nums">
            <span>{bucket_label(List.first(@series).ts)}</span>
            <span>{bucket_label(List.last(@series).ts)}</span>
          </div>
        </div>

        <div :if={@daily != []} class="bg-base-200 rounded-xl p-4 space-y-3">
          <div class="flex items-center justify-between gap-4">
            <h2 class="text-lg font-semibold">Daily Totals ({period_label(@period)})</h2>
            <div class="flex items-center gap-3 text-xs opacity-60">
              <span class="flex items-center gap-1">
                <span class="size-2 rounded-full bg-success"></span>Allowed
              </span>
              <span class="flex items-center gap-1">
                <span class="size-2 rounded-full bg-warning"></span>Blocked
              </span>
              <span class="flex items-center gap-1">
                <span class="size-2 rounded-full bg-error"></span>Failed
              </span>
            </div>
          </div>

          <% daily_data? = Enum.any?(@daily, &(&1.total > 0)) %>

          <div :if={not daily_data?} class="text-sm opacity-40 py-12 text-center">
            No queries in this period
          </div>

          <svg
            :if={daily_data?}
            viewBox={"0 0 #{length(@daily)} 100"}
            preserveAspectRatio="none"
            class="w-full h-40"
            role="img"
            aria-label={"Daily query totals over the last #{length(@daily)} days"}
          >
            <% dmax = daily_max(@daily) %>
            <%= for {day, i} <- Enum.with_index(@daily) do %>
              <% ok_h = day.ok / dmax * 100 %>
              <% blocked_h = day.blocked / dmax * 100 %>
              <% other_h = (day.error + day.rate_limited) / dmax * 100 %>
              <rect x={i} y="0" width="1" height="100" fill="transparent">
                <title>
                  {day_label(day.date)} — {day.total} queries ({day.blocked} blocked, {day.error +
                    day.rate_limited} failed)
                </title>
              </rect>
              <rect
                :if={ok_h > 0}
                x={i + 0.1}
                width="0.8"
                y={100 - ok_h}
                height={ok_h}
                fill="currentColor"
                class="text-success"
              />
              <rect
                :if={blocked_h > 0}
                x={i + 0.1}
                width="0.8"
                y={100 - ok_h - blocked_h}
                height={blocked_h}
                fill="currentColor"
                class="text-warning"
              />
              <rect
                :if={other_h > 0}
                x={i + 0.1}
                width="0.8"
                y={100 - ok_h - blocked_h - other_h}
                height={other_h}
                fill="currentColor"
                class="text-error"
              />
            <% end %>
          </svg>

          <div :if={daily_data?} class="flex justify-between text-xs opacity-40 tabular-nums">
            <span>{day_label(List.first(@daily).date)}</span>
            <span>{day_label(List.last(@daily).date)}</span>
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

  defp series_max(series) do
    series |> Enum.map(& &1.total) |> Enum.max(fn -> 0 end) |> max(1)
  end

  defp bucket_label(unix) do
    unix |> DateTime.from_unix!() |> Calendar.strftime("%H:%M")
  end

  defp period_label(:today), do: "today"
  defp period_label(:week), do: "7 days"
  defp period_label(:month), do: "30 days"

  defp daily_max(daily) do
    daily |> Enum.map(& &1.total) |> Enum.max(fn -> 0 end) |> max(1)
  end

  defp day_label(%Date{} = date), do: Calendar.strftime(date, "%b %-d")

  defp bar_width(_count, []), do: 0

  defp bar_width(count, items) do
    max = items |> List.first() |> Map.get(:count, 1)
    if max == 0, do: 0, else: round(count / max * 100)
  end
end
