defmodule EliHole.DNS.QueryHistoryTest do
  use EliHole.DataCase, async: true

  alias EliHole.DNS.QueryHistory

  defp entry(attrs) do
    Map.merge(
      %{
        domain: "example.com",
        type: "A",
        client: "10.0.0.1",
        upstream: "8.8.8.8:53",
        status: :ok,
        dnssec: nil,
        transport: :udp,
        duration_ms: 3,
        queried_at: DateTime.utc_now()
      },
      Map.new(attrs)
    )
  end

  describe "insert_many/1 and recent/1" do
    test "round-trips entries, newest first, restoring atoms" do
      base = ~U[2026-06-01 10:00:00.000000Z]

      QueryHistory.insert_many([
        entry(domain: "first.com", status: :ok, queried_at: base),
        entry(domain: "second.com", status: :blocked, queried_at: DateTime.add(base, 1)),
        entry(
          domain: "third.com",
          status: :ok,
          dnssec: :secure,
          transport: :doh,
          queried_at: DateTime.add(base, 2)
        )
      ])

      recent = QueryHistory.recent()
      assert Enum.map(recent, & &1.domain) == ["third.com", "second.com", "first.com"]

      newest = hd(recent)
      assert newest.status == :ok
      assert newest.dnssec == :secure
      assert newest.transport == :doh
      # queried_at 10:00:02 UTC → HH:MM:SS display string
      assert newest.time == "10:00:02"
      assert is_integer(newest.id)
    end

    test "respects the limit" do
      for i <- 1..5 do
        QueryHistory.insert_many([
          entry(domain: "d#{i}.com", queried_at: DateTime.add(~U[2026-06-01 00:00:00Z], i))
        ])
      end

      assert length(QueryHistory.recent(2)) == 2
    end

    test "empty insert is a no-op" do
      assert QueryHistory.insert_many([]) == {0, nil}
      assert QueryHistory.recent() == []
    end
  end

  describe "daily_counts/2" do
    test "groups status, dnssec, domain and client counts per UTC day" do
      d1 = ~U[2026-05-30 12:00:00Z]
      d2 = ~U[2026-05-31 12:00:00Z]

      QueryHistory.insert_many([
        entry(domain: "a.com", client: "10.0.0.1", status: :ok, dnssec: :secure, queried_at: d1),
        entry(domain: "a.com", client: "10.0.0.1", status: :ok, dnssec: :secure, queried_at: d1),
        entry(domain: "b.com", client: "10.0.0.2", status: :blocked, dnssec: nil, queried_at: d2)
      ])

      counts = Map.new(QueryHistory.daily_counts(~D[2026-05-30], ~D[2026-05-31]))

      assert counts[{"2026-05-30", :status, :ok}] == 2
      assert counts[{"2026-05-31", :status, :blocked}] == 1
      assert counts[{"2026-05-30", :dnssec, :secure}] == 2
      assert counts[{"2026-05-30", :domain, "a.com"}] == 2
      assert counts[{"2026-05-31", :domain, "b.com"}] == 1
      assert counts[{"2026-05-30", :client, "10.0.0.1"}] == 2
      # No dnssec verdict on the blocked row → not aggregated.
      refute Map.has_key?(counts, {"2026-05-31", :dnssec, nil})
    end

    test "excludes days outside the inclusive range" do
      QueryHistory.insert_many([
        entry(status: :ok, queried_at: ~U[2026-05-29 12:00:00Z]),
        entry(status: :ok, queried_at: ~U[2026-05-30 12:00:00Z])
      ])

      counts = Map.new(QueryHistory.daily_counts(~D[2026-05-30], ~D[2026-05-30]))

      assert counts[{"2026-05-30", :status, :ok}] == 1
      refute Map.has_key?(counts, {"2026-05-29", :status, :ok})
    end
  end

  describe "series_counts/1" do
    test "buckets per-status counts into 10-minute slices" do
      at = ~U[2026-06-01 09:07:00Z]
      bucket = div(DateTime.to_unix(at), 600) * 600

      QueryHistory.insert_many([
        entry(status: :ok, queried_at: at),
        entry(status: :ok, queried_at: DateTime.add(at, 30)),
        entry(status: :blocked, queried_at: DateTime.add(at, 60))
      ])

      counts = Map.new(QueryHistory.series_counts(bucket - 600))

      assert counts[{bucket, :ok}] == 2
      assert counts[{bucket, :blocked}] == 1
    end

    test "excludes buckets before the since cutoff" do
      old = ~U[2026-06-01 00:00:00Z]
      new = ~U[2026-06-01 12:00:00Z]
      new_bucket = div(DateTime.to_unix(new), 600) * 600

      QueryHistory.insert_many([
        entry(status: :ok, queried_at: old),
        entry(status: :ok, queried_at: new)
      ])

      counts = Map.new(QueryHistory.series_counts(new_bucket))

      assert counts[{new_bucket, :ok}] == 1
      assert map_size(counts) == 1
    end
  end

  describe "prune/1" do
    test "deletes rows older than the cutoff, keeps the rest" do
      now = DateTime.utc_now()

      QueryHistory.insert_many([
        entry(domain: "old.com", queried_at: DateTime.add(now, -40, :day)),
        entry(domain: "fresh.com", queried_at: now)
      ])

      assert QueryHistory.prune(DateTime.add(now, -30, :day)) == 1
      assert Enum.map(QueryHistory.recent(), & &1.domain) == ["fresh.com"]
    end
  end

  describe "clear/0" do
    test "removes every persisted row" do
      QueryHistory.insert_many([entry(domain: "x.com")])
      assert QueryHistory.clear() == 1
      assert QueryHistory.recent() == []
    end
  end
end
