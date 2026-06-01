defmodule EliHoleWeb.QueryLogLiveTest do
  use EliHoleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EliHole.DNS.QueryLog

  defp log_query(attrs) do
    entry =
      Map.merge(
        %{
          id: System.unique_integer([:positive]),
          time: "12:00:00",
          client: "10.0.0.1",
          domain: "example.com",
          type: :A,
          upstream: "1.1.1.1:53",
          duration_ms: 5,
          status: :ok,
          dnssec: nil,
          transport: :udp
        },
        attrs
      )

    QueryLog.log(entry)
    _ = :sys.get_state(QueryLog)
    entry
  end

  setup do
    # QueryLog is an app-wide ETS singleton the SQL sandbox does not roll back,
    # so clear both before and after to avoid leaking entries into other files.
    QueryLog.clear()
    _ = :sys.get_state(QueryLog)
    on_exit(fn -> QueryLog.clear() end)
    :ok
  end

  describe "authentication" do
    test "redirects to /login when not authenticated", %{conn: conn} do
      {:ok, _admin} =
        EliHole.Accounts.create_admin(%{
          "username" => "existing_admin",
          "password" => "supersecret123"
        })

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/admin/queries")
    end
  end

  describe "mount and render" do
    setup :register_and_log_in_admin

    test "renders the heading, table and clear button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/queries")

      assert has_element?(view, "h1", "Query Log")
      assert has_element?(view, "#queries")
      assert has_element?(view, "button[phx-click='clear']")
    end

    test "renders previously logged queries on mount", %{conn: conn} do
      entry = log_query(%{domain: "seeded.example.com", status: :blocked})

      {:ok, view, _html} = live(conn, "/admin/queries")

      assert has_element?(view, "#queries-#{entry.id}")
      assert has_element?(view, "#queries-#{entry.id} td", "seeded.example.com")
    end
  end

  describe "live streaming" do
    setup :register_and_log_in_admin

    test "inserts a new query pushed over PubSub after mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/queries")

      entry = log_query(%{domain: "live.example.com", status: :ok})

      # Force the LiveView process to handle the broadcast before asserting.
      _ = render(view)

      assert has_element?(view, "#queries-#{entry.id}")
      assert has_element?(view, "#queries-#{entry.id} td", "live.example.com")
    end
  end

  describe "clear" do
    setup :register_and_log_in_admin

    test "clear removes streamed queries", %{conn: conn} do
      entry = log_query(%{domain: "clearme.example.com"})

      {:ok, view, _html} = live(conn, "/admin/queries")
      assert has_element?(view, "#queries-#{entry.id}")

      view |> element("button[phx-click='clear']") |> render_click()

      refute has_element?(view, "#queries-#{entry.id}")
      assert QueryLog.recent(200) == []
    end
  end
end
