defmodule EliHole.DNS.Provider do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_providers" do
    field :name, :string
    field :ip, :string
    field :port, :integer, default: 53
    field :enabled, :boolean, default: true
    field :position, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:name, :ip, :port, :enabled, :position])
    |> validate_required([:ip, :port])
    |> validate_number(:port, greater_than: 0, less_than: 65536)
    |> validate_ip()
    |> unique_constraint([:ip, :port])
  end

  defp validate_ip(changeset) do
    validate_change(changeset, :ip, fn :ip, ip_str ->
      case :inet.parse_address(String.to_charlist(ip_str)) do
        {:ok, _} -> []
        {:error, _} -> [ip: "is not a valid IP address"]
      end
    end)
  end

  def to_tuple(%__MODULE__{ip: ip_str, port: port}) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(ip_str))
    {ip, port}
  end
end
