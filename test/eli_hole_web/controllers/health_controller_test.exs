defmodule EliHoleWeb.HealthControllerTest do
  use EliHoleWeb.ConnCase, async: false

  test "GET /api/health returns 200 with status ok when healthy", %{conn: conn} do
    conn = get(conn, ~p"/api/health")

    assert %{"status" => "ok", "checks" => checks} = json_response(conn, 200)
    assert checks["database"] == "ok"
    assert checks["dns_server"] == "ok"
  end
end
