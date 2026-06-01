defmodule EliHole.DNS.QueryLogTest do
  use ExUnit.Case

  alias EliHole.DNS.QueryLog

  setup do
    # Clear the log before each test to get a clean slate
    QueryLog.clear()
    # Sync to ensure clear has been processed (cast)
    _ = :sys.get_state(QueryLog)
    :ok
  end

  describe "dnssec_breakdown/0" do
    test "counts secure/insecure/bogus verdicts and ignores entries without a verdict" do
      for {d, v} <- [{"a", :secure}, {"b", :secure}, {"c", :insecure}, {"d", :bogus}] do
        QueryLog.log(%{domain: d, type: "A", status: :ok, upstream: "x", dnssec: v})
      end

      # an entry with no dnssec key must not be counted
      QueryLog.log(%{domain: "blocked", type: "A", status: :blocked, upstream: nil})
      _ = :sys.get_state(QueryLog)

      assert QueryLog.dnssec_breakdown() == %{secure: 2, insecure: 1, bogus: 1}
    end
  end

  describe "log/1 and recent/1" do
    test "logged entry appears in recent results" do
      entry = %{domain: "example.com", type: "A", status: :ok, upstream: "8.8.8.8:53"}
      QueryLog.log(entry)
      _ = :sys.get_state(QueryLog)

      recent = QueryLog.recent()
      assert length(recent) == 1
      assert hd(recent).domain == "example.com"
    end

    test "multiple entries appear in recent" do
      for i <- 1..5 do
        QueryLog.log(%{domain: "test#{i}.com", type: "A", status: :ok, upstream: "8.8.8.8:53"})
      end

      _ = :sys.get_state(QueryLog)

      recent = QueryLog.recent()
      assert length(recent) == 5
    end

    test "recent respects limit parameter" do
      for i <- 1..10 do
        QueryLog.log(%{domain: "test#{i}.com", type: "A", status: :ok, upstream: "8.8.8.8:53"})
      end

      _ = :sys.get_state(QueryLog)

      assert length(QueryLog.recent(3)) == 3
    end

    test "recent returns newest entries first" do
      QueryLog.log(%{domain: "first.com", type: "A", status: :ok, upstream: "8.8.8.8:53"})
      _ = :sys.get_state(QueryLog)

      QueryLog.log(%{domain: "second.com", type: "A", status: :ok, upstream: "8.8.8.8:53"})
      _ = :sys.get_state(QueryLog)

      QueryLog.log(%{domain: "third.com", type: "A", status: :ok, upstream: "8.8.8.8:53"})
      _ = :sys.get_state(QueryLog)

      recent = QueryLog.recent()
      domains = Enum.map(recent, & &1.domain)
      assert domains == ["third.com", "second.com", "first.com"]
    end
  end

  describe "stats/0" do
    test "returns zero stats when empty" do
      stats = QueryLog.stats()
      assert stats.total == 0
      assert stats.resolved == 0
      assert stats.blocked == 0
      assert stats.failed == 0
    end

    test "counts resolved, blocked, and failed correctly" do
      QueryLog.log(%{domain: "ok1.com", type: "A", status: :ok, upstream: "8.8.8.8:53"})
      QueryLog.log(%{domain: "ok2.com", type: "A", status: :ok, upstream: "8.8.8.8:53"})
      QueryLog.log(%{domain: "blocked.com", type: "A", status: :blocked, upstream: nil})
      QueryLog.log(%{domain: "fail.com", type: "A", status: :error, upstream: nil})
      _ = :sys.get_state(QueryLog)

      stats = QueryLog.stats()
      assert stats.total == 4
      assert stats.resolved == 2
      assert stats.blocked == 1
      assert stats.failed == 1
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      QueryLog.log(%{domain: "clear-me.com", type: "A", status: :ok, upstream: "8.8.8.8:53"})
      _ = :sys.get_state(QueryLog)
      assert length(QueryLog.recent()) > 0

      QueryLog.clear()
      _ = :sys.get_state(QueryLog)

      assert QueryLog.recent() == []
      assert QueryLog.stats().total == 0
    end
  end

  describe "top_domains/1 and top_clients/1" do
    test "rank by frequency, descending, respecting the limit" do
      log_n = fn domain, client, n ->
        for _ <- 1..n,
            do:
              QueryLog.log(%{
                domain: domain,
                client: client,
                type: "A",
                status: :ok,
                upstream: "x"
              })
      end

      log_n.("popular.com", "10.0.0.1", 5)
      log_n.("medium.com", "10.0.0.2", 3)
      log_n.("rare.com", "10.0.0.3", 1)
      _ = :sys.get_state(QueryLog)

      assert QueryLog.top_domains() == [
               %{domain: "popular.com", count: 5},
               %{domain: "medium.com", count: 3},
               %{domain: "rare.com", count: 1}
             ]

      assert QueryLog.top_clients(2) == [
               %{client: "10.0.0.1", count: 5},
               %{client: "10.0.0.2", count: 3}
             ]
    end
  end

  describe "long-term aggregates over a Date.Range" do
    # Daily counters key on `{iso_date, kind, key}`; seed past days directly so
    # we exercise the multi-day range summing without time-travelling the clock.
    defp seed_day(date, kind, key, count) do
      ds = Date.to_iso8601(date)
      :ets.insert(:dns_daily_stats, {{ds, kind, key}, count})
    end

    test "stats/1 sums status counts across every day in the range" do
      today = Date.utc_today()
      seed_day(Date.add(today, -2), :status, :ok, 10)
      seed_day(Date.add(today, -1), :status, :ok, 5)
      seed_day(today, :status, :ok, 2)
      seed_day(Date.add(today, -1), :status, :blocked, 4)
      # Outside the 3-day window — must not be counted.
      seed_day(Date.add(today, -9), :status, :ok, 999)

      range = Date.range(Date.add(today, -2), today)
      stats = QueryLog.stats(range)

      assert stats.resolved == 17
      assert stats.blocked == 4
      assert stats.total == 21
    end

    test "top_domains/2 folds per-domain counts across days, then ranks" do
      today = Date.utc_today()
      seed_day(Date.add(today, -1), :domain, "a.com", 3)
      seed_day(today, :domain, "a.com", 4)
      seed_day(today, :domain, "b.com", 5)
      # Outside the window — its count must not leak into the ranking.
      seed_day(Date.add(today, -9), :domain, "a.com", 999)

      range = Date.range(Date.add(today, -1), today)

      assert QueryLog.top_domains(10, range) == [
               %{domain: "a.com", count: 7},
               %{domain: "b.com", count: 5}
             ]
    end

    test "dnssec_breakdown/1 sums verdicts across the range" do
      today = Date.utc_today()
      seed_day(Date.add(today, -1), :dnssec, :secure, 2)
      seed_day(today, :dnssec, :secure, 3)
      seed_day(today, :dnssec, :bogus, 1)
      # Outside the window — must not be summed in.
      seed_day(Date.add(today, -9), :dnssec, :secure, 999)

      range = Date.range(Date.add(today, -1), today)
      assert QueryLog.dnssec_breakdown(range) == %{secure: 5, insecure: 0, bogus: 1}
    end

    test "a descending range is normalized and still sums the window" do
      today = Date.utc_today()
      seed_day(Date.add(today, -1), :status, :ok, 4)
      seed_day(today, :status, :ok, 6)

      # first > last (step -1) must not silently match nothing.
      descending = Date.range(today, Date.add(today, -1), -1)
      assert QueryLog.stats(descending).resolved == 10
    end

    test "a single Date still resolves to that day only" do
      today = Date.utc_today()
      seed_day(today, :status, :ok, 7)
      seed_day(Date.add(today, -1), :status, :ok, 99)

      assert QueryLog.stats(today).resolved == 7
    end
  end

  describe "daily_series/1" do
    test "returns one zero-filled row per day, oldest first" do
      today = Date.utc_today()
      range = Date.range(Date.add(today, -6), today)

      series = QueryLog.daily_series(range)

      assert length(series) == 7
      assert Enum.all?(series, &(&1.total == 0))
      assert List.first(series).date == Date.add(today, -6)
      assert List.last(series).date == today
    end

    test "reflects per-day totals split by status" do
      today = Date.utc_today()
      ds = Date.to_iso8601(today)
      :ets.insert(:dns_daily_stats, {{ds, :status, :ok}, 6})
      :ets.insert(:dns_daily_stats, {{ds, :status, :blocked}, 2})

      series = QueryLog.daily_series(Date.range(Date.add(today, -1), today))
      latest = List.last(series)

      assert latest.date == today
      assert latest.ok == 6
      assert latest.blocked == 2
      assert latest.total == 8
      # The seeded prior day had no traffic.
      assert List.first(series).total == 0
    end
  end

  describe "series/0" do
    test "returns a full 24h window of zero buckets when empty" do
      series = QueryLog.series()

      assert length(series) == 144
      assert Enum.all?(series, &(&1.total == 0))
      # Oldest bucket first, newest last.
      assert List.first(series).ts < List.last(series).ts
    end

    test "buckets the current statuses into the latest slot" do
      QueryLog.log(%{domain: "a.com", type: "A", status: :ok, upstream: "x"})
      QueryLog.log(%{domain: "b.com", type: "A", status: :ok, upstream: "x"})
      QueryLog.log(%{domain: "c.com", type: "A", status: :blocked, upstream: nil})
      QueryLog.log(%{domain: "d.com", type: "A", status: :error, upstream: nil})
      _ = :sys.get_state(QueryLog)

      current = List.last(QueryLog.series())
      assert current.ok == 2
      assert current.blocked == 1
      assert current.error == 1
      assert current.rate_limited == 0
      assert current.total == 4
    end

    test "clear resets the series" do
      QueryLog.log(%{domain: "x.com", type: "A", status: :ok, upstream: "x"})
      _ = :sys.get_state(QueryLog)
      assert List.last(QueryLog.series()).total == 1

      QueryLog.clear()
      _ = :sys.get_state(QueryLog)
      assert Enum.all?(QueryLog.series(), &(&1.total == 0))
    end

    test "buckets older than the 24h window are excluded from series and reaped by prune" do
      # Seed a bucket well outside the rolling window (~48h ago), aligned to a
      # 10-minute boundary, directly in the series ETS table.
      bucket_seconds = 600
      old_ts = div(System.system_time(:second) - 48 * 3600, bucket_seconds) * bucket_seconds
      key = {old_ts, :ok}
      :ets.insert(:dns_query_series, {key, 7})

      # series/0 reads only the in-window buckets, so the stale one never shows.
      series = QueryLog.series()
      assert length(series) == 144
      assert Enum.all?(series, &(&1.ts > old_ts))
      assert Enum.all?(series, &(&1.total == 0))

      # The prune sweep physically removes it from the table.
      send(QueryLog, :prune_days)
      _ = :sys.get_state(QueryLog)
      assert :ets.lookup(:dns_query_series, key) == []
    end
  end

  describe "recent ring pruning" do
    test "caps the live ring while daily aggregates keep the full count" do
      total = 1_050

      for i <- 1..total do
        QueryLog.log(%{domain: "prune#{i}.com", type: "A", status: :ok, upstream: "8.8.8.8:53"})
      end

      _ = :sys.get_state(QueryLog)

      # The live ring is capped (@max_recent = 1_000) regardless of how many ask.
      assert length(QueryLog.recent(10_000)) == 1_000
      # Daily aggregates are uncapped — every query is counted.
      assert QueryLog.stats().total == total
    end
  end
end
