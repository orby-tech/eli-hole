defmodule EliHoleWeb.BlocklistLive do
  use EliHoleWeb, :live_view

  alias EliHole.DNS.{Blocklist, BlocklistEntry}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:blocklist")
    end

    stats = Blocklist.stats()

    {:ok,
     socket
     |> assign(:active_nav, :blocklist)
     |> assign(:stats, stats)
     |> assign(:search_query, "")
     |> assign(:page, 1)
     |> assign(:show_import, false)
     |> assign(:import_text, "")
     |> assign(:import_format, "domains")
     |> assign(:form, to_form(BlocklistEntry.changeset(%BlocklistEntry{}, %{})))
     |> stream(:entries, load_entries("", 1))}
  end

  @impl true
  def handle_info(:blocklist_changed, socket) do
    page = socket.assigns.page
    entries = load_entries(socket.assigns.search_query, page)
    stats = Blocklist.stats()

    {:noreply,
     socket
     |> assign(:stats, stats)
     |> stream(:entries, entries, reset: true)}
  end

  @impl true
  def handle_event("add_entry", %{"blocklist_entry" => params}, socket) do
    case Blocklist.create_entry(params) do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> assign(:form, to_form(BlocklistEntry.changeset(%BlocklistEntry{}, %{})))
         |> assign(:stats, Blocklist.stats())
         |> assign(:page, 1)
         |> stream(:entries, load_entries(socket.assigns.search_query, 1), reset: true)
         |> put_flash(:info, "Domain added to blocklist")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("validate_entry", %{"blocklist_entry" => params}, socket) do
    changeset =
      %BlocklistEntry{}
      |> BlocklistEntry.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("toggle_entry", %{"id" => id}, socket) do
    entry = Blocklist.get_entry!(id)
    Blocklist.update_entry(entry, %{enabled: !entry.enabled})

    {:noreply,
     socket
     |> assign(:stats, Blocklist.stats())
     |> stream(:entries, load_entries(socket.assigns.search_query, socket.assigns.page),
       reset: true
     )}
  end

  @impl true
  def handle_event("delete_entry", %{"id" => id}, socket) do
    entry = Blocklist.get_entry!(id)
    Blocklist.delete_entry(entry)

    {:noreply,
     socket
     |> assign(:stats, Blocklist.stats())
     |> stream(:entries, load_entries(socket.assigns.search_query, socket.assigns.page),
       reset: true
     )
     |> put_flash(:info, "Entry removed")}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:page, 1)
     |> stream(:entries, load_entries(query, 1), reset: true)}
  end

  @impl true
  def handle_event("page", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)

    {:noreply,
     socket
     |> assign(:page, page)
     |> stream(:entries, load_entries(socket.assigns.search_query, page), reset: true)}
  end

  @impl true
  def handle_event("toggle_import", _, socket) do
    {:noreply, assign(socket, :show_import, !socket.assigns.show_import)}
  end

  @impl true
  def handle_event("set_import_format", %{"format" => format}, socket) do
    {:noreply, assign(socket, :import_format, format)}
  end

  @impl true
  def handle_event("import", %{"import_text" => text}, socket) do
    {:ok, count} =
      case socket.assigns.import_format do
        "hosts" -> Blocklist.import_hosts(text)
        _ -> Blocklist.import_domains(text)
      end

    {:noreply,
     socket
     |> assign(:stats, Blocklist.stats())
     |> assign(:show_import, false)
     |> assign(:import_text, "")
     |> assign(:page, 1)
     |> stream(:entries, load_entries(socket.assigns.search_query, 1), reset: true)
     |> put_flash(:info, "Imported #{count} domains")}
  end

  @impl true
  def handle_event("flush_cache", _, socket) do
    Blocklist.flush_cache()
    {:noreply, put_flash(socket, :info, "Blocklist cache reloaded")}
  end

  defp load_entries("", page), do: Blocklist.list_entries(page: page)
  defp load_entries(query, page), do: Blocklist.search_entries(query, page: page)

  defp total_pages(total), do: max(1, ceil(total / 50))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Blocklist</h1>
          <button phx-click="flush_cache" class="btn btn-warning btn-sm">
            <.icon name="hero-arrow-path" class="size-4" /> Reload Cache
          </button>
        </div>

        <%!-- Stats --%>
        <div class="grid grid-cols-3 gap-4">
          <div class="stat bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Total Entries</div>
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

        <%!-- Add entry form --%>
        <div class="bg-base-200 rounded-xl p-4 space-y-3">
          <h2 class="text-lg font-semibold">Add Domain</h2>
          <.form
            for={@form}
            id="add-entry-form"
            phx-submit="add_entry"
            phx-change="validate_entry"
            class="flex flex-wrap items-end gap-3"
          >
            <div class="flex-1 min-w-[200px]">
              <.input field={@form[:domain]} type="text" placeholder="ads.example.com" label="Domain" />
            </div>
            <div class="w-36">
              <.input
                field={@form[:type]}
                type="select"
                label="Type"
                options={[{"Exact", "exact"}, {"Wildcard", "wildcard"}, {"Regex", "regex"}]}
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
            <div class="flex gap-2 mb-2">
              <button
                phx-click="set_import_format"
                phx-value-format="domains"
                class={[
                  "btn btn-sm",
                  if(@import_format == "domains", do: "btn-primary", else: "btn-outline")
                ]}
              >
                Domain list
              </button>
              <button
                phx-click="set_import_format"
                phx-value-format="hosts"
                class={[
                  "btn btn-sm",
                  if(@import_format == "hosts", do: "btn-primary", else: "btn-outline")
                ]}
              >
                Hosts file
              </button>
            </div>
            <form phx-submit="import" id="import-form">
              <textarea
                name="import_text"
                rows="8"
                class="textarea textarea-bordered w-full font-mono text-sm"
                placeholder={
                  if(@import_format == "hosts",
                    do: "0.0.0.0 ads.example.com\n0.0.0.0 tracker.example.com",
                    else: "ads.example.com\ntracker.example.com"
                  )
                }
              >{@import_text}</textarea>
              <div class="flex justify-end mt-2">
                <button type="submit" class="btn btn-primary btn-sm">Import</button>
              </div>
            </form>
          <% end %>
        </div>

        <%!-- Search --%>
        <div class="flex items-center gap-2">
          <form phx-change="search" phx-submit="search" id="search-form" class="flex-1">
            <input
              type="text"
              name="query"
              value={@search_query}
              placeholder="Search domains..."
              class="input input-sm input-bordered w-full"
              phx-debounce="300"
            />
          </form>
        </div>

        <%!-- Entries table --%>
        <div class="overflow-x-auto">
          <table class="table table-sm w-full">
            <thead>
              <tr class="text-base-content/60">
                <th>Domain</th>
                <th>Type</th>
                <th>Source</th>
                <th>Comment</th>
                <th>Status</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody id="blocklist-entries" phx-update="stream">
              <tr
                :for={{dom_id, entry} <- @streams.entries}
                id={dom_id}
                class={[
                  "hover:bg-base-200",
                  if(!entry.enabled, do: "opacity-50")
                ]}
              >
                <td class="font-mono text-sm font-medium max-w-xs truncate">{entry.domain}</td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    cond do
                      entry.type == "exact" -> "badge-primary"
                      entry.type == "wildcard" -> "badge-secondary"
                      true -> "badge-accent"
                    end
                  ]}>
                    {entry.type}
                  </span>
                </td>
                <td class="text-xs opacity-60">{entry.source || "manual"}</td>
                <td class="text-xs opacity-60 max-w-[200px] truncate">{entry.comment || ""}</td>
                <td>
                  <button
                    phx-click="toggle_entry"
                    phx-value-id={entry.id}
                    class={[
                      "badge badge-sm cursor-pointer",
                      if(entry.enabled, do: "badge-success", else: "badge-warning")
                    ]}
                  >
                    <%= if entry.enabled do %>
                      enabled
                    <% else %>
                      disabled
                    <% end %>
                  </button>
                </td>
                <td>
                  <button
                    phx-click="delete_entry"
                    phx-value-id={entry.id}
                    data-confirm="Remove this entry?"
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
            Page {@page} of {total_pages(@stats.total)}
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
              :if={@page < total_pages(@stats.total)}
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
