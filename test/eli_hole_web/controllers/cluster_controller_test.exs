defmodule EliHoleWeb.ClusterControllerTest do
  use EliHoleWeb.ConnCase, async: false

  alias EliHole.DNS.{Cluster, ClusterManager}

  @api_key "test-cluster-key"

  setup do
    # The ClusterAuth plug compares against :cluster_api_key; set it for the
    # duration of each test and restore the previous value afterwards.
    prev = Application.fetch_env(:eli_hole, :cluster_api_key)
    Application.put_env(:eli_hole, :cluster_api_key, @api_key)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:eli_hole, :cluster_api_key, v)
        :error -> Application.delete_env(:eli_hole, :cluster_api_key)
      end
    end)

    :ok
  end

  defp auth_conn(conn) do
    conn
    |> put_req_header("x-cluster-key", @api_key)
    |> put_req_header("content-type", "application/json")
  end

  describe "ClusterAuth plug" do
    test "rejects request with no api key header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/cluster/stats", %{node_name: "n", stats: %{}})

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "rejects request with wrong api key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cluster-key", "wrong-key")
        |> post(~p"/api/cluster/stats", %{node_name: "n", stats: %{}})

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "passes request with the correct api key", %{conn: conn} do
      conn = post(auth_conn(conn), ~p"/api/cluster/stats", %{node_name: "n", stats: %{}})
      assert json_response(conn, 200) == %{"status" => "ok"}
    end

    test "returns 503 when cluster api key is not configured", %{conn: conn} do
      Application.delete_env(:eli_hole, :cluster_api_key)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cluster-key", "anything")
        |> post(~p"/api/cluster/stats", %{node_name: "n", stats: %{}})

      assert json_response(conn, 503) == %{"error" => "cluster not configured"}
    end
  end

  describe "POST /api/cluster/register" do
    test "registers a new node and returns the exported config", %{conn: conn} do
      params = %{name: "edge-1", url: "http://edge-1:4000", api_key: "node-secret"}
      conn = post(auth_conn(conn), ~p"/api/cluster/register", params)

      assert %{"status" => "ok", "config" => config} = json_response(conn, 200)
      assert Map.has_key?(config, "blocklist_entries")
      assert Map.has_key?(config, "whitelist_entries")
      assert Map.has_key?(config, "adlists")
      assert Map.has_key?(config, "upstreams")

      node = Cluster.get_node_by_name("edge-1")
      assert node.url == "http://edge-1:4000"
      assert node.status == "online"
    end

    test "updates an existing node on re-registration", %{conn: conn} do
      {:ok, _} =
        Cluster.create_node(%{name: "edge-2", url: "http://old:4000", api_key: "k"})

      params = %{name: "edge-2", url: "http://new:4000", api_key: "k2"}
      conn = post(auth_conn(conn), ~p"/api/cluster/register", params)

      assert %{"status" => "ok"} = json_response(conn, 200)
      node = Cluster.get_node_by_name("edge-2")
      assert node.url == "http://new:4000"
      assert node.api_key == "k2"
    end

    test "returns 422 when the node url is invalid", %{conn: conn} do
      params = %{name: "bad", url: "not-a-url", api_key: "k"}
      conn = post(auth_conn(conn), ~p"/api/cluster/register", params)

      assert %{"error" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "url")
    end

    test "returns 400 when required fields are missing", %{conn: conn} do
      conn = post(auth_conn(conn), ~p"/api/cluster/register", %{name: "only-name"})
      assert %{"error" => _} = json_response(conn, 400)
    end

    test "requires auth", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/cluster/register", %{name: "x", url: "http://x:1", api_key: "k"})

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/cluster/stats" do
    setup do
      # ClusterManager is not started in :standalone test env. Start it so the
      # stats cast is delivered (it touches the node row + broadcasts).
      start_supervised!(ClusterManager)
      :ok
    end

    test "accepts stats and records them for a known node", %{conn: conn} do
      {:ok, node} =
        Cluster.create_node(%{
          name: "slave-9",
          url: "http://s9:4000",
          api_key: "k",
          status: "pending"
        })

      conn =
        post(auth_conn(conn), ~p"/api/cluster/stats", %{
          node_name: "slave-9",
          stats: %{total: 42, blocked: 5}
        })

      assert json_response(conn, 200) == %{"status" => "ok"}

      # Flush the async cast through the manager, then assert side effects.
      :sys.get_state(ClusterManager)
      assert {:ok, %{"total" => 42}, %DateTime{}} = ClusterManager.get_node_stats("slave-9")
      assert Cluster.get_node!(node.id).status == "online"
    end

    test "returns 400 when fields are missing", %{conn: conn} do
      conn = post(auth_conn(conn), ~p"/api/cluster/stats", %{node_name: "x"})
      assert %{"error" => _} = json_response(conn, 400)
    end

    test "requires auth", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/cluster/stats", %{node_name: "x", stats: %{}})

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/cluster/config (receive_config)" do
    test "rejects with 403 when the node is not a slave", %{conn: conn} do
      # Default role is :standalone (not slave), so import is never attempted.
      conn =
        post(auth_conn(conn), ~p"/api/cluster/config", %{
          "blocklist_entries" => [%{"domain" => "x.com", "type" => "exact"}]
        })

      assert json_response(conn, 403) == %{"error" => "this node is not a slave"}
    end

    test "requires auth", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/cluster/config", %{})

      assert json_response(conn, 401)
    end

    # NOTE: the slave success path calls Cluster.import_config/1, which deadlocks
    # under the Ecto SQL sandbox (Repo.transaction wrapping a synchronous
    # GenServer.call to Blocklist/Whitelist/LocalDNS that issues its own query on
    # the single shared sandbox connection). It is covered structurally by the
    # 403 guard above and the export-side assertions in cluster_test.exs.
  end

  describe "GET /api/cluster/config (get_config)" do
    test "returns the exported config as JSON", %{conn: conn} do
      conn = get(auth_conn(conn), ~p"/api/cluster/config")

      body = json_response(conn, 200)
      assert Map.has_key?(body, "blocklist_entries")
      assert Map.has_key?(body, "whitelist_entries")
      assert Map.has_key?(body, "adlists")
      assert Map.has_key?(body, "local_dns")
      assert Map.has_key?(body, "upstreams")
      assert Map.has_key?(body, "cache_ttl")
    end

    test "requires auth", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> get(~p"/api/cluster/config")

      assert json_response(conn, 401)
    end
  end
end
