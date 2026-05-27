defmodule EliHole.DNS.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_settings" do
    field :key, :string
    field :value, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
    |> unique_constraint(:key)
  end
end
