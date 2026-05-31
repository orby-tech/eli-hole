defmodule EliHole.DNS.RateLimiterTest do
  # Not async: RateLimiter is a singleton GenServer with global ETS state.
  use EliHole.DataCase, async: false

  alias EliHole.DNS.{Blocklist, Handler, QueryLog, RateLimiter}

  setup do
    on_exit(fn ->
      RateLimiter.set_enabled(false)
      RateLimiter.set_limit(100)
    end)

    :ok
  end

  defp unique_key, do: "10.0.0.#{System.unique_integer([:positive])}"

  defp build_query(domain) do
    header = :inet_dns.make_header(id: 4242, qr: false, opcode: :query, rd: true)
    query = :inet_dns.make_dns_query(domain: String.to_charlist(domain), type: :a, class: :in)
    msg = :inet_dns.make_msg(header: header, qdlist: [query])

    case :inet_dns.encode(msg) do
      {:ok, p} -> p
      p when is_binary(p) -> p
    end
  end

  defp rcode(response) do
    {:ok, record} = :inet_dns.decode(response)
    record |> :inet_dns.msg(:header) |> :inet_dns.header(:rcode)
  end

  describe "config" do
    test "defaults: disabled, limit 100" do
      assert RateLimiter.enabled?() == false
      assert RateLimiter.limit() == 100
      assert RateLimiter.config() == %{enabled: false, limit: 100}
    end

    test "set_enabled/1 and set_limit/1 round-trip and persist" do
      assert :ok = RateLimiter.set_enabled(true)
      assert RateLimiter.enabled?() == true

      assert :ok = RateLimiter.set_limit(5)
      assert RateLimiter.limit() == 5

      assert EliHole.Repo.get_by(EliHole.DNS.Setting, key: "rate_limit_enabled").value == "true"
      assert EliHole.Repo.get_by(EliHole.DNS.Setting, key: "rate_limit_per_sec").value == "5"
    end

    test "set_limit/1 rejects non-positive values" do
      assert_raise FunctionClauseError, fn -> RateLimiter.set_limit(0) end
      assert_raise FunctionClauseError, fn -> RateLimiter.set_limit(-1) end
    end

    test "config changes broadcast on dns:rate_limit" do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:rate_limit")
      RateLimiter.set_enabled(true)
      assert_receive {:rate_limit_changed, %{enabled: true}}
    end
  end

  describe "allow?/1" do
    test "always true when disabled, without touching the counter" do
      key = unique_key()
      RateLimiter.set_enabled(false)

      for _ <- 1..1_000, do: assert(RateLimiter.allow?(key))
    end

    test "allows up to the limit per second, then refuses" do
      key = unique_key()
      RateLimiter.set_enabled(true)
      RateLimiter.set_limit(3)

      # All within the same monotonic second (microsecond-fast loop).
      assert RateLimiter.allow?(key)
      assert RateLimiter.allow?(key)
      assert RateLimiter.allow?(key)
      refute RateLimiter.allow?(key)
      refute RateLimiter.allow?(key)
    end

    test "limits are per-client — one noisy client doesn't throttle another" do
      noisy = unique_key()
      quiet = unique_key()
      RateLimiter.set_enabled(true)
      RateLimiter.set_limit(1)

      assert RateLimiter.allow?(noisy)
      refute RateLimiter.allow?(noisy)

      assert RateLimiter.allow?(quiet)
    end

    test "non-binary key (unknown peer) is always allowed" do
      RateLimiter.set_enabled(true)
      RateLimiter.set_limit(1)
      assert RateLimiter.allow?(nil)
      assert RateLimiter.allow?(nil)
    end
  end

  describe "Handler integration" do
    test "throttled query returns REFUSED and is logged as :rate_limited" do
      # Blocked domain so no upstream is contacted on the allowed call.
      domain = "rl-#{System.unique_integer([:positive])}.example"
      Blocklist.add_exact(domain)
      packet = build_query(domain)
      key = unique_key()

      RateLimiter.set_enabled(true)
      RateLimiter.set_limit(1)

      QueryLog.subscribe()

      # First query is under the limit → normal (blocked) response, rcode 0.
      assert rcode(Handler.process(packet, "#{key}:5300", :udp, key)) == 0
      assert_receive {:new_query, %{domain: ^domain, status: :blocked}}, 2_000

      # Second query in the same window → REFUSED (rcode 5), logged rate_limited.
      assert rcode(Handler.process(packet, "#{key}:5300", :udp, key)) == 5
      assert_receive {:new_query, %{domain: ^domain, status: :rate_limited} = entry}, 2_000
      assert entry.upstream == nil
      assert entry.transport == :udp
    end

    test "nil rate_key skips throttling entirely" do
      domain = "rl-nil-#{System.unique_integer([:positive])}.example"
      Blocklist.add_exact(domain)
      packet = build_query(domain)

      RateLimiter.set_enabled(true)
      RateLimiter.set_limit(1)

      # No rate_key → never throttled regardless of how many queries.
      assert rcode(Handler.process(packet, "nokey", :udp, nil)) == 0
      assert rcode(Handler.process(packet, "nokey", :udp, nil)) == 0
      assert rcode(Handler.process(packet, "nokey", :udp, nil)) == 0
    end
  end
end
