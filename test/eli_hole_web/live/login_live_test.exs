defmodule EliHoleWeb.LoginLiveTest do
  use EliHoleWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "when setup is not complete (no admin)" do
    test "redirects to /setup on mount", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/setup"}}} = live(conn, ~p"/login")
    end
  end

  describe "when an admin exists" do
    setup do
      {:ok, admin} =
        EliHole.Accounts.create_admin(%{
          "username" => "admin_#{System.unique_integer([:positive])}",
          "password" => "supersecret123"
        })

      %{admin: admin}
    end

    test "renders the login form posting to /login", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/login")

      assert has_element?(view, "#login-form")
      assert has_element?(view, "#login-form[action='/login'][method='post']")
      assert has_element?(view, "input[name='user[username]']")
      assert has_element?(view, "input[name='user[password]']")
      assert has_element?(view, "#login-form button[type=submit]")
    end

    test "authenticated user is redirected away from /login by the pipeline", %{
      conn: conn,
      admin: admin
    } do
      conn = log_in_admin(conn, admin)
      # redirect_if_authed plug pushes authed users to the dashboard.
      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/login")
      assert redirect_to in ["/admin", "/admin/"]
    end
  end
end
