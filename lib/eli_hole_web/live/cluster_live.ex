defmodule EliHoleWeb.ClusterLive do
  use EliHoleWeb, :live_view

  alias EliHole.DNS.{Cluster, ClusterManager, ClusterSync}

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    role = Cluster.instance_role()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:cluster")
      schedule_refresh()
    end

    socket =
      socket
      |> assign(:active_nav, :cluster)
      |> assign(:role, role)
      |> assign(:show_add_form, false)
      |> assign(:form, to_form(%{"name" => "", "url" => "", "api_key" => ""}, as: :node))
      |> assign_data()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_data(socket)}
  end

  def handle_info({:stats_updated, _name}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info({:node_added, _node}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info({:node_removed, _node}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_add_form", _params, socket) do
    {:noreply, assign(socket, :show_add_form, !socket.assigns.show_add_form)}
  end

  def handle_event("add_node", %{"node" => params}, socket) do
    case Cluster.create_node(params) do
      {:ok, node} ->
        Task.Supervisor.start_child(EliHole.TaskSupervisor, fn ->
          Cluster.push_config_to_node(node)
        end)

        {:noreply,
         socket
         |> put_flash(:info, "Node #{node.name} added")
         |> assign(:show_add_form, false)
         |> assign(:form, to_form(%{"name" => "", "url" => "", "api_key" => ""}, as: :node))
         |> assign_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :node))}
    end
  end

  def handle_event("delete_node", %{"id" => id}, socket) do
    node = Cluster.get_node!(id)

    case Cluster.delete_node(node) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Node #{node.name} removed")
         |> assign_data()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove node")}
    end
  end

  def handle_event("push_config", %{"id" => id}, socket) do
    node = Cluster.get_node!(id)

    Task.Supervisor.start_child(EliHole.TaskSupervisor, fn ->
      Cluster.push_config_to_node(node)
    end)

    {:noreply, put_flash(socket, :info, "Config push to #{node.name} initiated")}
  end

  def handle_event("push_all", _params, socket) do
    Task.Supervisor.start_child(EliHole.TaskSupervisor, fn -> Cluster.push_config_to_all() end)
    {:noreply, put_flash(socket, :info, "Config push to all nodes initiated")}
  end

  defp assign_data(socket) do
    case socket.assigns.role do
      :master -> assign_master_data(socket)
      :slave -> assign_slave_data(socket)
      _ -> assign(socket, nodes: [], node_stats: %{}, slave_status: nil)
    end
  end

  defp assign_master_data(socket) do
    nodes = Cluster.list_nodes()
    all_stats = ClusterManager.all_node_stats()

    node_stats =
      Map.new(all_stats, fn %{name: name, stats: stats, received_at: received_at} ->
        {name, %{stats: stats, received_at: received_at}}
      end)

    socket
    |> assign(:nodes, nodes)
    |> assign(:node_stats, node_stats)
  end

  defp assign_slave_data(socket) do
    status =
      case GenServer.whereis(ClusterSync) do
        nil -> %{registered: false, last_push: nil, master_status: :disconnected}
        _pid -> ClusterSync.status()
      end

    socket
    |> assign(:slave_status, status)
    |> assign(:nodes, [])
    |> assign(:node_stats, %{})
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold">Cluster</h1>
            <p class="text-sm opacity-60 mt-1">
              Role:
              <span class={[
                "font-semibold px-2 py-0.5 rounded-full text-xs",
                cond do
                  @role == :master -> "bg-primary/20 text-primary"
                  @role == :slave -> "bg-secondary/20 text-secondary"
                  true -> "bg-base-300 opacity-60"
                end
              ]}>
                {@role |> to_string() |> String.upcase()}
              </span>
            </p>
          </div>
          <div :if={@role == :master} class="flex gap-2">
            <button phx-click="push_all" class="btn btn-sm btn-outline">
              <.icon name="hero-arrow-path" class="size-4" /> Push to All
            </button>
            <button phx-click="toggle_add_form" class="btn btn-sm btn-primary">
              <.icon name="hero-plus" class="size-4" /> Add Node
            </button>
          </div>
        </div>

        <%= cond do %>
          <% @role == :standalone -> %>
            <.standalone_view />
          <% @role == :master -> %>
            <.master_view
              nodes={@nodes}
              node_stats={@node_stats}
              show_add_form={@show_add_form}
              form={@form}
            />
          <% @role == :slave -> %>
            <.slave_view status={@slave_status} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp standalone_view(assigns) do
    ~H"""
    <div class="bg-base-200 rounded-xl p-8 text-center space-y-4">
      <.icon name="hero-server-stack" class="size-12 opacity-30 mx-auto" />
      <h2 class="text-lg font-semibold">Standalone Mode</h2>
      <p class="text-sm opacity-60 max-w-md mx-auto">
        This instance runs independently. To enable clustering, set the
        <code class="px-1.5 py-0.5 bg-base-300 rounded text-xs">INSTANCE_ROLE</code>
        environment variable to <code class="px-1.5 py-0.5 bg-base-300 rounded text-xs">master</code>
        or <code class="px-1.5 py-0.5 bg-base-300 rounded text-xs">slave</code>.
      </p>
      <div class="bg-base-300 rounded-lg p-4 text-left max-w-lg mx-auto">
        <p class="text-xs font-semibold opacity-60 mb-2">Master setup:</p>
        <pre class="text-xs font-mono opacity-80" phx-no-curly-interpolation>INSTANCE_ROLE=master
    CLUSTER_API_KEY=your-shared-secret</pre>
        <p class="text-xs font-semibold opacity-60 mb-2 mt-4">Slave setup:</p>
        <pre class="text-xs font-mono opacity-80" phx-no-curly-interpolation>INSTANCE_ROLE=slave
    CLUSTER_API_KEY=your-shared-secret
    CLUSTER_MASTER_URL=http://master-host:4000
    INSTANCE_NAME=slave-1
    INSTANCE_URL=http://this-slave:4000</pre>
      </div>
    </div>
    """
  end

  attr :nodes, :list, required: true
  attr :node_stats, :map, required: true
  attr :show_add_form, :boolean, required: true
  attr :form, :map, required: true

  defp master_view(assigns) do
    ~H"""
    <div :if={@show_add_form} class="bg-base-200 rounded-xl p-4">
      <h3 class="font-semibold mb-3">Add Slave Node</h3>
      <.form
        for={@form}
        id="add-node-form"
        phx-submit="add_node"
        class="flex flex-col sm:flex-row gap-3"
      >
        <.input
          field={@form[:name]}
          placeholder="Node name"
          class="flex-1 input input-sm input-bordered"
        />
        <.input
          field={@form[:url]}
          placeholder="http://slave-host:4000"
          class="flex-1 input input-sm input-bordered"
        />
        <.input
          field={@form[:api_key]}
          placeholder="API key"
          class="flex-1 input input-sm input-bordered"
        />
        <button type="submit" class="btn btn-sm btn-primary">Add</button>
        <button type="button" phx-click="toggle_add_form" class="btn btn-sm btn-ghost">Cancel</button>
      </.form>
    </div>

    <div :if={@nodes == []} class="bg-base-200 rounded-xl p-8 text-center">
      <.icon name="hero-server-stack" class="size-10 opacity-30 mx-auto mb-3" />
      <p class="opacity-60">No slave nodes registered yet</p>
    </div>

    <div :if={@nodes != []} class="space-y-3">
      <div
        :for={node <- @nodes}
        class="bg-base-200 rounded-xl p-4"
      >
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-3">
            <div class={[
              "w-2.5 h-2.5 rounded-full",
              if(node.status == "online", do: "bg-success", else: "bg-error")
            ]} />
            <div>
              <span class="font-semibold">{node.name}</span>
              <span class="text-xs opacity-50 ml-2">{node.url}</span>
            </div>
          </div>
          <div class="flex gap-2">
            <button phx-click="push_config" phx-value-id={node.id} class="btn btn-xs btn-ghost">
              <.icon name="hero-arrow-path" class="size-3.5" /> Push
            </button>
            <button
              phx-click="delete_node"
              phx-value-id={node.id}
              data-confirm={"Remove #{node.name}?"}
              class="btn btn-xs btn-ghost text-error"
            >
              <.icon name="hero-trash" class="size-3.5" />
            </button>
          </div>
        </div>

        <div class="text-xs opacity-50 mb-2">
          Last seen: {format_time(node.last_seen_at)}
        </div>

        <%= if stats_data = @node_stats[node.name] do %>
          <div class="grid grid-cols-2 sm:grid-cols-5 gap-3 text-sm">
            <div>
              <span class="opacity-60">Queries</span>
              <div class="font-bold">{stats_data.stats["total"] || 0}</div>
            </div>
            <div>
              <span class="opacity-60">Resolved</span>
              <div class="font-bold text-success">{stats_data.stats["ok"] || 0}</div>
            </div>
            <div>
              <span class="opacity-60">Blocked</span>
              <div class="font-bold text-warning">{stats_data.stats["blocked_count"] || 0}</div>
            </div>
            <div>
              <span class="opacity-60">Failed</span>
              <div class="font-bold text-error">{stats_data.stats["error"] || 0}</div>
            </div>
            <div>
              <span class="opacity-60">QPS</span>
              <div class="font-bold">{stats_data.stats["qps"] || 0}</div>
            </div>
          </div>
        <% else %>
          <p class="text-xs opacity-40">No stats received yet</p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :status, :map, required: true

  defp slave_view(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="bg-base-200 rounded-xl p-6">
        <h2 class="text-lg font-semibold mb-4">Master Connection</h2>
        <div class="flex items-center gap-3 mb-4">
          <div class={[
            "w-3 h-3 rounded-full",
            cond do
              @status.master_status == :connected -> "bg-success"
              @status.master_status == :connecting -> "bg-warning animate-pulse"
              true -> "bg-error"
            end
          ]} />
          <span class="font-medium">
            {@status.master_status |> to_string() |> String.capitalize()}
          </span>
        </div>
        <div class="grid grid-cols-2 gap-4 text-sm">
          <div>
            <span class="opacity-60">Registered</span>
            <div class="font-semibold">{if(@status.registered, do: "Yes", else: "No")}</div>
          </div>
          <div>
            <span class="opacity-60">Last Stats Push</span>
            <div class="font-semibold">{format_time(@status.last_push)}</div>
          </div>
        </div>
      </div>

      <div class="bg-base-200 rounded-xl p-6">
        <h2 class="text-lg font-semibold mb-3">Slave Info</h2>
        <div class="space-y-2 text-sm">
          <div class="flex justify-between">
            <span class="opacity-60">Master URL</span>
            <span class="font-mono text-xs">
              {Application.get_env(:eli_hole, :cluster_master_url) || "—"}
            </span>
          </div>
          <div class="flex justify-between">
            <span class="opacity-60">Instance Name</span>
            <span class="font-mono text-xs">
              {Application.get_env(:eli_hole, :cluster_instance_name) || "—"}
            </span>
          </div>
          <div class="flex justify-between">
            <span class="opacity-60">Instance URL</span>
            <span class="font-mono text-xs">
              {Application.get_env(:eli_hole, :cluster_instance_url) || "—"}
            </span>
          </div>
        </div>
      </div>

      <div class="bg-base-300/50 rounded-lg p-4 text-sm opacity-60">
        <.icon name="hero-information-circle" class="size-4 inline" />
        Configuration is managed by master. Changes made here will be overwritten on next sync.
      </div>
    </div>
    """
  end

  defp format_time(nil), do: "Never"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S %Y-%m-%d")
  end

  defp format_time(_), do: "—"
end
