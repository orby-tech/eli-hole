defmodule EliHoleWeb.Plugs.RequireAuthTest do
  use EliHoleWeb.ConnCase

  alias EliHoleWeb.Plugs.RequireAuth

  # Builds a session-enabled conn suitable for calling the plug directly.
  defp session_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
  end

  describe "init/1" do
    test "returns opts unchanged" do
      assert RequireAuth.init([]) == []
      assert RequireAuth.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "call/2 when setup is NOT complete" do
    setup do
      # Ensure no env admin is configured so setup_complete? is driven purely
      # by the (empty, sandboxed) AdminUser table.
      prev_username = Application.get_env(:eli_hole, :admin_username)
      prev_password = Application.get_env(:eli_hole, :admin_password)
      Application.put_env(:eli_hole, :admin_username, nil)
      Application.put_env(:eli_hole, :admin_password, nil)

      on_exit(fn ->
        Application.put_env(:eli_hole, :admin_username, prev_username)
        Application.put_env(:eli_hole, :admin_password, prev_password)
      end)

      refute EliHole.Accounts.setup_complete?()
      :ok
    end

    test "redirects to /setup and halts (no session)" do
      conn = RequireAuth.call(session_conn(), [])

      assert redirected_to(conn) == "/setup"
      assert conn.halted
    end

    test "redirects to /setup and halts even with a session admin_user_id" do
      conn =
        session_conn()
        |> Plug.Conn.put_session(:admin_user_id, 1)
        |> RequireAuth.call([])

      assert redirected_to(conn) == "/setup"
      assert conn.halted
    end
  end

  describe "call/2 when setup is complete" do
    setup do
      {:ok, admin} =
        EliHole.Accounts.create_admin(%{
          "username" => "admin_#{System.unique_integer([:positive])}",
          "password" => "supersecret123"
        })

      assert EliHole.Accounts.setup_complete?()
      %{admin: admin}
    end

    test "passes through when admin_user_id is in the session", %{admin: admin} do
      conn =
        session_conn()
        |> Plug.Conn.put_session(:admin_user_id, admin.id)
        |> RequireAuth.call([])

      refute conn.halted
      assert conn.status == nil
    end

    test "redirects to /login and halts when there is no session admin" do
      conn = RequireAuth.call(session_conn(), [])

      assert redirected_to(conn) == "/login"
      assert conn.halted
    end
  end
end
