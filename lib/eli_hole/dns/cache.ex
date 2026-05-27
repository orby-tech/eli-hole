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
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:cache_settings", {:ttl_changed, seconds})
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
    {:ok, %{}}
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
