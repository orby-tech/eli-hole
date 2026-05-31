defmodule EliHoleWeb.QueryLogLive do
  use EliHoleWeb, :live_view

  alias EliHole.DNS.QueryLog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:queries")
    end

    queries = QueryLog.recent(200)

    {:ok,
     socket
     |> assign(:active_nav, :queries)
     |> stream(:queries, queries)}
  end

  @impl true
  def handle_info({:new_query, entry}, socket) do
    {:noreply, stream_insert(socket, :queries, entry, at: 0)}
  end

  @impl true
  def handle_event("clear", _, socket) do
    QueryLog.clear()
    {:noreply, stream(socket, :queries, [], reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="space-y-4">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Query Log</h1>
          <button
            phx-click="clear"
            data-confirm="Clear all query history?"
            class="btn btn-error btn-sm"
          >
            Clear
          </button>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm w-full">
            <thead>
              <tr class="text-base-content/60">
                <th>Time</th>
                <th>Client</th>
                <th>Domain</th>
                <th>Type</th>
                <th>Upstream</th>
                <th>Duration</th>
                <th>Status</th>
                <th>DNSSEC</th>
              </tr>
            </thead>
            <tbody id="queries" phx-update="stream">
              <tr :for={{dom_id, q} <- @streams.queries} id={dom_id} class="hover:bg-base-200">
                <td class="font-mono text-xs whitespace-nowrap">{q.time}</td>
                <td class="font-mono text-xs">{q.client}</td>
                <td class="font-mono text-sm font-medium max-w-xs truncate">{q.domain}</td>
                <td class="text-xs">{q.type}</td>
                <td class="font-mono text-xs">{q.upstream || "—"}</td>
                <td class="text-xs whitespace-nowrap">{q.duration_ms}ms</td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    cond do
                      q.status == :ok -> "badge-success"
                      q.status == :blocked -> "badge-warning"
                      q.status == :rate_limited -> "badge-neutral"
                      true -> "badge-error"
                    end
                  ]}>
                    {q.status}
                  </span>
                </td>
                <td>
                  <span
                    :if={q[:dnssec]}
                    class={[
                      "badge badge-sm",
                      cond do
                        q[:dnssec] == :secure -> "badge-success"
                        q[:dnssec] == :insecure -> "badge-ghost"
                        true -> "badge-error"
                      end
                    ]}
                    title="DNSSEC validation result"
                  >
                    {q[:dnssec]}
                  </span>
                  <span :if={is_nil(q[:dnssec])} class="text-base-content/30 text-xs">—</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
