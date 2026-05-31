defmodule EliHoleWeb.DohControllerTest do
  use EliHoleWeb.ConnCase, async: false

  alias EliHole.DNS.Cache

  # Ephemeral UDP "upstream" so DoH exercises the real forward path.
  defp setup_upstream(answer_fun) do
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

    # Hand socket ownership to the loop pid so it receives the active-mode
    # `{:udp, ...}` answers (the caller would otherwise swallow them).
    :ok = :gen_udp.controlling_process(socket, pid)

    # Drive the real upstream-selection path (ETS) so a prior test that populated
    # the ETS `:upstreams` key can't mask this fake upstream.
    original = Cache.get_upstreams()
    Cache.set_upstreams([{{127, 0, 0, 1}, port}])

    on_exit(fn ->
      Cache.set_upstreams(original)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_udp.close(socket)
    end)

    :ok
  end

  defp build_query(domain, type) do
    header = :inet_dns.make_header(id: 777, qr: false, opcode: :query, rd: true)
    query = :inet_dns.make_dns_query(domain: String.to_charlist(domain), type: type, class: :in)
    encode(:inet_dns.make_msg(header: header, qdlist: [query]))
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

  describe "POST /dns-query" do
    setup do
      setup_upstream(fn q -> build_a_response(q, {5, 6, 7, 8}) end)
      :ok
    end

    test "resolves a wire-format query in the request body", %{conn: conn} do
      query = build_query("doh-post-#{System.unique_integer([:positive])}.example", :a)

      conn =
        conn
        |> put_req_header("content-type", "application/dns-message")
        |> post(~p"/dns-query", query)

      assert hd(get_resp_header(conn, "content-type")) =~ "application/dns-message"
      assert first_answer_data(conn.resp_body) == {5, 6, 7, 8}
    end

    test "rejects an empty body", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/dns-message")
        |> post(~p"/dns-query", "")

      assert conn.status == 400
    end
  end

  describe "GET /dns-query" do
    setup do
      setup_upstream(fn q -> build_a_response(q, {9, 10, 11, 12}) end)
      :ok
    end

    test "resolves a base64url-encoded query in the dns param", %{conn: conn} do
      query = build_query("doh-get-#{System.unique_integer([:positive])}.example", :a)
      dns = Base.url_encode64(query, padding: false)

      conn = get(conn, ~p"/dns-query?dns=#{dns}")

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/dns-message"
      assert first_answer_data(conn.resp_body) == {9, 10, 11, 12}
    end

    test "rejects an invalid base64 dns param", %{conn: conn} do
      conn = get(conn, ~p"/dns-query?dns=not!!base64")
      assert conn.status == 400
    end

    test "rejects a missing dns param", %{conn: conn} do
      conn = get(conn, ~p"/dns-query")
      assert conn.status == 400
    end
  end
end
