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
      totals survive the recent-ring churn and give true daily figures. Every
      stat function takes a `Date` *or* a `Date.Range`; a range sums the daily
      counters across the window, which is how the weekly/monthly long-term
      views are built (plus `daily_series/1` for the per-day trend chart).

    * `@series_table` — per-status counters bucketed into fixed time slices
      (`@bucket_seconds`), keyed by `{bucket_start_unix, status}` and bumped
      atomically. Backs `series/0`, the dashboard "queries over time" chart.
      Holds a rolling 24h window (`@series_buckets`); old buckets are reaped
      alongside the daily aggregates.

  ISO-8601 date strings sort lexicographically == chronologically, so old days
  are reaped with a single `select_delete` range scan (`@retention_days`).
  """

  use GenServer

  require Logger

  alias EliHole.DNS.QueryHistory

  @recent_table :dns_query_log
  @daily_table :dns_daily_stats
  @series_table :dns_query_series
  @max_recent 1_000
  @retention_days 30
  @prune_interval :timer.hours(6)

  # Buffer persisted-row writes and flush them in batches so the DB round-trip
  # never sits on the per-query logging path: flush once the buffer fills or the
  # timer fires, whichever comes first. A graceful shutdown flushes via
  # terminate/2; a hard crash (kill -9, OOM, power loss) drops at most one
  # unflushed buffer — up to @flush_interval of history. Acceptable for a
  # home sinkhole query log.
  @flush_interval :timer.seconds(5)
  @flush_threshold 50

  # 10-minute buckets over a rolling 24h window (144 buckets) for the chart.
  @bucket_seconds 600
  @series_buckets 144

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

  @doc """
  Aggregate query totals over a period (default: today).

  Accepts a single `Date` or a `Date.Range` — passing a range (e.g.
  `Date.range(Date.add(today, -6), today)`) sums the per-day counters across
  the whole window, which is how weekly/monthly long-term stats are built.
  """
  def stats(period \\ Date.utc_today()) do
    counts = status_counts(period)

    %{
      total: counts.ok + counts.blocked + counts.error + counts.rate_limited,
      resolved: counts.ok,
      blocked: counts.blocked,
      failed: counts.error,
      rate_limited: counts.rate_limited
    }
  end

  @doc "Per-status counts over a period (`Date` or `Date.Range`, default: today)."
  def status_breakdown(period \\ Date.utc_today()), do: status_counts(period)

  @doc "Counts of DNSSEC validation verdicts over a period (entries without a verdict ignored)."
  def dnssec_breakdown(period \\ Date.utc_today()) do
    Map.new(@verdicts, fn v -> {v, sum_kind(:dnssec, v, period)} end)
  end

  @doc "Most-queried domains over a period, descending."
  def top_domains(limit \\ 10, period \\ Date.utc_today()) do
    top(:domain, period, limit)
  end

  @doc "Busiest clients over a period, descending."
  def top_clients(limit \\ 10, period \\ Date.utc_today()) do
    top(:client, period, limit)
  end

  @doc """
  Per-UTC-day query totals over a date range, oldest day first.

  Each entry is `%{date, ok, blocked, error, rate_limited, total}`. Backs the
  dashboard long-term "daily totals" trend chart for the 7-day / 30-day views.
  Days with no traffic are included as zero rows so the x-axis stays stable.
  """
  def daily_series(%Date.Range{} = range) do
    for date <- range do
      counts = status_counts(date)

      %{
        date: date,
        ok: counts.ok,
        blocked: counts.blocked,
        error: counts.error,
        rate_limited: counts.rate_limited,
        total: counts.ok + counts.blocked + counts.error + counts.rate_limited
      }
    end
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

  @doc """
  Per-status query counts bucketed over the last 24h, oldest bucket first.

  Returns exactly `@series_buckets` entries (empty buckets filled with zeros)
  so the chart has a stable x-axis. Each entry is
  `%{ts, ok, blocked, error, rate_limited, total}` where `ts` is the bucket's
  start as a unix second.
  """
  def series do
    current = bucket_start(System.system_time(:second))
    oldest = current - (@series_buckets - 1) * @bucket_seconds

    by_bucket =
      @series_table
      |> :ets.select([
        {{{:"$1", :"$2"}, :"$3"}, [{:>=, :"$1", oldest}], [{{:"$1", :"$2", :"$3"}}]}
      ])
      |> Enum.reduce(%{}, fn {bucket, status, n}, acc ->
        Map.update(acc, bucket, %{status => n}, &Map.put(&1, status, n))
      end)

    for bucket <- oldest..current//@bucket_seconds do
      counts = Map.get(by_bucket, bucket, %{})
      ok = Map.get(counts, :ok, 0)
      blocked = Map.get(counts, :blocked, 0)
      error = Map.get(counts, :error, 0)
      rate_limited = Map.get(counts, :rate_limited, 0)

      %{
        ts: bucket,
        ok: ok,
        blocked: blocked,
        error: error,
        rate_limited: rate_limited,
        total: ok + blocked + error + rate_limited
      }
    end
  end

  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  defp status_counts(period) do
    Map.new(@statuses, fn s -> {s, sum_kind(:status, s, period)} end)
  end

  # Sum the daily counter for one `{kind, key}` across every day in the period.
  # ISO date strings compare lexicographically == chronologically, so a single
  # bounded range match-spec covers a one-day or a multi-day window alike.
  defp sum_kind(kind, key, period) do
    {from_ds, to_ds} = iso_bounds(period)

    @daily_table
    |> :ets.select([
      {{{:"$1", kind, key}, :"$2"}, [{:>=, :"$1", from_ds}, {:"=<", :"$1", to_ds}], [:"$2"]}
    ])
    |> Enum.sum()
  end

  # Top domains/clients over the period: pull every matching day, fold counts
  # per key (a busy domain spans many days), then rank.
  defp top(kind, period, limit) do
    {from_ds, to_ds} = iso_bounds(period)
    field = if kind == :domain, do: :domain, else: :client

    @daily_table
    |> :ets.select([
      {{{:"$1", kind, :"$2"}, :"$3"}, [{:>=, :"$1", from_ds}, {:"=<", :"$1", to_ds}],
       [{{:"$2", :"$3"}}]}
    ])
    |> Enum.reduce(%{}, fn {key, count}, acc -> Map.update(acc, key, count, &(&1 + count)) end)
    |> Enum.sort_by(fn {_key, count} -> count end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {key, count} -> %{field => key, :count => count} end)
  end

  # Normalize to {earlier_iso, later_iso} so a descending range (first > last)
  # can't make every guard (>= from AND <= to) match nothing.
  defp iso_bounds(%Date.Range{first: from, last: to}) do
    a = Date.to_iso8601(from)
    b = Date.to_iso8601(to)
    if a <= b, do: {a, b}, else: {b, a}
  end

  defp iso_bounds(%Date{} = date) do
    ds = Date.to_iso8601(date)
    {ds, ds}
  end

  @doc false
  # Whether to mirror entries to Postgres. Off in test, where the app-wide
  # GenServer boots before any sandbox connection is checked out.
  def persist? do
    :eli_hole
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:persist, true)
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

    :ets.new(@series_table, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    persist? = persist?()

    if persist? do
      # Trap exits so terminate/2 runs on graceful shutdown and flushes the
      # pending write buffer instead of dropping it.
      Process.flag(:trap_exit, true)
      rehydrate()
    end

    schedule_prune()
    if persist?, do: schedule_flush()

    {:ok, %{buffer: [], persist?: persist?}}
  end

  @impl true
  def handle_cast({:log, entry}, state) do
    ts = System.monotonic_time()
    :ets.insert(@recent_table, {ts, entry})
    aggregate(entry)
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:queries", {:new_query, entry})
    prune_recent()
    {:noreply, buffer(state, entry)}
  end

  @impl true
  def handle_cast(:clear, state) do
    :ets.delete_all_objects(@recent_table)
    :ets.delete_all_objects(@daily_table)
    :ets.delete_all_objects(@series_table)
    if state.persist?, do: safe(fn -> QueryHistory.clear() end)
    {:noreply, %{state | buffer: []}}
  end

  @impl true
  def handle_info(:flush, state) do
    schedule_flush()
    {:noreply, flush(state)}
  end

  @impl true
  def handle_info(:prune_days, state) do
    prune_days()
    prune_series()
    if state.persist?, do: safe(fn -> QueryHistory.prune(db_cutoff()) end)
    schedule_prune()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    flush(state)
    :ok
  end

  # Append the persisted row to the write buffer, flushing once it's full. The
  # captured `queried_at` is the durable timestamp (the in-memory `:time` field
  # is only an HH:MM:SS display string).
  defp buffer(%{persist?: false} = state, _entry), do: state

  defp buffer(%{buffer: buf} = state, entry) do
    row = Map.put(entry, :queried_at, DateTime.utc_now())
    state = %{state | buffer: [row | buf]}
    if length(state.buffer) >= @flush_threshold, do: flush(state), else: state
  end

  defp flush(%{buffer: []} = state), do: state

  defp flush(%{buffer: buf} = state) do
    # insert_all wants oldest-first for stable ids; the buffer is newest-first.
    safe(fn -> QueryHistory.insert_many(Enum.reverse(buf)) end)
    %{state | buffer: []}
  end

  # Rebuild the ETS tables from persisted history so a restart keeps the recent
  # log, the daily aggregates, and the 24h series chart.
  defp rehydrate do
    rehydrate_recent()
    rehydrate_daily()
    rehydrate_series()
  rescue
    e -> Logger.warning("QueryLog rehydrate failed: #{Exception.message(e)}")
  end

  defp rehydrate_recent do
    mono = System.monotonic_time()
    wall = System.system_time(:native)

    @max_recent
    |> QueryHistory.recent_with_time()
    |> Enum.with_index()
    |> Enum.each(fn {{queried_at, entry}, i} ->
      # Map the wall-clock timestamp into the monotonic frame the ring keys on,
      # so ordering and the 60s qps gauge stay correct; `- i` keeps keys unique.
      qn = DateTime.to_unix(queried_at, :native)
      :ets.insert(@recent_table, {mono - (wall - qn) - i, entry})
    end)
  end

  defp rehydrate_daily do
    today = Date.utc_today()
    from_date = Date.add(today, -@retention_days)

    from_date
    |> QueryHistory.daily_counts(today)
    |> Enum.each(fn {key, count} -> :ets.insert(@daily_table, {key, count}) end)
  end

  defp rehydrate_series do
    since = bucket_start(System.system_time(:second)) - (@series_buckets - 1) * @bucket_seconds

    since
    |> QueryHistory.series_counts()
    |> Enum.each(fn {key, count} -> :ets.insert(@series_table, {key, count}) end)
  end

  defp db_cutoff do
    DateTime.utc_now() |> DateTime.add(-@retention_days, :day)
  end

  # DB writes are best-effort: a logging failure must never take DNS down.
  defp safe(fun) do
    fun.()
  rescue
    e -> Logger.warning("QueryLog persistence error: #{Exception.message(e)}")
  end

  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)

  defp aggregate(entry) do
    ds = Date.to_iso8601(Date.utc_today())

    bump({ds, :status, entry.status})

    case Map.get(entry, :dnssec) do
      nil -> :ok
      verdict -> bump({ds, :dnssec, verdict})
    end

    if domain = Map.get(entry, :domain), do: bump({ds, :domain, domain})
    if client = Map.get(entry, :client), do: bump({ds, :client, client})

    bucket_key = {bucket_start(System.system_time(:second)), entry.status}
    :ets.update_counter(@series_table, bucket_key, {2, 1}, {bucket_key, 0})
  end

  defp bump(key), do: :ets.update_counter(@daily_table, key, {2, 1}, {key, 0})

  defp bucket_start(unix), do: div(unix, @bucket_seconds) * @bucket_seconds

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

  # Drop time-series buckets older than the rolling 24h chart window.
  defp prune_series do
    cutoff = bucket_start(System.system_time(:second)) - (@series_buckets - 1) * @bucket_seconds
    :ets.select_delete(@series_table, [{{{:"$1", :_}, :_}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp schedule_prune, do: Process.send_after(self(), :prune_days, @prune_interval)
end
