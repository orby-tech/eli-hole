defmodule EliHoleWeb.BlocklistLiveTest do
  use EliHoleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias EliHole.DNS.Blocklist

  setup :register_and_log_in_admin

  defp create_entry(attrs) do
    {:ok, entry} =
      Blocklist.create_entry(Map.merge(%{"type" => "exact", "source" => "manual"}, attrs))

    entry
  end

  describe "auth" do
    test "unauthenticated visitor is redirected to /login" do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(build_conn(), ~p"/admin/blocklist")
    end
  end

  describe "mount" do
    test "renders the key page elements", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/blocklist")

      assert has_element?(view, "#add-entry-form")
      assert has_element?(view, "#blocklist-entries")
      assert has_element?(view, "#search-form")
      assert has_element?(view, "#add-entry-form input[name='blocklist_entry[domain]']")
    end

    test "renders existing entries seeded via the context", %{conn: conn} do
      entry = create_entry(%{"domain" => "ads.example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/blocklist")

      assert has_element?(view, "#blocklist-entries #entries-#{entry.id}")
    end
  end

  describe "add_entry" do
    test "creates an entry and shows it in the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/blocklist")

      view
      |> form("#add-entry-form", blocklist_entry: %{domain: "tracker.example.com", type: "exact"})
      |> render_submit()

      entry = Enum.find(Blocklist.list_entries(), &(&1.domain == "tracker.example.com"))
      assert entry
      assert has_element?(view, "#entries-#{entry.id}")
    end

    test "shows validation error when domain is blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/blocklist")

      html =
        view
        |> form("#add-entry-form", blocklist_entry: %{domain: "", type: "exact"})
        |> render_change()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "invalid regex pattern does not create an entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/blocklist")

      view
      |> form("#add-entry-form", blocklist_entry: %{domain: "([", type: "regex"})
      |> render_submit()

      refute Enum.any?(Blocklist.list_entries(), &(&1.domain == "(["))
    end
  end

  describe "toggle_entry" do
    test "toggles enabled state", %{conn: conn} do
      entry = create_entry(%{"domain" => "toggle.example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/blocklist")

      view
      |> element("#entries-#{entry.id} button[phx-click='toggle_entry']")
      |> render_click()

      refute Blocklist.get_entry!(entry.id).enabled
    end
  end

  describe "delete_entry" do
    test "removes the entry", %{conn: conn} do
      entry = create_entry(%{"domain" => "delete.example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/blocklist")
      assert has_element?(view, "#entries-#{entry.id}")

      view
      |> element("#entries-#{entry.id} button[phx-click='delete_entry']")
      |> render_click()

      refute has_element?(view, "#entries-#{entry.id}")
      assert_raise Ecto.NoResultsError, fn -> Blocklist.get_entry!(entry.id) end
    end
  end

  describe "search" do
    test "filters the entries list", %{conn: conn} do
      kept = create_entry(%{"domain" => "keepme.example.com"})
      gone = create_entry(%{"domain" => "other.example.org"})

      {:ok, view, _html} = live(conn, ~p"/admin/blocklist")

      view
      |> form("#search-form", query: "keepme")
      |> render_change()

      assert has_element?(view, "#entries-#{kept.id}")
      refute has_element?(view, "#entries-#{gone.id}")
    end
  end

  describe "import" do
    test "imports a domain list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/blocklist")

      render_click(view, "toggle_import")
      assert has_element?(view, "#import-form")

      view
      |> form("#import-form", import_text: "a.import.test\nb.import.test")
      |> render_submit()

      domains = Enum.map(Blocklist.list_entries(), & &1.domain)
      assert "a.import.test" in domains
      assert "b.import.test" in domains
    end
  end

  describe "flush_cache" do
    test "flush_cache handler runs without error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/blocklist")
      assert render_click(view, "flush_cache") =~ "Blocklist"
    end
  end
end
