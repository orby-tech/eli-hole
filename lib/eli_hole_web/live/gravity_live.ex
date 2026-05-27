defmodule EliHoleWeb.GravityLive do
  use EliHoleWeb, :live_view

  alias EliHole.DNS.{Adlist, Adlists, Gravity}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:gravity")
    end

    gravity_status = Gravity.status()

    {:ok,
     socket
     |> assign(:active_nav, :gravity)
     |> assign(:stats, Adlists.stats())
     |> assign(:updating, gravity_status.updating)
     |> assign(:last_update, gravity_status.last_update)
     |> assign(:form, to_form(Adlist.changeset(%Adlist{}, %{})))
     |> stream(:adlists, Adlists.list_all())}
  end

  @impl true
  def handle_info({:gravity_status, :updating}, socket) do
    {:noreply, assign(socket, :updating, true)}
  end

  def handle_info({:gravity_status, :idle}, socket) do
    {:noreply, assign(socket, :updating, false)}
  end

  def handle_info(:gravity_updated, socket) do
    status = Gravity.status()

    {:noreply,
     socket
     |> assign(:stats, Adlists.stats())
     |> assign(:last_update, status.last_update)
     |> stream(:adlists, Adlists.list_all(), reset: true)}
  end

  @impl true
  def handle_event("add_adlist", %{"adlist" => params}, socket) do
    case Adlists.create(params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Adlist.changeset(%Adlist{}, %{})))
         |> assign(:stats, Adlists.stats())
         |> stream(:adlists, Adlists.list_all(), reset: true)
         |> put_flash(:info, "Adlist added")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("validate_adlist", %{"adlist" => params}, socket) do
    changeset =
      %Adlist{}
      |> Adlist.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("toggle_adlist", %{"id" => id}, socket) do
    adlist = Adlists.get!(id)
    Adlists.update(adlist, %{enabled: !adlist.enabled})

    {:noreply,
     socket
     |> assign(:stats, Adlists.stats())
     |> stream(:adlists, Adlists.list_all(), reset: true)}
  end

  @impl true
  def handle_event("delete_adlist", %{"id" => id}, socket) do
    adlist = Adlists.get!(id)
    Adlists.delete(adlist)

    {:noreply,
     socket
     |> assign(:stats, Adlists.stats())
     |> stream(:adlists, Adlists.list_all(), reset: true)
     |> put_flash(:info, "Adlist removed")}
  end

  @impl true
  def handle_event("update_gravity", _, socket) do
    Gravity.update_now()
    {:noreply, put_flash(socket, :info, "Gravity update started...")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">Gravity</h1>
          <button
            phx-click="update_gravity"
            class={["btn btn-primary btn-sm", if(@updating, do: "loading")]}
            disabled={@updating}
          >
            <.icon name="hero-arrow-path" class={["size-4", if(@updating, do: "animate-spin")]} />
            <%= if @updating do %>
              Updating...
            <% else %>
              Update Gravity
            <% end %>
          </button>
        </div>

        <%!-- Stats --%>
        <div class="grid grid-cols-3 gap-4">
          <div class="stat bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Adlists</div>
            <div class="text-3xl font-bold">
              {@stats.enabled}<span class="text-lg opacity-40">/{@stats.total}</span>
            </div>
          </div>
          <div class="stat bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Domains Blocked</div>
            <div class="text-3xl font-bold text-error">{@stats.total_domains}</div>
          </div>
          <div class="stat bg-base-200 rounded-xl p-4">
            <div class="text-sm opacity-60">Last Update</div>
            <div class="text-lg font-bold">
              <%= if @last_update do %>
                {Calendar.strftime(@last_update, "%Y-%m-%d %H:%M")}
              <% else %>
                Never
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Add adlist --%>
        <div class="bg-base-200 rounded-xl p-4 space-y-3">
          <h2 class="text-lg font-semibold">Add Adlist</h2>
          <.form
            for={@form}
            id="add-adlist-form"
            phx-submit="add_adlist"
            phx-change="validate_adlist"
            class="flex flex-wrap items-end gap-3"
          >
            <div class="flex-1 min-w-[300px]">
              <.input
                field={@form[:address]}
                type="text"
                placeholder="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
                label="URL"
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

        <%!-- Adlists table --%>
        <div class="overflow-x-auto">
          <table class="table table-sm w-full">
            <thead>
              <tr class="text-base-content/60">
                <th>URL</th>
                <th>Comment</th>
                <th>Domains</th>
                <th>Last Updated</th>
                <th>Status</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody id="adlists" phx-update="stream">
              <tr
                :for={{dom_id, adlist} <- @streams.adlists}
                id={dom_id}
                class={[
                  "hover:bg-base-200",
                  if(!adlist.enabled, do: "opacity-50")
                ]}
              >
                <td class="font-mono text-xs max-w-sm truncate" title={adlist.address}>
                  {adlist.address}
                </td>
                <td class="text-xs opacity-60 max-w-[150px] truncate">{adlist.comment || ""}</td>
                <td class="font-mono text-sm">{adlist.domain_count}</td>
                <td class="text-xs opacity-60">
                  <%= if adlist.last_updated_at do %>
                    {Calendar.strftime(adlist.last_updated_at, "%m-%d %H:%M")}
                  <% else %>
                    —
                  <% end %>
                </td>
                <td>
                  <button
                    phx-click="toggle_adlist"
                    phx-value-id={adlist.id}
                    class={[
                      "badge badge-sm cursor-pointer",
                      if(adlist.enabled, do: "badge-success", else: "badge-warning")
                    ]}
                  >
                    <%= if adlist.enabled do %>
                      enabled
                    <% else %>
                      disabled
                    <% end %>
                  </button>
                </td>
                <td>
                  <button
                    phx-click="delete_adlist"
                    phx-value-id={adlist.id}
                    data-confirm="Remove this adlist?"
                    class="btn btn-ghost btn-xs text-error"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
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
