defmodule EliHole.DNS.CnameCloakingTest do
  use EliHole.DataCase

  alias EliHole.DNS.{Blocklist, BlocklistEntry, Cache, Resolver, Whitelist, WhitelistEntry}

  setup do
    Repo.delete_all(BlocklistEntry)
    Repo.delete_all(WhitelistEntry)
    Blocklist.flush_cache()
    Whitelist.flush_cache()
    :ok
  end

  defp build_dns_query(domain, type) do
    header = :inet_dns.make_header(id: 4321, qr: false, opcode: :query, rd: true)
    query = :inet_dns.make_dns_query(domain: String.to_charlist(domain), type: type, class: :in)
    msg = :inet_dns.make_msg(header: header, qdlist: [query])
    :inet_dns.encode(msg)
  end

  # Build an upstream-style A response whose answer section is a CNAME pointing
  # to `cname_target` (simulating CNAME cloaking).
  defp build_cname_response(domain, cname_target) do
    header =
      :inet_dns.make_header(id: 4321, qr: true, opcode: :query, aa: false, rcode: 0, ra: true)

    query = :inet_dns.make_dns_query(domain: String.to_charlist(domain), type: :a, class: :in)

    cname_rr =
      :inet_dns.make_rr(
        domain: String.to_charlist(domain),
        type: :cname,
        class: :in,
        ttl: 300,
        data: String.to_charlist(cname_target)
      )

    msg = :inet_dns.make_msg(header: header, qdlist: [query], anlist: [cname_rr])

    case :inet_dns.encode(msg) do
      {:ok, bin} -> bin
      bin when is_binary(bin) -> bin
    end
  end

  defp seed_cached_cname(cname_target) do
    domain = "clean-#{System.unique_integer([:positive])}.example.com"
    response = build_cname_response(domain, cname_target)
    Cache.put(domain, "A", response, "test:53")
    domain
  end

  # Spawn a fake upstream DNS server that always replies with `response`,
  # patching the response's transaction id to match each incoming query.
  defp start_fake_upstream(response) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, sock} = :gen_udp.open(0, [:binary, active: true])
        {:ok, port} = :inet.port(sock)
        send(parent, {:upstream_port, port})
        fake_upstream_loop(sock, response)
      end)

    receive do
      {:upstream_port, port} -> {pid, port}
    after
      1_000 -> raise "fake upstream failed to start"
    end
  end

  defp fake_upstream_loop(sock, response) do
    receive do
      {:udp, ^sock, ip, port, data} ->
        <<id::16, _::binary>> = data
        <<_::16, rest::binary>> = response
        :gen_udp.send(sock, ip, port, <<id::16, rest::binary>>)
        fake_upstream_loop(sock, response)
    end
  end

  describe "CNAME cloaking detection (via cache-hit path)" do
    test "blocks a clean domain whose CNAME target is on the blocklist" do
      Blocklist.create_entry(%{"domain" => "ads.doubleclick.net", "type" => "exact"})
      domain = seed_cached_cname("ads.doubleclick.net")

      assert {:blocked, nil, response} = Resolver.resolve(build_dns_query(domain, :a))
      assert is_binary(response) and byte_size(response) > 0
    end

    test "blocks when CNAME target matches a wildcard blocklist entry" do
      Blocklist.create_entry(%{"domain" => "*.doubleclick.net", "type" => "wildcard"})
      domain = seed_cached_cname("stats.g.doubleclick.net")

      assert {:blocked, nil, _response} = Resolver.resolve(build_dns_query(domain, :a))
    end

    test "does not block when CNAME target is clean" do
      Blocklist.create_entry(%{"domain" => "ads.doubleclick.net", "type" => "exact"})
      domain = seed_cached_cname("cdn.cloudfront.net")

      assert {:ok, source, _response} = Resolver.resolve(build_dns_query(domain, :a))
      assert source =~ "cache"
    end

    test "whitelisted CNAME target overrides the blocklist" do
      Blocklist.create_entry(%{"domain" => "ads.doubleclick.net", "type" => "exact"})
      Whitelist.create_entry(%{"domain" => "ads.doubleclick.net", "type" => "exact"})
      domain = seed_cached_cname("ads.doubleclick.net")

      assert {:ok, source, _response} = Resolver.resolve(build_dns_query(domain, :a))
      assert source =~ "cache"
    end

    test "does not block when there are no CNAME records in the answer" do
      Blocklist.create_entry(%{"domain" => "ads.doubleclick.net", "type" => "exact"})
      domain = "plain-#{System.unique_integer([:positive])}.example.com"
      # A-record-only response (no CNAME) — fabricate via a minimal A answer.
      header = :inet_dns.make_header(id: 4321, qr: true, opcode: :query, rcode: 0, ra: true)
      query = :inet_dns.make_dns_query(domain: String.to_charlist(domain), type: :a, class: :in)

      a_rr =
        :inet_dns.make_rr(
          domain: String.to_charlist(domain),
          type: :a,
          class: :in,
          ttl: 300,
          data: {93, 184, 216, 34}
        )

      response =
        case :inet_dns.encode(:inet_dns.make_msg(header: header, qdlist: [query], anlist: [a_rr])) do
          {:ok, bin} -> bin
          bin when is_binary(bin) -> bin
        end

      Cache.put(domain, "A", response, "test:53")

      assert {:ok, _source, _response} = Resolver.resolve(build_dns_query(domain, :a))
    end
  end

  describe "CNAME cloaking detection (via live upstream path)" do
    test "blocks a cloaked upstream answer and does not cache it" do
      Blocklist.create_entry(%{"domain" => "ads.doubleclick.net", "type" => "exact"})
      domain = "upstream-#{System.unique_integer([:positive])}.example.com"
      cloaked = build_cname_response(domain, "ads.doubleclick.net")

      {_pid, port} = start_fake_upstream(cloaked)
      prev_upstreams = Cache.get_upstreams()
      Cache.set_upstreams([{{127, 0, 0, 1}, port}])
      on_exit(fn -> Cache.set_upstreams(prev_upstreams) end)

      # Cache miss -> goes to upstream -> upstream returns cloaked CNAME -> blocked.
      assert :miss = Cache.lookup(domain, "A")
      assert {:blocked, nil, _response} = Resolver.resolve(build_dns_query(domain, :a))

      # Cloaked answers must NOT be cached.
      assert :miss = Cache.lookup(domain, "A")
    end
  end
end
