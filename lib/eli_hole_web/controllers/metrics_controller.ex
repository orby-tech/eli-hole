defmodule EliHoleWeb.MetricsController do
  @moduledoc """
  `GET /metrics` — Prometheus text-exposition endpoint (`text/plain; version=0.0.4`).
  """

  use EliHoleWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, EliHole.Metrics.prometheus_text())
  end
end
