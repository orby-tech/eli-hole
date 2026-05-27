defmodule EliHoleWeb.LocalDNSLive do
  use EliHoleWeb, :live_view

  alias EliHole.DNS.{LocalDNS, LocalRecord}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:local_dns")
    end

    stats = LocalDNS.stats()

    {:ok,
     socket
     |> assign(:active_nav, :local_dns)
     |> assign(:stats, stats)
     |> assign(:search_query, "")
     |> assign(:page, 1)
     |> assign(:filtered_total, stats.total)
     |> assign(:show_import, false)
     |> assign(:import_text, "")
     |> assign(:form, to_form(LocalRecord.changeset(%LocalRecord{}, %{})))
     |> stream(:records, load_records("", 1))}
  end

  @impl true
  def handle_info(:local_dns_changed, socket) do
    query = socket.assigns.search_query
    page = socket.assigns.page
    records = load_records(query, page)
    stats = LocalDNS.stats()

    {:noreply,
     socket
     |> assign(:stats, stats)
     |> assign(:filtered_total, LocalDNS.count_records(query))
     |> stream(:records, records, reset: true)}
  end

  @impl true
  def handle_event("add_record", %{"local_record" => params}, socket) do
    case LocalDNS.create_record(params) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> assign(:form, to_form(LocalRecord.changeset(%LocalRecord{}, %{})))
         |> assign(:stats, LocalDNS.stats())
         |> assign(:page, 1)
         |> assign(:filtered_total, LocalDNS.count_records(socket.assigns.search_query))
         |> stream(:records, load_records(socket.assigns.search_query, 1), reset: true)
         |> put_flash(:info, "Local DNS record added")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("validate_record", %{"local_record" => params}, socket) do
    changeset =
      %LocalRecord{}
      |> LocalRecord.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("toggle_record", %{"id" => id}, socket) do
    record = LocalDNS.get_record!(id)
    LocalDNS.update_record(record, %{enabled: !record.enabled})
    query = socket.assigns.search_query

    {:noreply,
     socket
     |> assign(:stats, LocalDNS.stats())
     |> assign(:filtered_total, LocalDNS.count_records(query))
     |> stream(:records, load_records(query, socket.assigns.page), reset: true)}
  end

  @impl true
  def handle_event("delete_record", %{"id" => id}, socket) do
    record = LocalDNS.get_record!(id)
    LocalDNS.delete_record(record)
    query = socket.assigns.search_query

    {:noreply,
     socket
     |> assign(:stats, LocalDNS.stats())
     |> assign(:filtered_total, LocalDNS.count_records(query))
     |> stream(:records, load_records(query, socket.assigns.page), reset: true)
     |> put_flash(:info, "Record removed")}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:page, 1)
     |> assign(:filtered_total, LocalDNS.count_records(query))
     |> stream(:records, load_records(query, 1), reset: true)}
  end

  @impl true
  def handle_event("page", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)
    query = socket.assigns.search_query

    {:noreply,
     socket
     |> assign(:page, page)
     |> assign(:filtered_total, LocalDNS.count_records(query))
     |> stream(:records, load_records(query, page), reset: true)}
  end

  @impl true
  def handle_event("toggle_import", _, socket) do
    {:noreply, assign(socket, :show_import, !socket.assigns.show_import)}
  end

  @impl true
  def handle_event("import", %{"import_text" => text}, socket) do
    {:ok, count} = LocalDNS.import_custom_list(text)

    {:noreply,
     socket
     |> assign(:stats, LocalDNS.stats())
     |> assign(:show_import, false)
     |> assign(:import_text, "")
     |> assign(:page, 1)
     |> assign(:filtered_total, LocalDNS.count_records(socket.assigns.search_query))
     |> stream(:records, load_records(socket.assigns.search_query, 1), reset: true)
     |> put_flash(:info, "Imported #{count} local DNS records")}
  end

  @impl true
  def handle_event("flush_cache", _, socket) do
    LocalDNS.flush_cache()
    {:noreply, put_flash(socket, :info, "Local DNS cache reloaded")}
  end

  defp load_records("", page), do: LocalDNS.list_records(page: page)
  defp load_records(query, page), do: LocalDNS.search_records(query, page: page)

  defp total_pages(total), do: max(1, ceil(total / 50))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Local DNS</h1>
          <button phx-click="flush_cache" class="btn btn-warning btn-sm">
            <.icon name="hero-arrow-path" class="size-4" /> Reload Cache
          </button>
        </div>

        <%!-- Stats --%>
        <div class="grid grid-cols-3 gap-4">
          <div class="stat bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Total Records</div>
            <div class="text-3xl font-bold">{@stats.total}</div>
          </div>
          <div class="stat bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Enabled</div>
            <div class="text-3xl font-bold text-success">{@stats.enabled}</div>
          </div>
          <div class="stat bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Disabled</div>
            <div class="text-3xl font-bold text-warning">{@stats.disabled}</div>
          </div>
        </div>

        <%!-- Add record form --%>
        <div class="bg-base-200 rounded-xl p-4 space-y-3">
          <h2 class="text-lg font-semibold">Add Record</h2>
          <.form
            for={@form}
            id="add-record-form"
            phx-submit="add_record"
            phx-change="validate_record"
            class="flex flex-wrap items-end gap-3"
          >
            <div class="flex-1 min-w-[200px]">
              <.input
                field={@form[:domain]}
                type="text"
                placeholder="myserver.local"
                label="Domain"
              />
            </div>
            <div class="w-28">
              <.input
                field={@form[:record_type]}
                type="select"
                label="Type"
                options={[{"A", "A"}, {"AAAA", "AAAA"}, {"CNAME", "CNAME"}]}
              />
            </div>
            <div class="flex-1 min-w-[180px]">
              <.input
                field={@form[:target]}
                type="text"
                placeholder="192.168.1.100"
                label="Target"
              />
            </div>
            <div class="flex-1 min-w-[150px]">
              <.input
                field={@form[:comment]}
                type="text"
                placeholder="Optional comment"
                label="Comment"
              />
            </div>
            <button type="submit" class="btn btn-primary btn-sm">Add</button>
          </.form>
        </div>

        <%!-- Bulk import --%>
        <div class="bg-base-200 rounded-xl p-4 space-y-3">
          <div class="flex items-center justify-between">
            <h2 class="text-lg font-semibold">Bulk Import</h2>
            <button phx-click="toggle_import" class="btn btn-ghost btn-sm">
              <%= if @show_import do %>
                Hide
              <% else %>
                Show
              <% end %>
            </button>
          </div>
          <%= if @show_import do %>
            <p class="text-sm opacity-60">
              Paste IP-domain pairs, one per line. Supports Pi-hole custom.list and /etc/hosts format.
            </p>
            <form phx-submit="import" id="import-local-dns-form">
              <textarea
                name="import_text"
                rows="8"
                class="textarea textarea-bordered w-full font-mono text-sm"
                placeholder="192.168.1.1 myrouter.local\n192.168.1.2 mynas.local\n10.0.0.5 homeassistant.local"
              >{@import_text}</textarea>
              <div class="flex justify-end mt-2">
                <button type="submit" class="btn btn-primary btn-sm">Import</button>
              </div>
            </form>
          <% end %>
        </div>

        <%!-- Search --%>
        <div class="flex items-center gap-2">
          <form phx-change="search" phx-submit="search" id="search-local-dns-form" class="flex-1">
            <input
              type="text"
              name="query"
              value={@search_query}
              placeholder="Search domains or targets..."
              class="input input-sm input-bordered w-full"
              phx-debounce="300"
            />
          </form>
        </div>

        <%!-- Records table --%>
        <div class="overflow-x-auto">
          <table class="table table-sm w-full">
            <thead>
              <tr class="text-base-content/60">
                <th>Domain</th>
                <th>Type</th>
                <th>Target</th>
                <th>Comment</th>
                <th>Status</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody id="local-dns-records" phx-update="stream">
              <tr
                :for={{dom_id, record} <- @streams.records}
                id={dom_id}
                class={[
                  "hover:bg-base-200",
                  if(!record.enabled, do: "opacity-50")
                ]}
              >
                <td class="font-mono text-sm font-medium max-w-xs truncate">{record.domain}</td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    cond do
                      record.record_type == "A" -> "badge-primary"
                      record.record_type == "AAAA" -> "badge-secondary"
                      true -> "badge-accent"
                    end
                  ]}>
                    {record.record_type}
                  </span>
                </td>
                <td class="font-mono text-sm">{record.target}</td>
                <td class="text-xs opacity-60 max-w-[200px] truncate">{record.comment || ""}</td>
                <td>
                  <button
                    phx-click="toggle_record"
                    phx-value-id={record.id}
                    class={[
                      "badge badge-sm cursor-pointer",
                      if(record.enabled, do: "badge-success", else: "badge-warning")
                    ]}
                  >
                    <%= if record.enabled do %>
                      enabled
                    <% else %>
                      disabled
                    <% end %>
                  </button>
                </td>
                <td>
                  <button
                    phx-click="delete_record"
                    phx-value-id={record.id}
                    data-confirm="Remove this record?"
                    class="btn btn-ghost btn-xs text-error"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Pagination --%>
        <div class="flex items-center justify-between">
          <span class="text-sm opacity-60">
            Page {@page} of {total_pages(@filtered_total)}
          </span>
          <div class="flex gap-1">
            <button
              :if={@page > 1}
              phx-click="page"
              phx-value-page={@page - 1}
              class="btn btn-sm btn-outline"
            >
              <.icon name="hero-chevron-left" class="size-4" />
            </button>
            <button
              :if={@page < total_pages(@filtered_total)}
              phx-click="page"
              phx-value-page={@page + 1}
              class="btn btn-sm btn-outline"
            >
              <.icon name="hero-chevron-right" class="size-4" />
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
