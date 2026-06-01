defmodule EliHoleWeb.GravityLiveTest do
  use EliHoleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias EliHole.DNS.Adlists

  setup :register_and_log_in_admin

  defp create_adlist(attrs) do
    {:ok, adlist} = Adlists.create(attrs)
    adlist
  end

  describe "auth" do
    test "unauthenticated visitor is redirected to /login" do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(build_conn(), ~p"/admin/gravity")
    end
  end

  describe "mount" do
    test "renders the key page elements", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/gravity")

      assert has_element?(view, "#add-adlist-form")
      assert has_element?(view, "#adlists")
      assert has_element?(view, "#add-adlist-form input[name='adlist[address]']")
    end

    test "renders existing adlists seeded via the context", %{conn: conn} do
      adlist = create_adlist(%{"address" => "https://example.com/hosts.txt"})

      {:ok, view, _html} = live(conn, ~p"/admin/gravity")

      assert has_element?(view, "#adlists #adlists-#{adlist.id}")
    end
  end

  describe "add_adlist" do
    test "creates an adlist and shows it in the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/gravity")

      view
      |> form("#add-adlist-form", adlist: %{address: "https://lists.example.com/a.txt"})
      |> render_submit()

      adlist = Enum.find(Adlists.list_all(), &(&1.address == "https://lists.example.com/a.txt"))
      assert adlist
      assert has_element?(view, "#adlists-#{adlist.id}")
    end

    test "shows validation error for a non-URL address", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/gravity")

      html =
        view
        |> form("#add-adlist-form", adlist: %{address: "not-a-url"})
        |> render_change()

      assert html =~ "must be an HTTP(S) URL"
    end

    test "blank address does not create an adlist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/gravity")

      view
      |> form("#add-adlist-form", adlist: %{address: ""})
      |> render_submit()

      assert Adlists.list_all() == []
    end
  end

  describe "toggle_adlist" do
    test "toggles enabled state", %{conn: conn} do
      adlist = create_adlist(%{"address" => "https://example.com/toggle.txt"})

      {:ok, view, _html} = live(conn, ~p"/admin/gravity")

      view
      |> element("#adlists-#{adlist.id} button[phx-click='toggle_adlist']")
      |> render_click()

      refute Adlists.get!(adlist.id).enabled
    end
  end

  describe "delete_adlist" do
    test "removes the adlist", %{conn: conn} do
      adlist = create_adlist(%{"address" => "https://example.com/delete.txt"})

      {:ok, view, _html} = live(conn, ~p"/admin/gravity")
      assert has_element?(view, "#adlists-#{adlist.id}")

      view
      |> element("#adlists-#{adlist.id} button[phx-click='delete_adlist']")
      |> render_click()

      refute has_element?(view, "#adlists-#{adlist.id}")
      assert_raise Ecto.NoResultsError, fn -> Adlists.get!(adlist.id) end
    end
  end

  describe "update_gravity" do
    test "triggering an update flashes a message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/gravity")

      assert render_click(view, "update_gravity") =~ "Gravity update started"
    end
  end
end
