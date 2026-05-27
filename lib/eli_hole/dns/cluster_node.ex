defmodule EliHole.DNS.ClusterNode do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cluster_nodes" do
    field :name, :string
    field :url, :string
    field :api_key, :string
    field :status, :string, default: "pending"
    field :last_seen_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:name, :url, :api_key, :status, :last_seen_at])
    |> validate_required([:name, :url, :api_key])
    |> validate_format(:url, ~r/^https?:\/\//, message: "must be an HTTP(S) URL")
    |> unique_constraint(:url)
    |> unique_constraint(:name)
  end
end
