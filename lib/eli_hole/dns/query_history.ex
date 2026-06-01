defmodule EliHole.DNS.QueryHistory do
  @moduledoc """
  Postgres persistence layer behind `EliHole.DNS.QueryLog`.

  `QueryLog` keeps the hot path in ETS (a capped recent ring + daily/series
  aggregate counters) for speed, and mirrors every query into the `query_logs`
  table through this module so the history survives a restart. On boot
  `QueryLog` rebuilds its ETS tables from here:

    * `recent/1` rehydrates the recent ring (newest-first entry maps);
    * `daily_counts/2` rebuilds the per-day aggregate counters;
    * `series_counts/1` rebuilds the 24h time-series buckets.

  `status`, `dnssec`, and `transport` round-trip as strings in the column and are
  converted back to the fixed atom sets on read (never `String.to_atom/1` on the
  stored value — the mappings below are closed).
  """
  import Ecto.Query

  alias EliHole.DNS.QueryLogEntry
  alias EliHole.Repo

  @doc """
  Bulk-insert buffered query entries.

  Each `entry` is the in-memory map logged by the DNS handler; only the
  persisted fields are kept. `queried_at` must already be set by the caller.
  Returns `{count, nil}` like `Repo.insert_all/3`.
  """
  def insert_many([]), do: {0, nil}

  def insert_many(entries) when is_list(entries) do
    rows = Enum.map(entries, &to_row/1)
    Repo.insert_all(QueryLogEntry, rows)
  end

  @doc "Newest-first query entries as the in-memory map shape used by the admin log."
  def recent(limit \\ 100) do
    limit
    |> recent_with_time()
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Like `recent/1`, but each element is `{queried_at, entry}`.

  `QueryLog` needs the original timestamp to rebuild its monotonic-keyed recent
  ring (and the rolling qps gauge) on rehydration.
  """
  def recent_with_time(limit \\ 100) do
    QueryLogEntry
    |> order_by([q], desc: q.queried_at, desc: q.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn row -> {row.queried_at, to_entry(row)} end)
  end

  @doc """
  Per-day aggregate counts over `[from_date, to_date]` (inclusive, UTC days).

  Returns a list of `{ets_key, count}` tuples keyed exactly like
  `EliHole.DNS.QueryLog`'s `@daily_table` (`{iso_date, kind, key}`), ready to be
  seeded straight into ETS on rehydration.
  """
  def daily_counts(%Date{} = from_date, %Date{} = to_date) do
    from_dt = day_start(from_date)
    to_dt = day_start(Date.add(to_date, 1))

    base =
      from q in QueryLogEntry,
        where: q.queried_at >= ^from_dt and q.queried_at < ^to_dt

    status =
      base
      |> group_by([q], [fragment("(?)::date", q.queried_at), q.status])
      |> select([q], {fragment("(?)::date", q.queried_at), q.status, count(q.id)})
      |> Repo.all()
      |> Enum.map(fn {d, s, n} -> {{iso(d), :status, status_atom(s)}, n} end)

    dnssec =
      base
      |> where([q], not is_nil(q.dnssec))
      |> group_by([q], [fragment("(?)::date", q.queried_at), q.dnssec])
      |> select([q], {fragment("(?)::date", q.queried_at), q.dnssec, count(q.id)})
      |> Repo.all()
      |> Enum.map(fn {d, v, n} -> {{iso(d), :dnssec, verdict_atom(v)}, n} end)

    domain =
      base
      |> where([q], not is_nil(q.domain))
      |> group_by([q], [fragment("(?)::date", q.queried_at), q.domain])
      |> select([q], {fragment("(?)::date", q.queried_at), q.domain, count(q.id)})
      |> Repo.all()
      |> Enum.map(fn {d, dom, n} -> {{iso(d), :domain, dom}, n} end)

    client =
      base
      |> where([q], not is_nil(q.client))
      |> group_by([q], [fragment("(?)::date", q.queried_at), q.client])
      |> select([q], {fragment("(?)::date", q.queried_at), q.client, count(q.id)})
      |> Repo.all()
      |> Enum.map(fn {d, c, n} -> {{iso(d), :client, c}, n} end)

    status ++ dnssec ++ domain ++ client
  end

  @doc """
  Per-status counts bucketed into `@bucket_seconds` slices since `since_unix`.

  Returns `{{bucket_start_unix, status_atom}, count}` tuples keyed like
  `EliHole.DNS.QueryLog`'s `@series_table`, ready to seed into ETS.
  """
  def series_counts(since_unix) when is_integer(since_unix) do
    since_dt = DateTime.from_unix!(since_unix)

    # Bucket width must stay in sync with QueryLog's @bucket_seconds (600). It's
    # inlined as a literal because fragment/2 forbids an interpolated first arg.
    from(q in QueryLogEntry, where: q.queried_at >= ^since_dt)
    |> group_by(
      [q],
      [fragment("(floor(extract(epoch from ?) / 600) * 600)::bigint", q.queried_at), q.status]
    )
    |> select(
      [q],
      {fragment("(floor(extract(epoch from ?) / 600) * 600)::bigint", q.queried_at), q.status,
       count(q.id)}
    )
    |> Repo.all()
    |> Enum.map(fn {b, s, n} -> {{b, status_atom(s)}, n} end)
  end

  @doc "Delete rows older than `before` (a `DateTime`). Returns the deleted count."
  def prune(%DateTime{} = before) do
    {count, _} =
      from(q in QueryLogEntry, where: q.queried_at < ^before)
      |> Repo.delete_all()

    count
  end

  @doc "Remove all persisted history."
  def clear do
    {count, _} = Repo.delete_all(QueryLogEntry)
    count
  end

  defp to_row(entry) do
    %{
      domain: Map.get(entry, :domain),
      type: to_string_or_nil(Map.get(entry, :type)),
      client: Map.get(entry, :client),
      upstream: Map.get(entry, :upstream),
      status: to_string_or_nil(Map.get(entry, :status)),
      dnssec: to_string_or_nil(Map.get(entry, :dnssec)),
      transport: to_string_or_nil(Map.get(entry, :transport)),
      duration_ms: Map.get(entry, :duration_ms, 0),
      queried_at: ensure_usec(Map.fetch!(entry, :queried_at))
    }
  end

  # The column is microsecond-precision; force the precision so second-precision
  # timestamps (e.g. truncated or literal) don't fail the Ecto dump.
  defp ensure_usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp ensure_usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp to_entry(%QueryLogEntry{} = row) do
    %{
      id: row.id,
      time: Calendar.strftime(row.queried_at, "%H:%M:%S"),
      client: row.client,
      domain: row.domain,
      type: row.type,
      upstream: row.upstream,
      duration_ms: row.duration_ms,
      status: status_atom(row.status),
      dnssec: verdict_atom(row.dnssec),
      transport: transport_atom(row.transport)
    }
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)

  defp day_start(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")

  defp iso(%Date{} = d), do: Date.to_iso8601(d)

  defp status_atom("ok"), do: :ok
  defp status_atom("blocked"), do: :blocked
  defp status_atom("error"), do: :error
  defp status_atom("rate_limited"), do: :rate_limited
  defp status_atom(_), do: :error

  defp verdict_atom("secure"), do: :secure
  defp verdict_atom("insecure"), do: :insecure
  defp verdict_atom("bogus"), do: :bogus
  defp verdict_atom(_), do: nil

  defp transport_atom("udp"), do: :udp
  defp transport_atom("dot"), do: :dot
  defp transport_atom("doh"), do: :doh
  defp transport_atom(_), do: nil
end
