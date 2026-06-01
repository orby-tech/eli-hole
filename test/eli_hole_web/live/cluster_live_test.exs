defmodule EliHoleWeb.ClusterLiveTest do
  use EliHoleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias EliHole.DNS.{Cluster, ClusterManager}

  setup :register_and_log_in_admin

  setup do
    # The cluster LiveView fires config/stats pushes as detached
    # EliHole.TaskSupervisor children (export_config → Req → mark_offline).
    # Those tasks hit the DB; if they outlive the test's sandbox owner they
    # crash on a checked-in connection and can flake an unrelated concurrent
    # test. Drain them while the (shared, async:false) sandbox is still open.
    on_exit(&drain_task_supervisor/0)
    :ok
  end

  defp drain_task_supervisor do
    EliHole.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  describe "auth" do
    test "unauthenticated visitor is redirected to /login" do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(build_conn(), ~p"/admin/cluster")
    end
  end

  describe "standalone role (default in test env)" do
    test "renders the standalone view and no add-node form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/cluster")

      assert has_element?(view, "h1", "Cluster")
      assert render(view) =~ "Standalone Mode"
      refute has_element?(view, "#add-node-form")
    end
  end

  describe "master role" do
    setup do
      previous = Application.get_env(:eli_hole, :cluster_role)
      Application.put_env(:eli_hole, :cluster_role, :master)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:eli_hole, :cluster_role)
          val -> Application.put_env(:eli_hole, :cluster_role, val)
        end
      end)

      # ClusterManager is only started by the app in master mode; in test env
      # the role is standalone, so start it here for the master-view code path
      # (its named ETS stats table backs the dashboard).
      start_supervised!(ClusterManager)

      :ok
    end

    test "renders the master controls and empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/cluster")

      assert has_element?(view, "button[phx-click='toggle_add_form']")
      assert has_element?(view, "button[phx-click='push_all']")
      assert render(view) =~ "No slave nodes registered yet"
    end

    test "toggling the add form reveals the node form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/cluster")

      refute has_element?(view, "#add-node-form")
      render_click(view, "toggle_add_form")
      assert has_element?(view, "#add-node-form")
    end

    test "add_node creates a node and lists it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/cluster")

      render_click(view, "toggle_add_form")

      view
      |> form("#add-node-form",
        node: %{name: "slave-1", url: "http://slave-1:4000", api_key: "secret"}
      )
      |> render_submit()

      assert Enum.any?(Cluster.list_nodes(), &(&1.name == "slave-1"))
      assert render(view) =~ "slave-1"
      assert render(view) =~ "http://slave-1:4000"
    end

    test "add_node with an invalid url keeps the form and creates nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/cluster")

      render_click(view, "toggle_add_form")

      view
      |> form("#add-node-form",
        node: %{name: "bad", url: "not-a-url", api_key: "secret"}
      )
      |> render_submit()

      assert Cluster.list_nodes() == []
      assert has_element?(view, "#add-node-form")
    end

    test "delete_node removes a node", %{conn: conn} do
      {:ok, node} =
        Cluster.create_node(%{
          "name" => "removable",
          "url" => "http://removable:4000",
          "api_key" => "secret"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/cluster")
      assert render(view) =~ "removable"

      view
      |> element("button[phx-click='delete_node'][phx-value-id='#{node.id}']")
      |> render_click()

      assert Cluster.list_nodes() == []
    end

    test "push_config and push_all handlers run without error", %{conn: conn} do
      {:ok, node} =
        Cluster.create_node(%{
          "name" => "pushable",
          "url" => "http://pushable:4000",
          "api_key" => "secret"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/cluster")

      assert view
             |> element("button[phx-click='push_config'][phx-value-id='#{node.id}']")
             |> render_click() =~ "Config push"

      assert render_click(view, "push_all") =~ "Config push to all nodes initiated"
    end
  end
end
