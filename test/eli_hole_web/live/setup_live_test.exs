defmodule EliHoleWeb.SetupLiveTest do
  use EliHoleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias EliHole.Accounts

  describe "when no admin exists" do
    test "renders the setup form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      assert has_element?(view, "#setup-form")
      assert has_element?(view, "#setup-form button[type=submit]")
      assert has_element?(view, "input[name='user[username]']")
      assert has_element?(view, "input[name='user[password]']")
    end

    test "validate event surfaces validation errors for short input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html =
        view
        |> form("#setup-form", user: %{username: "ab", password: "short"})
        |> render_change()

      # Errors render inside the form (core_components <.error>); the form is
      # still present and re-rendered with the bad params.
      assert has_element?(view, "#setup-form")
      assert html =~ "should be at least"
    end

    test "successful create redirects to /login and persists the admin", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      uname = "owner_#{System.unique_integer([:positive])}"

      assert {:error, {:live_redirect, %{to: "/login"}}} =
               view
               |> form("#setup-form", user: %{username: uname, password: "supersecret123"})
               |> render_submit()

      assert Accounts.setup_complete?()
      assert {:ok, _admin} = Accounts.authenticate(uname, "supersecret123")
    end

    test "invalid submit re-renders the form with errors and does not create admin", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html =
        view
        |> form("#setup-form", user: %{username: "x", password: "y"})
        |> render_submit()

      assert has_element?(view, "#setup-form")
      assert html =~ "should be at least"
      refute Accounts.setup_complete?()
    end
  end

  describe "when setup is already complete" do
    setup :register_and_log_in_admin

    test "redirects to /login on mount", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, ~p"/setup")
    end
  end
end
