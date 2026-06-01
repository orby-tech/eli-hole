defmodule EliHole.DNS.GravityTest do
  use EliHole.DataCase

  alias EliHole.DNS.{Adlist, Adlists, Blocklist, BlocklistEntry, Gravity}

  # A tiny Plug that serves a fixed body/status, keyed by the request path so a
  # single server can stand in for several adlist URLs in one test.
  defmodule FakeAdlistServer do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      {status, body} = Agent.get(__MODULE__, &Map.get(&1, conn.request_path, {404, ""}))

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(status, body)
    end
  end

  # Boot a real HTTP server (Gravity uses live `Req.get`, no Req.Test stub), and
  # an Agent holding the path -> {status, body} routing table. The Agent is linked
  # to the test process, so it dies (and is freshly recreated) per test.
  setup do
    {:ok, _} = Agent.start_link(fn -> %{} end, name: FakeAdlistServer)

    {:ok, server} =
      start_supervised(
        {Bandit, plug: FakeAdlistServer, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Repo.delete_all(Adlist)
    Repo.delete_all(BlocklistEntry)
    Blocklist.flush_cache()

    %{port: port}
  end

  defp route(path, status, body) do
    Agent.update(FakeAdlistServer, &Map.put(&1, path, {status, body}))
  end

  defp url(port, path), do: "http://127.0.0.1:#{port}#{path}"

  describe "status/0 and update_sync/0 with no adlists" do
    test "reports a baseline status" do
      status = Gravity.status()
      assert is_map(status)
      assert Map.has_key?(status, :updating)
      assert Map.has_key?(status, :last_update)
      assert Map.has_key?(status, :last_result)
    end

    test "sync with no enabled adlists yields a zero result" do
      assert {:ok, result} = Gravity.update_sync()
      assert result == %{total: 0, lists: 0}
    end
  end

  describe "update_sync/0 — hosts-format adlist" do
    test "parses a hosts file into exact blocklist entries" do
      {:ok, adlist} = Adlists.create(%{address: url(_p = current_port(), "/hosts")})

      route("/hosts", 200, """
      # title: my list
      0.0.0.0 ads.example.com
      0.0.0.0 tracker.example.com
      127.0.0.1 localhost

      """)

      assert {:ok, %{total: total, lists: 1}} = Gravity.update_sync()
      assert total == 2

      source = "gravity:#{adlist.id}"
      domains = Repo.all(from e in BlocklistEntry, where: e.source == ^source, select: e.domain)
      assert "ads.example.com" in domains
      assert "tracker.example.com" in domains
      # localhost is filtered out
      refute "localhost" in domains
      assert length(domains) == 2

      # entries land in the live cache so blocked?/1 sees them
      assert Blocklist.blocked?("ads.example.com")
    end

    test "records domain_count and last_updated_at on the adlist" do
      {:ok, adlist} = Adlists.create(%{address: url(current_port(), "/hosts2")})
      route("/hosts2", 200, "0.0.0.0 a.example.com\n0.0.0.0 b.example.com\n")

      assert {:ok, _} = Gravity.update_sync()

      reloaded = Adlists.get!(adlist.id)
      assert reloaded.domain_count == 2
      assert %DateTime{} = reloaded.last_updated_at
    end

    test "lowercases and de-duplicates domains" do
      {:ok, adlist} = Adlists.create(%{address: url(current_port(), "/dup")})
      route("/dup", 200, "0.0.0.0 ADS.Example.COM\n0.0.0.0 ads.example.com\n")

      assert {:ok, %{total: 1}} = Gravity.update_sync()

      source = "gravity:#{adlist.id}"
      domains = Repo.all(from e in BlocklistEntry, where: e.source == ^source, select: e.domain)
      assert domains == ["ads.example.com"]
    end
  end

  describe "update_sync/0 — parsing edge cases" do
    test "skips '#' comment lines and blank lines" do
      {:ok, adlist} = Adlists.create(%{address: url(current_port(), "/comments")})

      route("/comments", 200, """
      # header comment
      0.0.0.0 keep.example.com

      # trailing comment

      0.0.0.0 also.example.com
      """)

      assert {:ok, %{total: 2}} = Gravity.update_sync()

      source = "gravity:#{adlist.id}"
      domains = Repo.all(from e in BlocklistEntry, where: e.source == ^source, select: e.domain)
      assert "keep.example.com" in domains
      assert "also.example.com" in domains
      assert length(domains) == 2
    end

    test "an empty body imports nothing" do
      {:ok, adlist} = Adlists.create(%{address: url(current_port(), "/empty")})
      route("/empty", 200, "")

      assert {:ok, %{total: 0, lists: 1}} = Gravity.update_sync()

      source = "gravity:#{adlist.id}"
      refute Repo.exists?(from e in BlocklistEntry, where: e.source == ^source)

      # domain_count is still recorded as 0
      assert Adlists.get!(adlist.id).domain_count == 0
    end

    test "single-token (domain-only) lines yield no domains (IP prefix required)" do
      {:ok, adlist} = Adlists.create(%{address: url(current_port(), "/bare")})
      # No IP column: parser splits to [domain] and treats it as [ip | []] -> []
      route("/bare", 200, "bare-domain.example.com\nanother.example.com\n")

      assert {:ok, %{total: 0}} = Gravity.update_sync()

      source = "gravity:#{adlist.id}"
      refute Repo.exists?(from e in BlocklistEntry, where: e.source == ^source)
    end
  end

  describe "update_sync/0 — multiple domains per line" do
    test "captures every domain after the IP, skipping localhost/local" do
      {:ok, adlist} = Adlists.create(%{address: url(current_port(), "/multi")})
      route("/multi", 200, "0.0.0.0 ads.example.com tracker.net localhost\n")

      assert {:ok, %{total: 2}} = Gravity.update_sync()

      source = "gravity:#{adlist.id}"
      domains = Repo.all(from e in BlocklistEntry, where: e.source == ^source, select: e.domain)
      assert "ads.example.com" in domains
      assert "tracker.net" in domains
      refute "localhost" in domains
    end
  end

  describe "update_sync/0 — enabled vs disabled adlists" do
    test "skips disabled adlists" do
      {:ok, enabled} = Adlists.create(%{address: url(current_port(), "/on")})
      {:ok, disabled} = Adlists.create(%{address: url(current_port(), "/off")})
      {:ok, _} = Adlists.update(disabled, %{enabled: false})

      route("/on", 200, "0.0.0.0 on.example.com\n")
      route("/off", 200, "0.0.0.0 off.example.com\n")

      assert {:ok, %{total: 1, lists: 1}} = Gravity.update_sync()

      assert Repo.exists?(from e in BlocklistEntry, where: e.source == ^"gravity:#{enabled.id}")
      refute Repo.exists?(from e in BlocklistEntry, where: e.source == ^"gravity:#{disabled.id}")
    end
  end

  describe "update_sync/0 — HTTP/error handling" do
    test "non-200 responses contribute zero domains" do
      {:ok, _} = Adlists.create(%{address: url(current_port(), "/missing")})
      route("/missing", 404, "not found")

      assert {:ok, %{total: 0, lists: 1}} = Gravity.update_sync()
    end

    test "a failing list does not block a succeeding one" do
      {:ok, good} = Adlists.create(%{address: url(current_port(), "/good")})
      {:ok, _bad} = Adlists.create(%{address: url(current_port(), "/bad")})

      route("/good", 200, "0.0.0.0 good.example.com\n")
      # 404 (not 5xx) so Req doesn't burn time on its default retry backoff
      route("/bad", 404, "boom")

      assert {:ok, %{total: 1, lists: 2}} = Gravity.update_sync()

      assert Repo.exists?(from e in BlocklistEntry, where: e.source == ^"gravity:#{good.id}")
    end
  end

  describe "update_sync/0 — re-sync replaces prior entries" do
    test "old gravity entries for a list are removed before re-import" do
      {:ok, adlist} = Adlists.create(%{address: url(current_port(), "/resync")})
      source = "gravity:#{adlist.id}"

      route("/resync", 200, "0.0.0.0 first.example.com\n0.0.0.0 second.example.com\n")
      assert {:ok, %{total: 2}} = Gravity.update_sync()

      # Change the served content; the second sync should reflect only the new set.
      route("/resync", 200, "0.0.0.0 third.example.com\n")
      assert {:ok, _} = Gravity.update_sync()

      domains = Repo.all(from e in BlocklistEntry, where: e.source == ^source, select: e.domain)
      assert domains == ["third.example.com"]
    end
  end

  describe "update_now/0 (async cast)" do
    test "imports domains and broadcasts :gravity_updated" do
      {:ok, adlist} = Adlists.create(%{address: url(current_port(), "/cast")})
      route("/cast", 200, "0.0.0.0 cast.example.com\n")

      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:gravity")
      :ok = Gravity.update_now()

      assert_receive {:gravity_status, :updating}, 2000
      assert_receive :gravity_updated, 2000
      assert_receive {:gravity_status, :idle}, 2000

      source = "gravity:#{adlist.id}"
      assert Repo.exists?(from e in BlocklistEntry, where: e.source == ^source)
    end
  end

  # NOTE on the `updating: true` concurrency guards in handle_call/handle_cast/
  # handle_info: `do_update/1` runs *inline* and resets `updating` to false before
  # returning, so the flag never survives across a message boundary in the single-
  # threaded GenServer. A second message is only dequeued after the first finishes,
  # at which point the flag is already false. The guards are therefore not
  # reachable without restructuring the lib to run downloads off-process, so they
  # are intentionally left uncovered here rather than asserted via a flaky/racy
  # test or a lib change.

  describe "PubSub status broadcasts" do
    test "sync broadcasts updating then idle" do
      {:ok, _} = Adlists.create(%{address: url(current_port(), "/bcast")})
      route("/bcast", 200, "0.0.0.0 bcast.example.com\n")

      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:gravity")
      assert {:ok, _} = Gravity.update_sync()

      assert_receive {:gravity_status, :updating}
      assert_receive {:gravity_status, :idle}
      assert_receive :gravity_updated
    end

    test "empty sync broadcasts updating then idle without :gravity_updated" do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:gravity")
      assert {:ok, %{total: 0, lists: 0}} = Gravity.update_sync()

      assert_receive {:gravity_status, :updating}
      assert_receive {:gravity_status, :idle}
      refute_receive :gravity_updated, 50
    end
  end

  # The Bandit server's listen port is dynamic (port: 0). We grab it once per
  # test from the process dictionary primed in setup via the context — but since
  # `setup` returns it in the context map, expose it through a helper that reads
  # the test's context-provided value. We stash it in the process dictionary in
  # the per-test setup block below.
  defp current_port, do: Process.get(:gravity_test_port)

  setup %{port: port} do
    Process.put(:gravity_test_port, port)
    :ok
  end
end
