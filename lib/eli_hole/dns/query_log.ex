defmodule EliHole.DNS.QueryLog do
  @moduledoc """
  Query logging split into two stores, each sized for what reads it:

    * `@recent_table` — a small `:ordered_set` ring (capped at `@max_recent`)
      holding the **full** entry maps. Feeds the real-time admin log
      (`recent/1`) and the rolling queries-per-second gauge (`recent_rate/0`).
      Never the source of long-term stats.

    * `@daily_table` — per-day aggregate counters keyed by
      `{iso_date, kind, key}` (`kind ∈ :status | :dnssec | :domain | :client`),
      bumped atomically with `:ets.update_counter/4`. This is what backs
      `stats/1`, `status_breakdown/1`, `dnssec_breakdown/1`, `top_domains/2`,
      and `top_clients/2`. Counts accumulate per UTC day (no 10k cap), so
      totals survive the recent-ring churn and give true daily figures.

  ISO-8601 date strings sort lexicographically == chronologically, so old days
  are reaped with a single `select_delete` range scan (`@retention_days`).
  """

  use GenServer

  @recent_table :dns_query_log
  @daily_table :dns_daily_stats
  @max_recent 1_000
  @retention_days 30
  @prune_interval :timer.hours(6)

  @statuses [:ok, :blocked, :error, :rate_limited]
  @verdicts [:secure, :insecure, :bogus]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def log(entry) do
    GenServer.cast(__MODULE__, {:log, entry})
  end

  @doc """
  Subscribe the calling process to live query events.

  Each logged query is broadcast as `{:new_query, entry}` on the `dns:queries`
  PubSub topic — the admin LiveView and tests consume it for real-time updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:queries")
  end

  @doc "Most recent full query entries (from the capped live ring), newest first."
  def recent(limit \\ 100) do
    @recent_table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {ts, _} -> ts end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_ts, entry} -> entry end)
  end

  @doc "Aggregate query totals for a UTC day (default: today)."
  def stats(date \\ Date.utc_today()) do
    counts = status_counts(date)

    %{
      total: counts.ok + counts.blocked + counts.error + counts.rate_limited,
      resolved: counts.ok,
      blocked: counts.blocked,
      failed: counts.error,
      rate_limited: counts.rate_limited
    }
  end

  @doc "Per-status counts for a UTC day (default: today)."
  def status_breakdown(date \\ Date.utc_today()), do: status_counts(date)

  @doc "Counts of DNSSEC validation verdicts for a UTC day (entries without a verdict ignored)."
  def dnssec_breakdown(date \\ Date.utc_today()) do
    ds = Date.to_iso8601(date)
    Map.new(@verdicts, fn v -> {v, counter(ds, :dnssec, v)} end)
  end

  @doc "Most-queried domains for a UTC day, descending."
  def top_domains(limit \\ 10, date \\ Date.utc_today()) do
    top(:domain, date, limit)
  end

  @doc "Busiest clients for a UTC day, descending."
  def top_clients(limit \\ 10, date \\ Date.utc_today()) do
    top(:client, date, limit)
  end

  @doc """
  Average queries per second over the last 60s, counted from the live ring.

  Because the ring is capped at `@max_recent`, the 60s window can hold at most
  `@max_recent` entries, so the gauge saturates near `@max_recent / 60` qps
  under sustained load — fine for a home sinkhole, not a high-throughput meter.
  """
  def recent_rate do
    now = System.monotonic_time(:second)
    cutoff = now - 60

    @recent_table
    |> :ets.tab2list()
    |> Enum.count(fn {ts, _entry} ->
      System.convert_time_unit(ts, :native, :second) > cutoff
    end)
    |> then(&Float.round(&1 / 60, 1))
  end

  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  defp status_counts(date) do
    ds = Date.to_iso8601(date)
    Map.new(@statuses, fn s -> {s, counter(ds, :status, s)} end)
  end

  defp counter(ds, kind, key) do
    case :ets.lookup(@daily_table, {ds, kind, key}) do
      [{_key, n}] -> n
      [] -> 0
    end
  end

  defp top(kind, date, limit) do
    ds = Date.to_iso8601(date)
    field = if kind == :domain, do: :domain, else: :client

    @daily_table
    |> :ets.select([{{{ds, kind, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort_by(fn {_key, count} -> count end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {key, count} -> %{field => key, :count => count} end)
  end

  @impl true
  def init(_) do
    :ets.new(@recent_table, [:ordered_set, :named_table, :public, read_concurrency: true])

    :ets.new(@daily_table, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_prune()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:log, entry}, state) do
    ts = System.monotonic_time()
    :ets.insert(@recent_table, {ts, entry})
    aggregate(entry)
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:queries", {:new_query, entry})
    prune_recent()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear, state) do
    :ets.delete_all_objects(@recent_table)
    :ets.delete_all_objects(@daily_table)
    {:noreply, state}
  end

  @impl true
  def handle_info(:prune_days, state) do
    prune_days()
    schedule_prune()
    {:noreply, state}
  end

  defp aggregate(entry) do
    ds = Date.to_iso8601(Date.utc_today())

    bump({ds, :status, entry.status})

    case Map.get(entry, :dnssec) do
      nil -> :ok
      verdict -> bump({ds, :dnssec, verdict})
    end

    if domain = Map.get(entry, :domain), do: bump({ds, :domain, domain})
    if client = Map.get(entry, :client), do: bump({ds, :client, client})
  end

  defp bump(key), do: :ets.update_counter(@daily_table, key, {2, 1}, {key, 0})

  defp prune_recent do
    size = :ets.info(@recent_table, :size)

    if size > @max_recent do
      to_delete = size - @max_recent

      @recent_table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {ts, _} -> ts end, :asc)
      |> Enum.take(to_delete)
      |> Enum.each(fn {ts, _} -> :ets.delete(@recent_table, ts) end)
    end
  end

  # ISO date strings compare lexicographically == chronologically, so a single
  # range match-spec drops every aggregate older than the retention window.
  defp prune_days do
    cutoff = Date.utc_today() |> Date.add(-@retention_days) |> Date.to_iso8601()
    :ets.select_delete(@daily_table, [{{{:"$1", :_, :_}, :_}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp schedule_prune, do: Process.send_after(self(), :prune_days, @prune_interval)
end
