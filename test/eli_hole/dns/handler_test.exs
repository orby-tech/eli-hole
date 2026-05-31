defmodule EliHole.DNS.HandlerTest do
  use EliHole.DataCase, async: false

  alias EliHole.DNS.{Blocklist, Cache, Handler, QueryLog}

  # Ephemeral UDP "upstream" answering every query with a fixed A record, so we
  # exercise the real forward path (not just a cache shortcut).
  defp start_fake_upstream(answer_fun) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true, reuseaddr: true])
    {:ok, port} = :inet.port(socket)

    pid =
      spawn_link(fn ->
        loop = fn loop_fn ->
          receive do
            {:udp, ^socket, ip, sport, packet} ->
              :gen_udp.send(socket, ip, sport, answer_fun.(packet))
              loop_fn.(loop_fn)
          end
        end

        loop.(loop)
      end)

    # The socket's controlling process (default: the caller) receives the
    # active-mode `{:udp, ...}` messages, so hand ownership to the loop pid —
    # otherwise the answers never reach `loop` and every forward times out.
    :ok = :gen_udp.controlling_process(socket, pid)

    {socket, port, pid}
  end

  defp setup_upstream(answer_fun) do
    {socket, port, pid} = start_fake_upstream(answer_fun)
    # Drive the real upstream-selection path (ETS), which `Cache.get_upstreams/0`
    # reads before falling back to app env — otherwise a prior test that set the
    # ETS `:upstreams` key (e.g. cache_test) would mask this fake upstream.
    original = Cache.get_upstreams()
    Cache.set_upstreams([{{127, 0, 0, 1}, port}])

    on_exit(fn ->
      Cache.set_upstreams(original)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_udp.close(socket)
    end)

    port
  end

  defp build_query(domain, type) do
    header = :inet_dns.make_header(id: 4242, qr: false, opcode: :query, rd: true)
    query = :inet_dns.make_dns_query(domain: String.to_charlist(domain), type: type, class: :in)
    msg = :inet_dns.make_msg(header: header, qdlist: [query])
    encode(msg)
  end

  defp build_a_response(query_packet, ip_tuple) do
    {:ok, record} = :inet_dns.decode(query_packet)
    id = record |> :inet_dns.msg(:header) |> :inet_dns.header(:id)
    qdlist = :inet_dns.msg(record, :qdlist)
    domain = qdlist |> List.first() |> :inet_dns.dns_query(:domain)

    header =
      :inet_dns.make_header(
        id: id,
        qr: true,
        opcode: :query,
        aa: true,
        rd: true,
        ra: true,
        rcode: 0
      )

    answer = :inet_dns.make_rr(domain: domain, type: :a, class: :in, ttl: 300, data: ip_tuple)
    encode(:inet_dns.make_msg(header: header, qdlist: qdlist, anlist: [answer]))
  end

  defp encode(msg) do
    case :inet_dns.encode(msg) do
      {:ok, p} -> p
      p when is_binary(p) -> p
    end
  end

  defp first_answer_data(response) do
    {:ok, record} = :inet_dns.decode(response)
    record |> :inet_dns.msg(:anlist) |> List.first() |> :inet_dns.rr(:data)
  end

  describe "process/3 — resolved via upstream" do
    setup do
      port = setup_upstream(fn q -> build_a_response(q, {1, 2, 3, 4}) end)
      %{port: port}
    end

    test "forwards the query and returns the upstream answer" do
      query = build_query("handler-#{System.unique_integer([:positive])}.example", :a)
      response = Handler.process(query, "10.0.0.1:5300", :udp)
      assert first_answer_data(response) == {1, 2, 3, 4}
    end

    test "logs the query tagged with its transport and client" do
      QueryLog.subscribe()
      domain = "handler-log-#{System.unique_integer([:positive])}.example"

      Handler.process(build_query(domain, :a), "10.0.0.2:5300", :doh)

      # Match our own domain explicitly — QueryLog broadcasts for every query
      # system-wide, so a late async log from another test could arrive first.
      assert_receive {:new_query, %{domain: ^domain} = entry}, 2_000
      assert entry.transport == :doh
      assert entry.client == "10.0.0.2:5300"
      assert entry.status == :ok
    end
  end

  describe "process/3 — blocked" do
    test "returns 0.0.0.0 for a blocked A query without contacting upstream" do
      # Point upstream at a dead port so any forward attempt would clearly fail;
      # a correct blocked path never touches it.
      original = Application.get_env(:eli_hole, :dns_upstreams)
      Application.put_env(:eli_hole, :dns_upstreams, [{{127, 0, 0, 1}, 1}])
      on_exit(fn -> Application.put_env(:eli_hole, :dns_upstreams, original) end)

      domain = "blocked-#{System.unique_integer([:positive])}.example"
      Blocklist.add_exact(domain)

      response = Handler.process(build_query(domain, :a), "10.0.0.3:5300", :dot)
      assert first_answer_data(response) == {0, 0, 0, 0}
    end
  end
end
