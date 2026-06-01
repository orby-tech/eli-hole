defmodule EliHole.DNS.ClusterTest do
  use EliHole.DataCase, async: false

  alias EliHole.DNS.{Cache, Cluster, ClusterNode, ClusterManager}

  # A minimal Plug that records the request (method, path, headers, decoded
  # JSON body) by sending it to a registered test pid, then replies with a
  # configurable status/body. Used as an ephemeral "master"/"slave" endpoint so
  # the real Req.post code path is exercised.
  defmodule EchoPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn, length: 10_000_000)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)

      test_pid = :persistent_term.get({:cluster_test_pid, conn.host <> ":#{conn.port}"}, nil)

      if test_pid do
        send(
          test_pid,
          {:http_request,
           %{method: conn.method, path: conn.request_path, headers: conn.req_headers, body: body}}
        )
      end

      {status, resp} = response_for(conn.request_path)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(resp))
    end

    defp response_for("/api/cluster/register") do
      status = :persistent_term.get({:cluster_test_register_status}, 200)
      config = :persistent_term.get({:cluster_test_register_config}, %{})
      {status, %{status: "ok", config: config}}
    end

    defp response_for(_path) do
      status = :persistent_term.get({:cluster_test_default_status}, 200)
      {status, %{status: "ok"}}
    end
  end

  # Boots a Bandit server with EchoPlug on an ephemeral port and registers the
  # current test pid so requests are forwarded to it. Returns the base URL.
  defp start_echo_server do
    {:ok, pid} = Bandit.start_link(plug: EchoPlug, scheme: :http, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    base = "http://127.0.0.1:#{port}"
    :persistent_term.put({:cluster_test_pid, "127.0.0.1:#{port}"}, self())

    on_exit(fn ->
      :persistent_term.erase({:cluster_test_pid, "127.0.0.1:#{port}"})
    end)

    %{pid: pid, port: port, base: base}
  end

  defp put_app_env(key, value) do
    prev = Application.fetch_env(:eli_hole, key)
    Application.put_env(:eli_hole, key, value)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:eli_hole, key, v)
        :error -> Application.delete_env(:eli_hole, key)
      end
    end)
  end

  defp valid_node_attrs(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{name: "node-#{n}", url: "http://node-#{n}.example.com:4000", api_key: "secret-#{n}"},
      overrides
    )
  end

  describe "instance_role/0 and predicates" do
    test "defaults to :standalone" do
      assert Cluster.instance_role() == :standalone
      refute Cluster.master?()
      refute Cluster.slave?()
    end

    test "master? reflects configured role" do
      put_app_env(:cluster_role, :master)
      assert Cluster.master?()
      refute Cluster.slave?()
    end

    test "slave? reflects configured role" do
      put_app_env(:cluster_role, :slave)
      assert Cluster.slave?()
      refute Cluster.master?()
    end
  end

  describe "ClusterNode.changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = ClusterNode.changeset(%ClusterNode{}, valid_node_attrs())
      assert cs.valid?
    end

    test "requires name, url and api_key" do
      cs = ClusterNode.changeset(%ClusterNode{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.url
      assert "can't be blank" in errors.api_key
    end

    test "rejects a url without http(s) scheme" do
      cs = ClusterNode.changeset(%ClusterNode{}, valid_node_attrs(%{url: "node.example.com"}))
      refute cs.valid?
      assert "must be an HTTP(S) URL" in errors_on(cs).url
    end

    test "accepts https urls" do
      cs = ClusterNode.changeset(%ClusterNode{}, valid_node_attrs(%{url: "https://node:4000"}))
      assert cs.valid?
    end
  end

  describe "node CRUD" do
    test "create_node/1 inserts and broadcasts :node_added" do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:cluster")

      assert {:ok, node} = Cluster.create_node(valid_node_attrs(%{name: "alpha"}))
      assert node.name == "alpha"
      assert node.id
      assert_receive {:node_added, %ClusterNode{name: "alpha"}}
    end

    test "create_node/1 returns error changeset for invalid attrs" do
      assert {:error, changeset} = Cluster.create_node(%{name: "x"})
      refute changeset.valid?
    end

    test "create_node/1 enforces unique name" do
      attrs = valid_node_attrs(%{name: "dup", url: "http://a:4000"})
      assert {:ok, _} = Cluster.create_node(attrs)
      assert {:error, cs} = Cluster.create_node(%{attrs | url: "http://b:4000"})
      assert "has already been taken" in errors_on(cs).name
    end

    test "list_nodes/0 returns nodes ordered by name" do
      {:ok, _} = Cluster.create_node(valid_node_attrs(%{name: "zeta"}))
      {:ok, _} = Cluster.create_node(valid_node_attrs(%{name: "beta"}))
      names = Cluster.list_nodes() |> Enum.map(& &1.name)
      assert names == Enum.sort(names)
      assert "beta" in names and "zeta" in names
    end

    test "get_node!/1 and get_node_by_name/1" do
      {:ok, node} = Cluster.create_node(valid_node_attrs(%{name: "findme"}))
      assert Cluster.get_node!(node.id).id == node.id
      assert Cluster.get_node_by_name("findme").id == node.id
      assert Cluster.get_node_by_name("nope") == nil
    end

    test "update_node/2 changes fields" do
      {:ok, node} = Cluster.create_node(valid_node_attrs())
      assert {:ok, updated} = Cluster.update_node(node, %{status: "online"})
      assert updated.status == "online"
    end

    test "delete_node/1 removes and broadcasts :node_removed" do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:cluster")
      {:ok, node} = Cluster.create_node(valid_node_attrs(%{name: "gone"}))

      assert {:ok, _} = Cluster.delete_node(node)
      assert_receive {:node_removed, %ClusterNode{name: "gone"}}
      assert Cluster.get_node_by_name("gone") == nil
    end

    test "touch_node/1 sets status online and last_seen_at" do
      {:ok, node} = Cluster.create_node(valid_node_attrs(%{status: "pending"}))
      assert {:ok, touched} = Cluster.touch_node(node)
      assert touched.status == "online"
      assert touched.last_seen_at
    end

    test "mark_offline/1 sets status offline" do
      {:ok, node} = Cluster.create_node(valid_node_attrs(%{status: "online"}))
      assert {:ok, off} = Cluster.mark_offline(node)
      assert off.status == "offline"
    end
  end

  describe "register_or_update/3" do
    test "creates a node when name is new" do
      assert {:ok, node} =
               Cluster.register_or_update("new-node", "http://new:4000", "k1")

      assert node.status == "online"
      assert node.url == "http://new:4000"
    end

    test "updates url/api_key when name already exists" do
      {:ok, _} =
        Cluster.create_node(valid_node_attrs(%{name: "existing", url: "http://old:4000"}))

      assert {:ok, node} =
               Cluster.register_or_update("existing", "http://updated:4000", "k2")

      assert node.url == "http://updated:4000"
      assert node.api_key == "k2"
      assert node.status == "online"
      # still a single row
      assert length(Enum.filter(Cluster.list_nodes(), &(&1.name == "existing"))) == 1
    end
  end

  describe "export_config/0 and import_config/1 round-trip" do
    setup do
      # Cache.set_upstreams mutates global ETS shared across tests; restore it.
      prev_upstreams = Cache.get_upstreams()
      prev_ttl = Cache.get_ttl()

      on_exit(fn ->
        Cache.set_upstreams(prev_upstreams)
        Cache.set_ttl(prev_ttl)
      end)

      :ok
    end

    test "export returns the expected shape" do
      config = Cluster.export_config()

      assert Map.has_key?(config, :adlists)
      assert Map.has_key?(config, :blocklist_entries)
      assert Map.has_key?(config, :whitelist_entries)
      assert Map.has_key?(config, :local_dns)
      assert is_list(config.upstreams)
      assert is_integer(config.cache_ttl)
    end

    test "export reflects blocklist/whitelist/adlist/local-dns rows in the DB" do
      # Seed each source table directly (bypassing import_config, which is not
      # sandbox-safe — see the note below) and verify export picks them up.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(EliHole.DNS.Adlist, [
        %{
          address: "https://example.com/list.txt",
          enabled: true,
          comment: "c",
          domain_count: 0,
          inserted_at: now,
          updated_at: now
        }
      ])

      Repo.insert_all(EliHole.DNS.BlocklistEntry, [
        %{
          domain: "ads.example.com",
          type: "exact",
          source: "manual",
          enabled: true,
          inserted_at: now,
          updated_at: now
        },
        # gravity-sourced entries must be excluded from export
        %{
          domain: "gravity-only.example.com",
          type: "exact",
          source: "gravity:abc",
          enabled: true,
          inserted_at: now,
          updated_at: now
        }
      ])

      Repo.insert_all(EliHole.DNS.WhitelistEntry, [
        %{
          domain: "good.example.com",
          type: "exact",
          source: "manual",
          enabled: true,
          inserted_at: now,
          updated_at: now
        }
      ])

      Repo.insert_all(EliHole.DNS.LocalRecord, [
        %{
          domain: "router.lan",
          record_type: "A",
          target: "10.0.0.1",
          enabled: true,
          inserted_at: now,
          updated_at: now
        }
      ])

      exported = Cluster.export_config()

      assert Enum.any?(exported.adlists, &(&1.address == "https://example.com/list.txt"))
      assert Enum.any?(exported.blocklist_entries, &(&1.domain == "ads.example.com"))
      refute Enum.any?(exported.blocklist_entries, &(&1.domain == "gravity-only.example.com"))
      assert Enum.any?(exported.whitelist_entries, &(&1.domain == "good.example.com"))
      assert Enum.any?(exported.local_dns, &(&1.domain == "router.lan"))
    end

    test "export reflects upstreams and cache ttl from Cache" do
      Cache.set_upstreams([{{1, 1, 1, 1}, 53}])
      Cache.set_ttl(4242)

      exported = Cluster.export_config()

      assert "1.1.1.1:53" in exported.upstreams
      assert exported.cache_ttl == 4242
    end

    # NOTE: import_config/1 (and therefore receive_config + register_with_master's
    # success path) cannot be exercised under the Ecto SQL sandbox. It wraps the
    # imports in Repo.transaction/1 and, inside that transaction, synchronously
    # calls Blocklist.flush_cache/Whitelist.flush_cache/LocalDNS.flush_cache —
    # each a GenServer.call to a singleton process that issues its own Repo query.
    # In the sandbox there is a single shared connection held by the open
    # transaction, so the cross-process query deadlocks (DBConnection queue
    # timeout). This is structural to the application code and unfixable from the
    # test without editing lib/. The pure decode helpers are covered indirectly
    # via export above; the not-configured / error branches are covered below.
  end

  describe "push_config_to_node/1 (real Req path)" do
    setup do
      prev_upstreams = Cache.get_upstreams()
      on_exit(fn -> Cache.set_upstreams(prev_upstreams) end)
      server = start_echo_server()
      {:ok, server: server}
    end

    test "pushes config, marks node online on 2xx", %{server: server} do
      :persistent_term.put({:cluster_test_default_status}, 200)
      {:ok, node} = Cluster.create_node(valid_node_attrs(%{url: server.base}))

      assert :ok = Cluster.push_config_to_node(node)

      assert_receive {:http_request, req}, 2_000
      assert req.method == "POST"
      assert req.path == "/api/cluster/config"
      assert {"x-cluster-key", node.api_key} in req.headers
      assert Map.has_key?(req.body, "blocklist_entries")

      reloaded = Cluster.get_node!(node.id)
      assert reloaded.status == "online"
    end

    test "marks node offline on non-2xx", %{server: server} do
      :persistent_term.put({:cluster_test_default_status}, 500)
      {:ok, node} = Cluster.create_node(valid_node_attrs(%{url: server.base}))

      assert {:error, "HTTP 500"} = Cluster.push_config_to_node(node)
      assert_receive {:http_request, _}, 2_000

      assert Cluster.get_node!(node.id).status == "offline"
    end

    test "marks node offline when the host is unreachable" do
      :persistent_term.put({:cluster_test_default_status}, 200)
      # Port nobody listens on.
      {:ok, node} = Cluster.create_node(valid_node_attrs(%{url: "http://127.0.0.1:1"}))

      assert {:error, _reason} = Cluster.push_config_to_node(node)
      assert Cluster.get_node!(node.id).status == "offline"
    end
  end

  describe "push_config_to_all/0" do
    setup do
      prev_upstreams = Cache.get_upstreams()
      on_exit(fn -> Cache.set_upstreams(prev_upstreams) end)
      server = start_echo_server()
      {:ok, server: server}
    end

    test "pushes to every node and aggregates results", %{server: server} do
      :persistent_term.put({:cluster_test_default_status}, 200)
      # node urls carry a unique suffix (the url column is unique); the echo
      # server answers any path, and do_push trims/appends so 2xx is returned.
      {:ok, _} = Cluster.create_node(valid_node_attrs(%{name: "a", url: server.base <> "/a"}))
      {:ok, _} = Cluster.create_node(valid_node_attrs(%{name: "b", url: server.base <> "/b"}))

      # push_config_to_all/0 fans out concurrent Req requests. Under full-suite
      # load the shared Finch HTTP/2 pool can transiently report
      # :pool_not_available; that is an environment artifact, not a push failure,
      # so retry a few times until the pool has capacity.
      results = push_all_without_pool_errors()
      assert Enum.all?(results, &(&1 == :ok))
      assert length(results) == 2
    end
  end

  defp push_all_without_pool_errors(attempts \\ 5) do
    results = Cluster.push_config_to_all()

    pool_error? =
      Enum.any?(results, fn
        {:error, %Req.HTTPError{reason: :pool_not_available}} -> true
        _ -> false
      end)

    if pool_error? and attempts > 1 do
      push_all_without_pool_errors(attempts - 1)
    else
      results
    end
  end

  describe "push_stats_to_master/1" do
    setup do
      server = start_echo_server()
      {:ok, server: server}
    end

    test "returns :not_configured when master url/key absent" do
      put_app_env(:cluster_master_url, nil)
      put_app_env(:cluster_api_key, nil)
      assert {:error, :not_configured} = Cluster.push_stats_to_master(%{total: 1})
    end

    test "posts stats payload to master on success", %{server: server} do
      :persistent_term.put({:cluster_test_default_status}, 200)
      put_app_env(:cluster_master_url, server.base)
      put_app_env(:cluster_api_key, "master-key")
      put_app_env(:cluster_instance_name, "slave-7")

      assert :ok = Cluster.push_stats_to_master(%{total: 99})

      assert_receive {:http_request, req}, 2_000
      assert req.path == "/api/cluster/stats"
      assert {"x-cluster-key", "master-key"} in req.headers
      assert req.body["node_name"] == "slave-7"
      assert req.body["stats"]["total"] == 99
    end

    test "returns {:error, HTTP ...} on non-2xx", %{server: server} do
      :persistent_term.put({:cluster_test_default_status}, 403)
      put_app_env(:cluster_master_url, server.base)
      put_app_env(:cluster_api_key, "master-key")

      assert {:error, "HTTP 403"} = Cluster.push_stats_to_master(%{total: 1})
    end
  end

  describe "register_with_master/0" do
    setup do
      on_exit(fn ->
        :persistent_term.erase({:cluster_test_register_status})
        :persistent_term.erase({:cluster_test_register_config})
      end)

      server = start_echo_server()
      {:ok, server: server}
    end

    test "returns :not_configured when not fully configured" do
      put_app_env(:cluster_master_url, nil)
      put_app_env(:cluster_api_key, nil)
      put_app_env(:cluster_instance_url, nil)
      assert {:error, :not_configured} = Cluster.register_with_master()
    end

    test "returns :not_configured when instance_url is missing" do
      put_app_env(:cluster_master_url, "http://master:4000")
      put_app_env(:cluster_api_key, "k")
      put_app_env(:cluster_instance_url, nil)
      assert {:error, :not_configured} = Cluster.register_with_master()
    end

    # The 200/success path imports the returned config, which deadlocks under the
    # sandbox (see import_config note above), so only the error branch — which
    # sends the request but does not import — is asserted here.
    test "sends a register request and returns error on non-200", %{server: server} do
      :persistent_term.put({:cluster_test_register_status}, 401)
      put_app_env(:cluster_master_url, server.base)
      put_app_env(:cluster_api_key, "k")
      put_app_env(:cluster_instance_url, "http://me:4000")
      put_app_env(:cluster_instance_name, "slave-x")

      assert {:error, "HTTP 401"} = Cluster.register_with_master()

      assert_receive {:http_request, req}, 2_000
      assert req.path == "/api/cluster/register"
      assert req.body["name"] == "slave-x"
      assert req.body["url"] == "http://me:4000"
      assert {"x-cluster-key", "k"} in req.headers
    end
  end

  describe "ClusterManager GenServer" do
    setup do
      # ClusterManager is not started in :standalone test env, so we own it.
      pid = start_supervised!(ClusterManager)
      {:ok, manager: pid}
    end

    test "stores and reads back node stats", %{manager: _pid} do
      ClusterManager.receive_stats("node-a", %{total: 5})

      # receive_stats is a cast; flush it with a sync call to the same process.
      :sys.get_state(ClusterManager)

      assert {:ok, %{total: 5}, %DateTime{}} = ClusterManager.get_node_stats("node-a")
      assert :miss = ClusterManager.get_node_stats("unknown")
    end

    test "all_node_stats/0 lists every recorded node" do
      ClusterManager.receive_stats("n1", %{total: 1})
      ClusterManager.receive_stats("n2", %{total: 2})
      :sys.get_state(ClusterManager)

      names = ClusterManager.all_node_stats() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["n1", "n2"]
    end

    test "receiving stats touches a known node and broadcasts :stats_updated" do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:cluster")
      {:ok, node} = Cluster.create_node(valid_node_attrs(%{name: "known", status: "pending"}))

      ClusterManager.receive_stats("known", %{total: 3})

      assert_receive {:stats_updated, "known"}, 2_000
      assert Cluster.get_node!(node.id).status == "online"
    end

    test "a config-change PubSub message schedules a debounced push timer" do
      # Drive the master's PubSub subscription: a blocklist change should arm
      # the debounce timer (push_timer goes from nil to a reference).
      assert %{push_timer: nil} = :sys.get_state(ClusterManager)

      Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:blocklist", :blocklist_changed)

      state = :sys.get_state(ClusterManager)
      assert is_reference(state.push_timer)
    end
  end
end
