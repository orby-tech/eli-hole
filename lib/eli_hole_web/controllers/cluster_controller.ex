defmodule EliHoleWeb.ClusterController do
  use EliHoleWeb, :controller

  alias EliHole.DNS.{Cluster, ClusterManager, Gravity}

  require Logger

  def register(conn, %{"name" => name, "url" => url, "api_key" => api_key}) do
    case Cluster.register_or_update(name, url, api_key) do
      {:ok, _node} ->
        config = Cluster.export_config()
        json(conn, %{status: "ok", config: config})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: format_errors(changeset)})
    end
  end

  def register(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "missing required fields: name, url, api_key"})
  end

  def receive_stats(conn, %{"node_name" => node_name, "stats" => stats}) do
    ClusterManager.receive_stats(node_name, stats)
    json(conn, %{status: "ok"})
  end

  def receive_stats(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "missing required fields: node_name, stats"})
  end

  def receive_config(conn, params) do
    if Cluster.slave?() do
      config =
        Map.take(params, ["adlists", "blocklist_entries", "local_dns", "upstreams", "cache_ttl"])

      Cluster.import_config(config)
      Gravity.update_now()
      Logger.info("Config received from master, gravity sync triggered")
      json(conn, %{status: "ok"})
    else
      conn
      |> put_status(403)
      |> json(%{error: "this node is not a slave"})
    end
  end

  def get_config(conn, _params) do
    config = Cluster.export_config()
    json(conn, config)
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_errors(other), do: inspect(other)
end
