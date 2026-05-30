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

  describe "pruning at max_entries" do
    test "prunes oldest entries when exceeding 10_000" do
      # Insert more than max_entries to trigger pruning multiple times
      for i <- 1..10_050 do
        QueryLog.log(%{domain: "prune#{i}.com", type: "A", status: :ok, upstream: "8.8.8.8:53"})
      end

      # Sync: send a synchronous call to ensure all preceding casts are processed
      _ = :sys.get_state(QueryLog)

      stats = QueryLog.stats()
      # After pruning, size should be at most max_entries (10,000)
      assert stats.total <= 10_000
      # And it should have a meaningful number of entries (not accidentally cleared)
      assert stats.total >= 9_900
    end
  end
end
