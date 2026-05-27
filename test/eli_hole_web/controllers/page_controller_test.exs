defmodule EliHoleWeb.PageControllerTest do
  use EliHoleWeb.ConnCase

  test "GET / redirects to admin", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/admin"
  end
end
