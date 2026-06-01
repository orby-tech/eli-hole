defmodule EliHoleWeb.HealthController do
  @moduledoc """
  `GET /api/health` — liveness/readiness probe.

  Returns `200` with `{"status":"ok",...}` when every check passes, or `503`
  with `{"status":"degraded",...}` when any check is down, so orchestrators
  (Docker/k8s) can act on the HTTP status alone.
  """

  use EliHoleWeb, :controller

  alias EliHole.Health

  def index(conn, _params) do
    result = Health.check()
    code = if result.status == :ok, do: 200, else: 503

    conn
    |> put_status(code)
    |> json(result)
  end
end
