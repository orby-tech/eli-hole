defmodule EliHoleWeb.MetricsControllerTest do
  use EliHoleWeb.ConnCase, async: false

  test "GET /metrics serves Prometheus text exposition", %{conn: conn} do
    conn = get(conn, ~p"/metrics")

    assert response(conn, 200) =~ "elihole_dns_queries"

    [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain"
    assert content_type =~ "version=0.0.4"
  end
end
