defmodule EliHoleWeb.SettingsLive do
  use EliHoleWeb, :live_view

  alias EliHole.DNS.{Blocklist, Cache, Providers, SpeedTracker, Teleporter, Whitelist}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:cache_settings")
    end

    cache_stats = Cache.stats()
    upstreams = Cache.get_upstreams()
    providers = Providers.list_all()

    {:ok,
     socket
     |> assign(:active_nav, :settings)
     |> assign(:cache_stats, cache_stats)
     |> assign(:ttl_input, to_string(cache_stats.ttl))
     |> assign(:upstreams, upstreams)
     |> assign(:active_presets, detect_active_presets(upstreams))
     |> assign(:providers, providers)
     |> assign(:custom_upstream_input, "")
     |> assign(:presets, Cache.presets())
     |> assign(:speed_stats, SpeedTracker.stats())
     |> assign(:import_result, nil)
     |> allow_upload(:teleporter_file,
       accept: ~w(.gz),
       max_entries: 1,
       max_file_size: 50_000_000
     )}
  end

  @impl true
  def handle_info({:ttl_changed, ttl}, socket) do
    {:noreply,
     socket
     |> assign(:cache_stats, Cache.stats())
     |> assign(:ttl_input, to_string(ttl))}
  end

  @impl true
  def handle_info(:cache_flushed, socket) do
    {:noreply, assign(socket, :cache_stats, Cache.stats())}
  end

  @impl true
  def handle_info({:upstreams_changed, upstreams}, socket) do
    {:noreply,
     socket
     |> assign(:upstreams, upstreams)
     |> assign(:active_presets, detect_active_presets(upstreams))}
  end

  @impl true
  def handle_event("set_ttl", %{"ttl" => ttl_str}, socket) do
    case Integer.parse(ttl_str) do
      {ttl, _} when ttl >= 0 ->
        Cache.set_ttl(ttl)
        {:noreply, assign(socket, :ttl_input, ttl_str)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("flush_cache", _, socket) do
    Cache.flush()
    {:noreply, assign(socket, :cache_stats, Cache.stats())}
  end

  @impl true
  def handle_event("toggle_preset", %{"preset" => preset}, socket) do
    Providers.toggle_preset(preset)
    reload_providers(socket)
  end

  @impl true
  def handle_event("add_upstream", %{"upstream" => upstream_str}, socket) do
    case Cache.parse_upstream(upstream_str) do
      {:ok, {ip, port}} ->
        case Providers.create(%{"ip" => to_string(:inet.ntoa(ip)), "port" => port}) do
          {:ok, _} -> reload_providers(socket, custom_upstream_input: "")
          {:error, _} -> {:noreply, put_flash(socket, :error, "Already exists or invalid")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid format. Use IP:PORT or IP")}
    end
  end

  @impl true
  def handle_event("remove_upstream", %{"id" => id}, socket) do
    providers = Providers.list_all()

    if length(providers) <= 1 do
      {:noreply, put_flash(socket, :error, "Need at least one upstream")}
    else
      provider = Providers.get!(id)
      Providers.delete(provider)
      reload_providers(socket)
    end
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("import_teleporter", _params, socket) do
    [tar_binary] =
      consume_uploaded_entries(socket, :teleporter_file, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    result =
      case Teleporter.detect_format(tar_binary) do
        :pihole -> Teleporter.import_pihole(tar_binary)
        :elihole -> Teleporter.import_elihole(tar_binary)
        :unknown -> {:error, "Unknown backup format"}
      end

    case result do
      {:ok, summary} ->
        Blocklist.flush_cache()
        Whitelist.flush_cache()
        Cache.load_upstreams_from_db()

        gravity = Map.get(summary, :gravity, 0)
        whitelist = Map.get(summary, :whitelist, 0)

        msg =
          "Imported #{summary.blocklist} blocklist entries, #{summary.providers} providers" <>
            if(whitelist > 0, do: ", #{whitelist} whitelist entries", else: "") <>
            if(gravity > 0, do: ", #{gravity} adlists (run Gravity update to download)", else: "") <>
            if(Map.get(summary, :skipped, []) != [],
              do: ". Skipped: #{Enum.join(summary.skipped, ", ")}",
              else: ""
            )

        {:noreply,
         socket
         |> assign(:providers, Providers.list_all())
         |> assign(:upstreams, Cache.get_upstreams())
         |> assign(:active_presets, detect_active_presets(Cache.get_upstreams()))
         |> assign(:speed_stats, SpeedTracker.stats())
         |> put_flash(:info, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Import failed: #{reason}")}
    end
  end

  defp reload_providers(socket, extra_assigns \\ []) do
    Cache.load_upstreams_from_db()
    Cache.flush()
    providers = Providers.list_all()
    upstreams = Cache.get_upstreams()

    socket =
      socket
      |> assign(:providers, providers)
      |> assign(:upstreams, upstreams)
      |> assign(:active_presets, detect_active_presets(upstreams))
      |> assign(:cache_stats, Cache.stats())
      |> assign(:speed_stats, SpeedTracker.stats())

    socket = Enum.reduce(extra_assigns, socket, fn {k, v}, s -> assign(s, k, v) end)
    {:noreply, socket}
  end

  defp detect_active_presets(upstreams) do
    upstream_set = MapSet.new(upstreams)

    Cache.presets()
    |> Enum.filter(fn {_name, servers} ->
      MapSet.subset?(MapSet.new(servers), upstream_set)
    end)
    |> Enum.map(fn {name, _} -> name end)
    |> MapSet.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={@active_nav}>
      <div class="space-y-6">
        <h1 class="text-2xl font-bold">Settings</h1>

        <div class="bg-base-200 rounded-xl p-4 space-y-3">
          <h2 class="text-lg font-semibold">DNS Providers</h2>
          <div class="flex flex-wrap gap-2">
            <button
              :for={{name, _servers} <- @presets}
              phx-click="toggle_preset"
              phx-value-preset={name}
              class={[
                "btn btn-sm",
                if(MapSet.member?(@active_presets, name), do: "btn-primary", else: "btn-outline")
              ]}
            >
              {String.capitalize(name)}
            </button>
          </div>
          <div class="space-y-1">
            <div :for={p <- @providers} class="flex items-center gap-2">
              <span class={[
                "font-mono text-sm",
                if(!p.enabled, do: "opacity-40 line-through")
              ]}>
                {p.ip}:{p.port}
              </span>
              <span :if={p.name} class="text-xs opacity-50">{p.name}</span>
              <button
                phx-click="remove_upstream"
                phx-value-id={p.id}
                class="btn btn-ghost btn-xs text-error"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </div>
          <form phx-submit="add_upstream" class="flex items-center gap-2">
            <input
              type="text"
              name="upstream"
              value={@custom_upstream_input}
              placeholder="1.1.1.1:53"
              class="input input-sm input-bordered w-40"
            />
            <button type="submit" class="btn btn-primary btn-sm">Add</button>
          </form>
        </div>

        <div :if={@speed_stats != []} class="bg-base-200 rounded-xl p-4 space-y-3">
          <h2 class="text-lg font-semibold">Upstream Speed</h2>
          <table class="table table-sm w-full">
            <thead>
              <tr class="text-base-content/60">
                <th>Upstream</th>
                <th>Avg</th>
                <th>Min</th>
                <th>Max</th>
                <th>Samples</th>
                <th>Timeouts</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={s <- @speed_stats}>
                <td class="font-mono text-sm">{Cache.format_upstream(s.upstream)}</td>
                <td class={[
                  "font-bold",
                  cond do
                    s.avg_ms == nil -> "opacity-40"
                    s.avg_ms < 50 -> "text-success"
                    s.avg_ms < 200 -> "text-warning"
                    true -> "text-error"
                  end
                ]}>
                  {s.avg_ms || "—"}ms
                </td>
                <td class="text-xs opacity-60">{s.min_ms || "—"}ms</td>
                <td class="text-xs opacity-60">{s.max_ms || "—"}ms</td>
                <td class="text-xs">{s.samples}</td>
                <td class={[
                  "text-xs",
                  if(s.timeouts > 0, do: "text-error font-bold", else: "opacity-40")
                ]}>
                  {s.timeouts}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="bg-base-200 rounded-xl p-4 space-y-3">
          <div class="flex items-center justify-between">
            <h2 class="text-lg font-semibold">Cache</h2>
            <button
              phx-click="flush_cache"
              data-confirm="Flush DNS cache?"
              class="btn btn-warning btn-sm"
            >
              Flush
            </button>
          </div>
          <div class="grid grid-cols-3 gap-4 text-center">
            <div>
              <div class="text-sm opacity-60">Active entries</div>
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
          <form phx-submit="set_ttl" class="flex items-center gap-2">
            <label class="text-sm opacity-60 shrink-0">TTL (seconds):</label>
            <input
              type="number"
              name="ttl"
              value={@ttl_input}
              min="0"
              max="86400"
              class="input input-sm input-bordered w-28"
            />
            <button type="submit" class="btn btn-primary btn-sm">Apply</button>
          </form>
        </div>
        <div class="bg-base-200 rounded-xl p-4 space-y-3">
          <h2 class="text-lg font-semibold">Teleporter</h2>
          <p class="text-sm opacity-60">
            Import from Pi-hole backup or EliHole export. Export current config.
          </p>

          <div class="flex flex-wrap gap-4">
            <div class="flex-1 min-w-[250px] space-y-3">
              <h3 class="text-sm font-medium">Import</h3>
              <form
                id="teleporter-import-form"
                phx-submit="import_teleporter"
                phx-change="validate_upload"
              >
                <div
                  class="border-2 border-dashed border-base-300 rounded-lg p-4 text-center"
                  phx-drop-target={@uploads.teleporter_file.ref}
                >
                  <.live_file_input upload={@uploads.teleporter_file} class="hidden" />
                  <%= if @uploads.teleporter_file.entries == [] do %>
                    <label for={@uploads.teleporter_file.ref} class="cursor-pointer space-y-2">
                      <.icon name="hero-arrow-up-tray" class="size-8 mx-auto opacity-40" />
                      <p class="text-sm opacity-60">Drop .tar.gz or click to browse</p>
                      <p class="text-xs opacity-40">Pi-hole Teleporter or EliHole backup</p>
                    </label>
                  <% else %>
                    <%= for entry <- @uploads.teleporter_file.entries do %>
                      <div class="flex items-center justify-between">
                        <span class="text-sm font-mono">{entry.client_name}</span>
                        <span class="text-xs opacity-60">
                          {Float.round(entry.client_size / 1_000_000, 2)} MB
                        </span>
                      </div>
                      <%= for err <- upload_errors(@uploads.teleporter_file, entry) do %>
                        <p class="text-error text-xs">{inspect(err)}</p>
                      <% end %>
                    <% end %>
                  <% end %>
                </div>
                <div class="flex justify-end mt-2">
                  <button
                    type="submit"
                    class="btn btn-primary btn-sm"
                    disabled={@uploads.teleporter_file.entries == []}
                  >
                    <.icon name="hero-arrow-down-tray" class="size-4" /> Import
                  </button>
                </div>
              </form>
            </div>

            <div class="flex-1 min-w-[200px] space-y-3">
              <h3 class="text-sm font-medium">Export</h3>
              <p class="text-xs opacity-60">
                Download blocklist entries and DNS providers as .tar.gz backup.
              </p>
              <a
                href={~p"/admin/teleporter/export"}
                class="btn btn-outline btn-sm"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" /> Export Config
              </a>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
