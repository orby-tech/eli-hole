defmodule EliHole.DNS.Providers do
  import Ecto.Query

  alias EliHole.Repo
  alias EliHole.DNS.{Cache, Provider}

  def list_enabled do
    Provider
    |> where(enabled: true)
    |> order_by(:position)
    |> Repo.all()
  end

  def list_all do
    Provider
    |> order_by(:position)
    |> Repo.all()
  end

  def get!(id), do: Repo.get!(Provider, id)

  def create(attrs) do
    max_pos =
      Repo.one(from p in Provider, select: max(p.position)) || 0

    %Provider{}
    |> Provider.changeset(Map.put(attrs, "position", max_pos + 1))
    |> Repo.insert()
  end

  def update(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> Repo.update()
  end

  def delete(%Provider{} = provider) do
    Repo.delete(provider)
  end

  def to_tuples(providers) do
    Enum.map(providers, &Provider.to_tuple/1)
  end

  def seed_defaults do
    defaults = [
      %{"name" => "Google 1", "ip" => "8.8.8.8", "port" => 53, "position" => 1},
      %{"name" => "Google 2", "ip" => "8.8.4.4", "port" => 53, "position" => 2}
    ]

    Enum.each(defaults, fn attrs ->
      %Provider{}
      |> Provider.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:ip, :port])
    end)
  end

  def toggle_preset(preset_name) do
    presets = Cache.presets()

    case Map.get(presets, preset_name) do
      nil ->
        {:error, :unknown_preset}

      servers ->
        existing = list_all()
        existing_tuples = MapSet.new(Enum.map(existing, fn p -> {p.ip, p.port} end))

        preset_tuples =
          Enum.map(servers, fn {ip, port} ->
            {to_string(:inet.ntoa(ip)), port}
          end)

        all_present? = Enum.all?(preset_tuples, &MapSet.member?(existing_tuples, &1))

        Repo.transaction(fn ->
          if all_present? do
            remaining =
              Enum.reject(existing, fn p ->
                {p.ip, p.port} in preset_tuples
              end)

            if remaining == [] do
              :noop
            else
              Enum.each(existing, fn p ->
                if {p.ip, p.port} in preset_tuples, do: delete(p)
              end)
            end
          else
            preset_tuples
            |> Enum.with_index(1)
            |> Enum.each(fn {{ip_str, port}, idx} ->
              unless MapSet.member?(existing_tuples, {ip_str, port}) do
                max_pos = Repo.one(from p in Provider, select: max(p.position)) || 0

                %Provider{}
                |> Provider.changeset(%{
                  "name" => "#{String.capitalize(preset_name)} #{idx}",
                  "ip" => ip_str,
                  "port" => port,
                  "position" => max_pos + 1
                })
                |> Repo.insert(on_conflict: :nothing, conflict_target: [:ip, :port])
              end
            end)
          end
        end)
    end
  end
end
