defmodule EliHoleWeb.SessionControllerTest do
  use EliHoleWeb.ConnCase

  alias EliHole.Accounts

  @password "supersecret123"

  defp create_admin do
    username = "admin_#{System.unique_integer([:positive])}"

    {:ok, admin} =
      Accounts.create_admin(%{
        "username" => username,
        "password" => @password
      })

    {admin, username}
  end

  describe "POST /login (create)" do
    test "with valid credentials sets the session and redirects to /admin", %{conn: conn} do
      {admin, username} = create_admin()

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"username" => username, "password" => @password}
        })

      assert get_session(conn, :admin_user_id) == admin.id
      assert redirected_to(conn) == "/admin"
    end

    test "with invalid password flashes an error and redirects to /login", %{conn: conn} do
      {_admin, username} = create_admin()

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"username" => username, "password" => "wrong-password"}
        })

      assert is_nil(get_session(conn, :admin_user_id))
      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
    end

    test "with unknown username flashes an error and redirects to /login", %{conn: conn} do
      # An admin must exist so setup is complete and the /login route is reachable.
      create_admin()

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"username" => "does-not-exist", "password" => @password}
        })

      assert is_nil(get_session(conn, :admin_user_id))
      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
    end

    test "redirects already-authed users away from /login without creating a session", %{
      conn: conn
    } do
      {admin, _username} = create_admin()

      conn =
        conn
        |> log_in_admin(admin)
        |> post(~p"/login", %{
          "user" => %{"username" => "anything", "password" => "anything"}
        })

      # redirect_if_authed pipeline bounces logged-in users to /admin.
      assert redirected_to(conn) == "/admin"
    end
  end

  describe "DELETE /logout (delete)" do
    test "clears the session and redirects to /login", %{conn: conn} do
      {admin, _username} = create_admin()

      conn =
        conn
        |> log_in_admin(admin)
        |> delete(~p"/logout")

      assert is_nil(get_session(conn, :admin_user_id))
      assert redirected_to(conn) == "/login"
    end

    test "redirects to /login even when there was no session", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> delete(~p"/logout")

      assert is_nil(get_session(conn, :admin_user_id))
      assert redirected_to(conn) == "/login"
    end
  end
end
