defmodule EliHoleWeb.WhitelistLive do
  use EliHoleWeb, :live_view

  alias EliHole.DNS.{Whitelist, WhitelistEntry}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:whitelist")
    end

    stats = Whitelist.stats()

    {:ok,
     socket
     |> assign(:active_nav, :whitelist)
     |> assign(:stats, stats)
     |> assign(:search_query, "")
     |> assign(:page, 1)
     |> assign(:show_import, false)
     |> assign(:import_text, "")
     |> assign(:form, to_form(WhitelistEntry.changeset(%WhitelistEntry{}, %{})))
     |> stream(:entries, load_entries("", 1))}
  end

  @impl true
  def handle_info(:whitelist_changed, socket) do
    page = socket.assigns.page
    entries = load_entries(socket.assigns.search_query, page)
    stats = Whitelist.stats()

    {:noreply,
     socket
     |> assign(:stats, stats)
     |> stream(:entries, entries, reset: true)}
  end

  @impl true
  def handle_event("add_entry", %{"whitelist_entry" => params}, socket) do
    case Whitelist.create_entry(params) do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> assign(:form, to_form(WhitelistEntry.changeset(%WhitelistEntry{}, %{})))
         |> assign(:stats, Whitelist.stats())
         |> assign(:page, 1)
         |> stream(:entries, load_entries(socket.assigns.search_query, 1), reset: true)
         |> put_flash(:info, "Domain added to whitelist")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("validate_entry", %{"whitelist_entry" => params}, socket) do
    changeset =
      %WhitelistEntry{}
      |> WhitelistEntry.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("toggle_entry", %{"id" => id}, socket) do
    entry = Whitelist.get_entry!(id)
    Whitelist.update_entry(entry, %{enabled: !entry.enabled})

    {:noreply,
     socket
     |> assign(:stats, Whitelist.stats())
     |> stream(:entries, load_entries(socket.assigns.search_query, socket.assigns.page),
       reset: true
     )}
  end

  @impl true
  def handle_event("delete_entry", %{"id" => id}, socket) do
    entry = Whitelist.get_entry!(id)
    Whitelist.delete_entry(entry)

    {:noreply,
     socket
     |> assign(:stats, Whitelist.stats())
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
  def handle_event("import", %{"import_text" => text}, socket) do
    {:ok, count} = Whitelist.import_domains(text)

    {:noreply,
     socket
     |> assign(:stats, Whitelist.stats())
     |> assign(:show_import, false)
     |> assign(:import_text, "")
     |> assign(:page, 1)
     |> stream(:entries, load_entries(socket.assigns.search_query, 1), reset: true)
     |> put_flash(:info, "Imported #{count} domains")}
  end

  @impl true
  def handle_event("flush_cache", _, socket) do
    Whitelist.flush_cache()
    {:noreply, put_flash(socket, :info, "Whitelist cache reloaded")}
  end

  defp load_entries("", page), do: Whitelist.list_entries(page: page)
  defp load_entries(query, page), do: Whitelist.search_entries(query, page: page)

  defp total_pages(total), do: max(1, ceil(total / 50))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Whitelist</h1>
          <button phx-click="flush_cache" class="btn btn-warning btn-sm">
            <.icon name="hero-arrow-path" class="size-4" /> Reload Cache
          </button>
        </div>

        <p class="text-sm opacity-60">
          Whitelisted domains always bypass the blocklist, even when a blocklist rule would match them.
        </p>

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
              <.input
                field={@form[:domain]}
                type="text"
                placeholder="cdn.example.com"
                label="Domain"
              />
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
            <form phx-submit="import" id="import-form">
              <textarea
                name="import_text"
                rows="8"
                class="textarea textarea-bordered w-full font-mono text-sm"
                placeholder="cdn.example.com&#10;assets.example.com"
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
            <tbody id="whitelist-entries" phx-update="stream">
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
