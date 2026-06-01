defmodule EliHoleWeb.Plugs.RedirectIfAuthedTest do
  use EliHoleWeb.ConnCase

  alias EliHoleWeb.Plugs.RedirectIfAuthed

  defp session_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
  end

  describe "init/1" do
    test "returns opts unchanged" do
      assert RedirectIfAuthed.init([]) == []
      assert RedirectIfAuthed.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "call/2" do
    test "redirects to /admin and halts when authed" do
      conn =
        session_conn()
        |> Plug.Conn.put_session(:admin_user_id, 42)
        |> RedirectIfAuthed.call([])

      assert redirected_to(conn) == "/admin"
      assert conn.halted
    end

    test "passes through when not authed" do
      conn = RedirectIfAuthed.call(session_conn(), [])

      refute conn.halted
      assert conn.status == nil
    end
  end
end
