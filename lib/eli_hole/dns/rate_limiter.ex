defmodule EliHole.DNS.RateLimiter do
  @moduledoc """
  Per-client DNS query throttling.

  Each client (keyed by source IP) is allowed at most `limit/0` queries per
  one-second window; excess queries are refused (REFUSED rcode) before any
  upstream resolution happens. Counts live in a public ETS table mutated with
  the atomic `:ets.update_counter/4`, so the per-packet `allow?/1` check stays
  lock-free under the UDP server's task-per-query concurrency — no GenServer
  call sits on the hot path.

  Disabled by default so existing deployments behave identically; when off,
  `allow?/1` returns `true` without touching the counter table. The config
  (enabled flag + per-second limit) is ETS-cached and persisted to
  `dns_settings`, mirroring `Cache` and `DNSSEC.Config`.
  """

  use GenServer

  alias EliHole.DNS.Setting
  alias EliHole.Repo

  @table :dns_rate_limit
  @settings_table :dns_rate_limit_settings
  @cleanup_interval :timer.seconds(5)
  @default_limit 100
  @enabled_key "rate_limit_enabled"
  @limit_key "rate_limit_per_sec"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Whether `client_key` may issue another query in the current one-second window.

  Returns `true` immediately when throttling is disabled (the counter table is
  never touched). Otherwise atomically bumps the client's per-second counter and
  allows the query while the count is at or below `limit/0`. A non-binary key
  (unknown peer) is always allowed — we can't throttle what we can't identify.
  """
  def allow?(client_key) when is_binary(client_key) do
    if enabled?() do
      key = {client_key, System.monotonic_time(:second)}
      count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
      count <= limit()
    else
      true
    end
  rescue
    ArgumentError -> true
  end

  def allow?(_other), do: true

  @doc "Whether throttling is active. Default false."
  def enabled? do
    case :ets.lookup(@settings_table, :enabled) do
      [{:enabled, value}] -> value
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Per-client queries-per-second ceiling. Default #{@default_limit}."
  def limit do
    case :ets.lookup(@settings_table, :limit) do
      [{:limit, value}] -> value
      _ -> @default_limit
    end
  rescue
    ArgumentError -> @default_limit
  end

  @doc "Current config as a map, for the admin UI."
  def config, do: %{enabled: enabled?(), limit: limit()}

  @doc "Enable/disable throttling; persists and broadcasts the change."
  def set_enabled(value) when is_boolean(value) do
    :ets.insert(@settings_table, {:enabled, value})
    persist(@enabled_key, to_string(value))
    broadcast()
    :ok
  end

  @doc "Set the per-client per-second ceiling; persists and broadcasts."
  def set_limit(n) when is_integer(n) and n > 0 do
    :ets.insert(@settings_table, {:limit, n})
    persist(@limit_key, to_string(n))
    broadcast()
    :ok
  end

  defp broadcast do
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:rate_limit", {:rate_limit_changed, config()})
  end

  defp persist(key, value) do
    case Repo.get_by(Setting, key: key) do
      nil -> %Setting{} |> Setting.changeset(%{key: key, value: value}) |> Repo.insert()
      existing -> existing |> Setting.changeset(%{value: value}) |> Repo.update()
    end
  end

  defp load(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> nil
      setting -> setting.value
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :named_table, :public, write_concurrency: true])
    :ets.new(@settings_table, [:set, :named_table, :public, read_concurrency: true])
    # Load persisted config synchronously: this is an abuse control, so it must be
    # in effect from the first query, not after an async catch-up. Repo starts
    # before this process in the supervision tree, so the read is safe.
    :ets.insert(@settings_table, {:enabled, load(@enabled_key) == "true"})
    :ets.insert(@settings_table, {:limit, load_limit()})
    schedule_cleanup()
    {:ok, %{}}
  end

  defp load_limit do
    with str when is_binary(str) <- load(@limit_key),
         {n, _} when n > 0 <- Integer.parse(str) do
      n
    else
      _ -> @default_limit
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Counters are per second; anything older than the current/previous window is
    # dead weight — drop it so the table tracks only active clients.
    cutoff = System.monotonic_time(:second) - 2
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval)
end
