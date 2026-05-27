defmodule EliHole.DNS.Cache do
  use GenServer

  @table :dns_cache
  @settings_table :dns_cache_settings
  @default_ttl 300
  @cleanup_interval :timer.seconds(30)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def lookup(domain, type) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, {domain, type}) do
      [{_key, response, upstream, expires_at}] when expires_at > now ->
        {:hit, response, upstream}

      [{_key, response, expires_at}] when expires_at > now ->
        {:hit, response, "?"}

      _ ->
        :miss
    end
  end

  def put(domain, type, response, upstream) do
    ttl = get_ttl()
    expires_at = System.monotonic_time(:second) + ttl
    :ets.insert(@table, {{domain, type}, response, upstream, expires_at})
  end

  def get_ttl do
    case :ets.lookup(@settings_table, :ttl) do
      [{:ttl, val}] -> val
      [] -> @default_ttl
    end
  end

  def set_ttl(seconds) when is_integer(seconds) and seconds >= 0 do
    :ets.insert(@settings_table, {:ttl, seconds})
    save_setting("ttl", to_string(seconds))
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:cache_settings", {:ttl_changed, seconds})
  end

  defp save_setting(key, value) do
    alias EliHole.DNS.Setting

    case EliHole.Repo.get_by(Setting, key: key) do
      nil ->
        %Setting{}
        |> Setting.changeset(%{key: key, value: value})
        |> EliHole.Repo.insert()

      existing ->
        existing
        |> Setting.changeset(%{value: value})
        |> EliHole.Repo.update()
    end
  end

  defp load_setting(key) do
    alias EliHole.DNS.Setting

    case EliHole.Repo.get_by(Setting, key: key) do
      nil -> nil
      setting -> setting.value
    end
  end

  @presets %{
    "google" => [{{8, 8, 8, 8}, 53}, {{8, 8, 4, 4}, 53}],
    "cloudflare" => [{{1, 1, 1, 1}, 53}, {{1, 0, 0, 1}, 53}],
    "quad9" => [{{9, 9, 9, 9}, 53}, {{149, 112, 112, 112}, 53}],
    "opendns" => [{{208, 67, 222, 222}, 53}, {{208, 67, 220, 220}, 53}]
  }

  def presets, do: @presets

  def get_upstreams do
    case :ets.lookup(@settings_table, :upstreams) do
      [{:upstreams, val}] when val != [] -> val
      _ -> Application.get_env(:eli_hole, :dns_upstreams, [{{8, 8, 8, 8}, 53}])
    end
  end

  def load_upstreams_from_db do
    alias EliHole.DNS.Providers
    providers = Providers.list_enabled()

    if providers != [] do
      tuples = Providers.to_tuples(providers)
      set_upstreams(tuples)
    end
  end

  def set_upstreams(upstreams) when is_list(upstreams) do
    :ets.insert(@settings_table, {:upstreams, upstreams})

    Phoenix.PubSub.broadcast(
      EliHole.PubSub,
      "dns:cache_settings",
      {:upstreams_changed, upstreams}
    )
  end

  def set_preset(name) when is_binary(name) do
    case Map.get(@presets, name) do
      nil -> {:error, :unknown_preset}
      upstreams -> set_upstreams(upstreams)
    end
  end

  def format_upstream({ip, port}), do: "#{:inet.ntoa(ip)}:#{port}"

  def parse_upstream(str) do
    case String.split(String.trim(str), ":") do
      [ip_str, port_str] ->
        with {:ok, ip} <- :inet.parse_address(String.to_charlist(ip_str)),
             {port, _} <- Integer.parse(port_str) do
          {:ok, {ip, port}}
        else
          _ -> {:error, :invalid}
        end

      [ip_str] ->
        case :inet.parse_address(String.to_charlist(ip_str)) do
          {:ok, ip} -> {:ok, {ip, 53}}
          _ -> {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  end

  def stats do
    now = System.monotonic_time(:second)
    all = :ets.tab2list(@table)
    total = length(all)

    active =
      Enum.count(all, fn
        {_key, _resp, _upstream, exp} -> exp > now
        {_key, _resp, exp} -> exp > now
      end)

    %{total: total, active: active, expired: total - active, ttl: get_ttl()}
  end

  def flush do
    :ets.delete_all_objects(@table)
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:cache_settings", :cache_flushed)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    :ets.new(@settings_table, [:set, :named_table, :public, read_concurrency: true])
    :ets.insert(@settings_table, {:ttl, @default_ttl})
    schedule_cleanup()
    send(self(), :load_from_db)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:load_from_db, state) do
    load_upstreams_from_db()

    case load_setting("ttl") do
      nil ->
        :ok

      ttl_str ->
        case Integer.parse(ttl_str) do
          {ttl, _} -> :ets.insert(@settings_table, {:ttl, ttl})
          _ -> :ok
        end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:second)

    :ets.foldl(
      fn
        {key, _resp, _upstream, exp}, acc ->
          if exp <= now, do: :ets.delete(@table, key)
          acc

        {key, _resp, _exp}, acc ->
          :ets.delete(@table, key)
          acc
      end,
      nil,
      @table
    )

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
