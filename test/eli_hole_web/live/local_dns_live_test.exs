defmodule EliHoleWeb.LocalDNSLiveTest do
  use EliHoleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias EliHole.DNS.LocalDNS

  setup :register_and_log_in_admin

  defp create_record(attrs) do
    {:ok, record} =
      LocalDNS.create_record(
        Map.merge(%{"record_type" => "A", "target" => "192.168.1.10"}, attrs)
      )

    record
  end

  describe "auth" do
    test "unauthenticated visitor is redirected to /login" do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(build_conn(), ~p"/admin/local-dns")
    end
  end

  describe "mount" do
    test "renders the key page elements", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/local-dns")

      assert has_element?(view, "#add-record-form")
      assert has_element?(view, "#local-dns-records")
      assert has_element?(view, "#search-local-dns-form")
      assert has_element?(view, "#add-record-form input[name='local_record[domain]']")
    end

    test "renders existing records seeded via the context", %{conn: conn} do
      record = create_record(%{"domain" => "nas.local"})

      {:ok, view, _html} = live(conn, ~p"/admin/local-dns")

      assert has_element?(view, "#local-dns-records #records-#{record.id}")
    end
  end

  describe "add_record" do
    test "creates a record and shows it in the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/local-dns")

      view
      |> form("#add-record-form",
        local_record: %{domain: "router.local", record_type: "A", target: "192.168.1.1"}
      )
      |> render_submit()

      record = Enum.find(LocalDNS.list_records(), &(&1.domain == "router.local"))
      assert record
      assert has_element?(view, "#records-#{record.id}")
    end

    test "shows validation error for invalid IPv4 target on an A record", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/local-dns")

      html =
        view
        |> form("#add-record-form",
          local_record: %{domain: "bad.local", record_type: "A", target: "not-an-ip"}
        )
        |> render_change()

      assert html =~ "must be a valid IPv4 address"
    end

    test "blank domain does not create a record", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/local-dns")

      view
      |> form("#add-record-form",
        local_record: %{domain: "", record_type: "A", target: "192.168.1.1"}
      )
      |> render_submit()

      assert LocalDNS.list_records() == []
    end
  end

  describe "toggle_record" do
    test "toggles enabled state", %{conn: conn} do
      record = create_record(%{"domain" => "toggle.local"})

      {:ok, view, _html} = live(conn, ~p"/admin/local-dns")

      view
      |> element("#records-#{record.id} button[phx-click='toggle_record']")
      |> render_click()

      refute LocalDNS.get_record!(record.id).enabled
    end
  end

  describe "delete_record" do
    test "removes the record", %{conn: conn} do
      record = create_record(%{"domain" => "delete.local"})

      {:ok, view, _html} = live(conn, ~p"/admin/local-dns")
      assert has_element?(view, "#records-#{record.id}")

      view
      |> element("#records-#{record.id} button[phx-click='delete_record']")
      |> render_click()

      refute has_element?(view, "#records-#{record.id}")
      assert_raise Ecto.NoResultsError, fn -> LocalDNS.get_record!(record.id) end
    end
  end

  describe "search" do
    test "filters the records list", %{conn: conn} do
      kept = create_record(%{"domain" => "keepme.local"})
      gone = create_record(%{"domain" => "other.local"})

      {:ok, view, _html} = live(conn, ~p"/admin/local-dns")

      view
      |> form("#search-local-dns-form", query: "keepme")
      |> render_change()

      assert has_element?(view, "#records-#{kept.id}")
      refute has_element?(view, "#records-#{gone.id}")
    end
  end

  describe "import" do
    test "imports a custom hosts list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/local-dns")

      render_click(view, "toggle_import")
      assert has_element?(view, "#import-local-dns-form")

      view
      |> form("#import-local-dns-form", import_text: "192.168.1.5 imported.local")
      |> render_submit()

      assert Enum.any?(LocalDNS.list_records(), &(&1.domain == "imported.local"))
    end
  end

  describe "flush_cache" do
    test "flush_cache handler runs without error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/local-dns")
      assert render_click(view, "flush_cache") =~ "Local DNS"
    end
  end
end
