defmodule EliHole.DNS.Adlists do
  import Ecto.Query

  alias EliHole.Repo
  alias EliHole.DNS.{Adlist, Blocklist, BlocklistEntry}

  def list_all do
    Adlist
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def list_enabled do
    Adlist
    |> where(enabled: true)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def get!(id), do: Repo.get!(Adlist, id)

  def create(attrs) do
    result =
      %Adlist{}
      |> Adlist.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, _} -> broadcast_change()
      _ -> :ok
    end

    result
  end

  def update(%Adlist{} = adlist, attrs) do
    result =
      adlist
      |> Adlist.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, _} -> broadcast_change()
      _ -> :ok
    end

    result
  end

  def delete(%Adlist{} = adlist) do
    source = "gravity:#{adlist.id}"
    Repo.delete_all(from e in BlocklistEntry, where: e.source == ^source)
    result = Repo.delete(adlist)
    Blocklist.flush_cache()
    broadcast_change()
    result
  end

  def update_stats(%Adlist{} = adlist, domain_count) do
    adlist
    |> Ecto.Changeset.change(%{
      domain_count: domain_count,
      last_updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  def stats do
    total = Repo.one(from a in Adlist, select: count(a.id))
    enabled = Repo.one(from a in Adlist, select: count(a.id), where: a.enabled == true)

    domains =
      Repo.one(
        from a in Adlist, select: coalesce(sum(a.domain_count), 0), where: a.enabled == true
      )

    %{total: total, enabled: enabled, total_domains: domains}
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:adlists", :adlists_changed)
  end
end
