defmodule EliHole.DNS.Cluster do
  import Ecto.Query

  alias EliHole.Repo

  alias EliHole.DNS.{
    Adlist,
    BlocklistEntry,
    ClusterNode,
    Adlists,
    Blocklist,
    LocalDNS,
    LocalRecord,
    Cache,
    Whitelist,
    WhitelistEntry
  }

  require Logger

  def instance_role do
    Application.get_env(:eli_hole, :cluster_role, :standalone)
  end

  def master?, do: instance_role() == :master
  def slave?, do: instance_role() == :slave

  def list_nodes do
    ClusterNode
    |> order_by(asc: :name)
    |> Repo.all()
  end

  def get_node!(id), do: Repo.get!(ClusterNode, id)

  def get_node_by_name(name) do
    Repo.get_by(ClusterNode, name: name)
  end

  def create_node(attrs) do
    result =
      %ClusterNode{}
      |> ClusterNode.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, node} ->
        broadcast(:node_added, node)
        {:ok, node}

      error ->
        error
    end
  end

  def update_node(%ClusterNode{} = node, attrs) do
    node
    |> ClusterNode.changeset(attrs)
    |> Repo.update()
  end

  def delete_node(%ClusterNode{} = node) do
    result = Repo.delete(node)

    case result do
      {:ok, _} ->
        broadcast(:node_removed, node)
        result

      error ->
        error
    end
  end

  def touch_node(%ClusterNode{} = node) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    node
    |> Ecto.Changeset.change(%{last_seen_at: now, status: "online"})
    |> Repo.update()
  end

  def mark_offline(%ClusterNode{} = node) do
    node
    |> Ecto.Changeset.change(%{status: "offline"})
    |> Repo.update()
  end

  def register_or_update(name, url, api_key) do
    case get_node_by_name(name) do
      nil ->
        create_node(%{name: name, url: url, api_key: api_key, status: "online"})

      existing ->
        update_node(existing, %{url: url, api_key: api_key, status: "online"})
    end
  end

  def export_config do
    adlists =
      Adlists.list_all()
      |> Enum.map(fn a ->
        %{address: a.address, enabled: a.enabled, comment: a.comment}
      end)

    blocklist_entries =
      Blocklist.list_enabled()
      |> Enum.reject(fn e -> String.starts_with?(e.source || "", "gravity:") end)
      |> Enum.map(fn e ->
        %{domain: e.domain, type: e.type, source: e.source, comment: e.comment}
      end)

    whitelist_entries =
      Whitelist.list_enabled()
      |> Enum.map(fn e ->
        %{domain: e.domain, type: e.type, source: e.source, comment: e.comment}
      end)

    local_dns =
      LocalDNS.list_all_enabled()
      |> Enum.map(fn r ->
        %{domain: r.domain, record_type: r.record_type, target: r.target}
      end)

    upstreams =
      Cache.get_upstreams()
      |> Enum.map(&Cache.format_upstream/1)

    cache_ttl = Cache.get_ttl()

    %{
      adlists: adlists,
      blocklist_entries: blocklist_entries,
      whitelist_entries: whitelist_entries,
      local_dns: local_dns,
      upstreams: upstreams,
      cache_ttl: cache_ttl
    }
  end

  def import_config(config) when is_map(config) do
    Repo.transaction(fn ->
      import_adlists(config["adlists"] || [])
      import_blocklist_entries(config["blocklist_entries"] || [])
      import_whitelist_entries(config["whitelist_entries"] || [])
      import_local_dns(config["local_dns"] || [])
    end)

    import_upstreams(config["upstreams"] || [])
    import_cache_ttl(config["cache_ttl"])

    :ok
  end

  defp import_adlists(adlists) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.delete_all(Adlist)

    entries =
      Enum.map(adlists, fn a ->
        %{
          address: a["address"],
          enabled: a["enabled"],
          comment: a["comment"],
          domain_count: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    if entries != [] do
      Repo.insert_all(Adlist, entries, on_conflict: :nothing, conflict_target: [:address])
    end
  end

  defp import_blocklist_entries(entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.delete_all(from e in BlocklistEntry, where: not like(e.source, "gravity:%"))

    rows =
      Enum.map(entries, fn e ->
        %{
          domain: e["domain"],
          type: e["type"] || "exact",
          source: e["source"] || "cluster_sync",
          enabled: true,
          comment: e["comment"],
          inserted_at: now,
          updated_at: now
        }
      end)

    rows
    |> Enum.chunk_every(5000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(BlocklistEntry, chunk,
        on_conflict: :nothing,
        conflict_target: [:domain, :type]
      )
    end)

    Blocklist.flush_cache()
  end

  defp import_whitelist_entries(entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.delete_all(WhitelistEntry)

    rows =
      Enum.map(entries, fn e ->
        %{
          domain: e["domain"],
          type: e["type"] || "exact",
          source: e["source"] || "cluster_sync",
          enabled: true,
          comment: e["comment"],
          inserted_at: now,
          updated_at: now
        }
      end)

    rows
    |> Enum.chunk_every(5000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(WhitelistEntry, chunk,
        on_conflict: :nothing,
        conflict_target: [:domain, :type]
      )
    end)

    Whitelist.flush_cache()
  end

  defp import_local_dns(records) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.delete_all(LocalRecord)

    rows =
      Enum.map(records, fn r ->
        %{
          domain: r["domain"],
          record_type: r["record_type"],
          target: r["target"],
          enabled: true,
          comment: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows != [] do
      Repo.insert_all(LocalRecord, rows,
        on_conflict: :nothing,
        conflict_target: [:domain, :record_type]
      )
    end

    LocalDNS.flush_cache()
  end

  defp import_upstreams(upstreams) when is_list(upstreams) do
    parsed =
      Enum.flat_map(upstreams, fn str ->
        case Cache.parse_upstream(str) do
          {:ok, tuple} -> [tuple]
          _ -> []
        end
      end)

    if parsed != [], do: Cache.set_upstreams(parsed)
  end

  defp import_cache_ttl(nil), do: :ok
  defp import_cache_ttl(ttl) when is_integer(ttl), do: Cache.set_ttl(ttl)
  defp import_cache_ttl(_), do: :ok

  def push_config_to_node(%ClusterNode{} = node) do
    config = export_config()

    case do_push(node, "/api/cluster/config", config) do
      :ok ->
        touch_node(node)
        :ok

      {:error, reason} ->
        Logger.warning("Failed to push config to #{node.name}: #{inspect(reason)}")
        mark_offline(node)
        {:error, reason}
    end
  end

  def push_config_to_all do
    nodes = list_nodes()

    Task.async_stream(nodes, &push_config_to_node/1,
      timeout: 10_000,
      max_concurrency: 10
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
    end)
  end

  defp do_push(%ClusterNode{} = node, path, body) do
    url = String.trim_trailing(node.url, "/") <> path

    case Req.post(url,
           json: body,
           headers: [{"x-cluster-key", node.api_key}],
           receive_timeout: 8_000
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def push_stats_to_master(stats) do
    master_url = Application.get_env(:eli_hole, :cluster_master_url)
    api_key = Application.get_env(:eli_hole, :cluster_api_key)
    instance_name = Application.get_env(:eli_hole, :cluster_instance_name, "slave")

    if master_url && api_key do
      url = String.trim_trailing(master_url, "/") <> "/api/cluster/stats"

      payload = %{
        node_name: instance_name,
        stats: stats
      }

      case Req.post(url,
             json: payload,
             headers: [{"x-cluster-key", api_key}],
             receive_timeout: 5_000
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          Logger.warning("Stats push failed: HTTP #{status}")
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          Logger.warning("Stats push failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_configured}
    end
  end

  def register_with_master do
    master_url = Application.get_env(:eli_hole, :cluster_master_url)
    api_key = Application.get_env(:eli_hole, :cluster_api_key)
    instance_name = Application.get_env(:eli_hole, :cluster_instance_name, "slave")
    instance_url = Application.get_env(:eli_hole, :cluster_instance_url)

    if master_url && api_key && instance_url do
      url = String.trim_trailing(master_url, "/") <> "/api/cluster/register"

      payload = %{
        name: instance_name,
        url: instance_url,
        api_key: api_key
      }

      case Req.post(url,
             json: payload,
             headers: [{"x-cluster-key", api_key}],
             receive_timeout: 8_000
           ) do
        {:ok, %{status: 200, body: %{"config" => config}}} ->
          import_config(config)
          Logger.info("Registered with master, config applied")
          :ok

        {:ok, %{status: status}} ->
          Logger.warning("Registration failed: HTTP #{status}")
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          Logger.warning("Registration failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_configured}
    end
  end

  defp broadcast(event, data) do
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:cluster", {event, data})
  end
end
