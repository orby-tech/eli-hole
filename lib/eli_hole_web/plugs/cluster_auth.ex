defmodule EliHoleWeb.Plugs.ClusterAuth do
  @moduledoc """
  Authenticates cluster API requests via X-Cluster-Key header.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected_key = Application.get_env(:eli_hole, :cluster_api_key)

    if expected_key do
      provided_key = get_req_header(conn, "x-cluster-key") |> List.first()

      if provided_key && Plug.Crypto.secure_compare(provided_key, expected_key) do
        conn
      else
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
      end
    else
      conn
      |> put_status(503)
      |> Phoenix.Controller.json(%{error: "cluster not configured"})
      |> halt()
    end
  end
end
