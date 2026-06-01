defmodule EliHole.DNS.ServerTest do
  use EliHole.DataCase, async: false

  alias EliHole.DNS.{Cache, Server}

  # Ephemeral UDP "upstream" answering every query with a fixed A record, so the
  # server's real forward path (handler -> resolver -> upstream) is exercised
  # rather than a cache shortcut. Mirrors the pattern in handler_test/dot_server_test.
  defp start_fake_upstream(answer_fun) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true, reuseaddr: true])
    {:ok, port} = :inet.port(socket)

    pid =
      spawn_link(fn ->
        loop = fn loop_fn ->
          receive do
            {:udp, ^socket, ip, sport, packet} ->
              # Stay alive on undecodable input (the malformed-packet test may
              # forward garbage here): only answer when we can build a reply.
              try do
                :gen_udp.send(socket, ip, sport, answer_fun.(packet))
              rescue
                _ -> :ok
              end

              loop_fn.(loop_fn)
          end
        end

        loop.(loop)
      end)

    # Hand socket ownership to the loop pid so it receives active-mode `{:udp, ...}`
    # answers (the caller would otherwise swallow them and every forward times out).
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

    port
  end

  defp build_query(domain, type) do
    header = :inet_dns.make_header(id: 4242, qr: false, opcode: :query, rd: true)
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

  # Start the server on an ephemeral OS-assigned port (port: 0 -> :gen_udp picks
  # a free port). The server's state stores the *requested* port (0), so read the
  # real bound port back from the socket via `:inet.port/1`.
  #
  # `Server.start_link/1` registers the GenServer under `name: __MODULE__`, and
  # the application supervisor already runs one such instance. To start an
  # isolated, *unnamed* instance for the test we invoke `GenServer.start_link/3`
  # directly (which still drives `Server.init/1`) via a custom child spec, with a
  # unique `id` so multiple instances can coexist under the test supervisor.
  defp start_server!(opts \\ [port: 0]) do
    pid =
      start_supervised!(%{
        id: {Server, System.unique_integer([:positive])},
        start: {GenServer, :start_link, [Server, opts]},
        restart: :temporary
      })

    %{socket: socket} = :sys.get_state(pid)
    {:ok, port} = :inet.port(socket)
    {pid, port}
  end

  # Client socket bound to its own ephemeral port; replies arrive as active-mode
  # `{:udp, ...}` messages we can `assert_receive` (no Process.sleep needed).
  defp open_client! do
    {:ok, sock} = :gen_udp.open(0, [:binary, active: true])
    on_exit(fn -> :gen_udp.close(sock) end)
    sock
  end

  describe "init/1" do
    test "opens the UDP listener and stores socket + port in state" do
      {pid, port} = start_server!()
      state = :sys.get_state(pid)

      assert is_port(state.socket) or is_reference(state.socket)
      # Requested port was 0; OS assigned a real, non-zero port.
      assert state.port == 0
      assert port > 0
    end

    test "fails to start when the requested port is already bound" do
      # Grab a concrete port, then ask the server for the same one.
      {:ok, hog} = :gen_udp.open(0, [:binary, active: true, reuseaddr: false])
      {:ok, taken} = :inet.port(hog)
      on_exit(fn -> :gen_udp.close(hog) end)

      # `init/1` returns `{:stop, reason}` when the port can't be opened, so
      # `GenServer.start_link` yields `{:error, reason}` (here :eaddrinuse).
      Process.flag(:trap_exit, true)
      assert {:error, reason} = GenServer.start_link(Server, port: taken)
      assert reason in [:eaddrinuse, :eacces]
    end
  end

  describe "UDP query handling" do
    setup do
      port = start_fake_upstream(fn q -> build_a_response(q, {1, 2, 3, 4}) end)
      {_pid, server_port} = start_server!()
      %{upstream_port: port, server_port: server_port}
    end

    test "answers an A-record query forwarded through the handler pipeline",
         %{server_port: server_port} do
      client = open_client!()
      query = build_query("server-#{System.unique_integer([:positive])}.example", :a)

      :ok = :gen_udp.send(client, {127, 0, 0, 1}, server_port, query)

      assert_receive {:udp, ^client, _ip, ^server_port, response}, 5_000
      assert first_answer_data(response) == {1, 2, 3, 4}
    end

    test "preserves the query id in the response", %{server_port: server_port} do
      client = open_client!()
      query = build_query("server-id-#{System.unique_integer([:positive])}.example", :a)

      :ok = :gen_udp.send(client, {127, 0, 0, 1}, server_port, query)

      assert_receive {:udp, ^client, _ip, ^server_port, response}, 5_000
      {:ok, record} = :inet_dns.decode(response)
      assert record |> :inet_dns.msg(:header) |> :inet_dns.header(:id) == 4242
    end

    test "handles two concurrent clients independently", %{server_port: server_port} do
      c1 = open_client!()
      c2 = open_client!()

      q1 = build_query("server-c1-#{System.unique_integer([:positive])}.example", :a)
      q2 = build_query("server-c2-#{System.unique_integer([:positive])}.example", :a)

      :ok = :gen_udp.send(c1, {127, 0, 0, 1}, server_port, q1)
      :ok = :gen_udp.send(c2, {127, 0, 0, 1}, server_port, q2)

      assert_receive {:udp, ^c1, _ip1, ^server_port, r1}, 5_000
      assert_receive {:udp, ^c2, _ip2, ^server_port, r2}, 5_000
      assert first_answer_data(r1) == {1, 2, 3, 4}
      assert first_answer_data(r2) == {1, 2, 3, 4}
    end
  end

  describe "robustness" do
    setup do
      port = start_fake_upstream(fn q -> build_a_response(q, {1, 2, 3, 4}) end)
      {pid, server_port} = start_server!()
      %{upstream_port: port, server_port: server_port, pid: pid}
    end

    test "a malformed packet does not crash the server", %{pid: pid, server_port: server_port} do
      ref = Process.monitor(pid)
      client = open_client!()

      # Garbage that is not a valid DNS message.
      :ok = :gen_udp.send(client, {127, 0, 0, 1}, server_port, <<0, 1, 2, 3, 4, 5>>)

      # The server must stay alive: a valid query right after still gets answered,
      # which both proves survival and synchronizes (no sleep). If the server had
      # died, `:sys.get_state` below would raise.
      query = build_query("server-after-bad-#{System.unique_integer([:positive])}.example", :a)
      :ok = :gen_udp.send(client, {127, 0, 0, 1}, server_port, query)

      assert_receive {:udp, ^client, _ip, ^server_port, response}, 5_000
      assert first_answer_data(response) == {1, 2, 3, 4}

      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert is_map(:sys.get_state(pid))
    end
  end

  describe "terminate/2" do
    test "closes the UDP socket so the port is released on shutdown" do
      {pid, port} = start_server!()

      ref = Process.monitor(pid)
      :ok = GenServer.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      # `terminate/2` closes the socket; the released port must now be re-bindable.
      assert {:ok, reopened} = :gen_udp.open(port, [:binary, active: true, reuseaddr: true])
      :gen_udp.close(reopened)
    end
  end
end
