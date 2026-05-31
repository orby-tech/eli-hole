defmodule EliHole.DNS.DoTServerTest do
  use EliHole.DataCase, async: false

  alias EliHole.DNS.{Cache, DoTServer}

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

  defp gen_cert do
    tmp = Path.join(System.tmp_dir!(), "elihole-dot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    cert = Path.join(tmp, "cert.pem")
    key = Path.join(tmp, "key.pem")

    {_out, 0} =
      System.cmd(
        "openssl",
        ~w(req -x509 -newkey rsa:2048 -nodes -keyout #{key} -out #{cert} -days 1 -subj /CN=localhost),
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf(tmp) end)
    {cert, key}
  end

  defp build_query(domain, type) do
    header = :inet_dns.make_header(id: 555, qr: false, opcode: :query, rd: true)
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

  describe "init/1 disabled paths" do
    test "returns :ignore with no certificate configured" do
      assert DoTServer.init(port: 0) == :ignore
    end

    test "returns :ignore when cert/key files are missing" do
      assert DoTServer.init(port: 0, certfile: "/nope/cert.pem", keyfile: "/nope/key.pem") ==
               :ignore
    end
  end

  describe "TLS query handling" do
    setup do
      start_fake_upstream(fn q -> build_a_response(q, {1, 2, 3, 4}) end)
      {cert, key} = gen_cert()
      start_supervised!({DoTServer, port: 0, certfile: cert, keyfile: key})
      %{port: DoTServer.port()}
    end

    test "resolves a length-prefixed query over TLS", %{port: port} do
      {:ok, sock} = tls_connect(port)
      query = build_query("dot-#{System.unique_integer([:positive])}.example", :a)
      :ok = :ssl.send(sock, query)
      {:ok, resp} = :ssl.recv(sock, 0, 5_000)
      assert first_answer_data(resp) == {1, 2, 3, 4}
      :ssl.close(sock)
    end

    test "serves multiple queries on one keep-alive connection", %{port: port} do
      {:ok, sock} = tls_connect(port)

      for _ <- 1..3 do
        query = build_query("dot-multi-#{System.unique_integer([:positive])}.example", :a)
        :ok = :ssl.send(sock, query)
        {:ok, resp} = :ssl.recv(sock, 0, 5_000)
        assert first_answer_data(resp) == {1, 2, 3, 4}
      end

      :ssl.close(sock)
    end
  end

  defp tls_connect(port) do
    :ssl.connect(
      ~c"127.0.0.1",
      port,
      [:binary, packet: 2, active: false, verify: :verify_none],
      5_000
    )
  end
end
