defmodule EliHole.DNS.PauseControlTest do
  # Not async: PauseControl is a singleton GenServer with global ETS state, and
  # the resolver integration path mutates the shared Blocklist/Cache.
  use EliHole.DataCase, async: false

  alias EliHole.DNS.{Blocklist, Cache, PauseControl, Resolver, Setting}

  setup do
    on_exit(fn -> PauseControl.resume() end)
    :ok
  end

  defp build_query(domain, type) do
    header = :inet_dns.make_header(id: 1234, qr: false, opcode: :query, rd: true)
    query = :inet_dns.make_dns_query(domain: String.to_charlist(domain), type: type, class: :in)
    msg = :inet_dns.make_msg(header: header, qdlist: [query])

    case :inet_dns.encode(msg) do
      {:ok, p} -> p
      p when is_binary(p) -> p
    end
  end

  describe "state" do
    test "blocking is active by default" do
      PauseControl.resume()
      assert PauseControl.paused?() == false
      assert PauseControl.remaining() == 0
      assert PauseControl.status() == %{paused?: false, remaining: 0}
    end

    test "pause/1 pauses for the requested minutes" do
      assert :ok = PauseControl.pause(5)
      assert PauseControl.paused?() == true
      # Allow a second of scheduling slack below the 300s deadline.
      assert PauseControl.remaining() in 299..300
    end

    test "resume/0 clears an active pause" do
      PauseControl.pause(5)
      assert PauseControl.paused?() == true

      assert :ok = PauseControl.resume()
      assert PauseControl.paused?() == false
      assert PauseControl.remaining() == 0
    end

    test "pause/1 rejects non-positive durations" do
      assert_raise FunctionClauseError, fn -> PauseControl.pause(0) end
      assert_raise FunctionClauseError, fn -> PauseControl.pause(-1) end
    end
  end

  describe "persistence" do
    test "pause persists the resume deadline; resume persists 0" do
      before = System.system_time(:second)
      PauseControl.pause(10)

      stored = Repo.get_by(Setting, key: "pause_until").value
      {until, _} = Integer.parse(stored)
      assert until >= before + 600

      PauseControl.resume()
      assert Repo.get_by(Setting, key: "pause_until").value == "0"
    end
  end

  describe "broadcast" do
    test "pause and resume broadcast on dns:pause" do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:pause")

      PauseControl.pause(1)
      assert_receive {:pause_changed, %{paused?: true, remaining: r}} when r > 0

      PauseControl.resume()
      assert_receive {:pause_changed, %{paused?: false, remaining: 0}}
    end
  end

  describe "resolver integration" do
    test "a blocked domain resolves normally while paused, blocks again on resume" do
      domain = "pause-blocked-#{System.unique_integer([:positive])}.example"
      {:ok, _} = Blocklist.add_exact(domain)

      # Seed the cache so the un-blocked path returns a cache hit instead of
      # touching a real upstream.
      cached = <<0, 0, 0::size(80)>>
      Cache.put(domain, "A", cached, "test:53")

      query = build_query(domain, :a)

      # Active: the blocklist short-circuits before the cache.
      assert {:blocked, nil, _} = Resolver.resolve(query)

      # Paused: the block predicate is bypassed, so the cache hit wins.
      PauseControl.pause(5)
      assert {:ok, source, _} = Resolver.resolve(query)
      assert source =~ "cache"

      # Resumed: blocking is enforced again.
      PauseControl.resume()
      assert {:blocked, nil, _} = Resolver.resolve(query)
    end
  end
end
