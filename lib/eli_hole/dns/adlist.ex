defmodule EliHole.DNS.Adlist do
  use Ecto.Schema
  import Ecto.Changeset

  schema "adlists" do
    field :address, :string
    field :enabled, :boolean, default: true
    field :comment, :string
    field :domain_count, :integer, default: 0
    field :last_updated_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(adlist, attrs) do
    adlist
    |> cast(attrs, [:address, :enabled, :comment])
    |> validate_required([:address])
    |> validate_format(:address, ~r/^https?:\/\//, message: "must be an HTTP(S) URL")
    |> unique_constraint(:address)
  end
end
