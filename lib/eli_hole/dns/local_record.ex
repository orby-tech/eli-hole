defmodule EliHole.DNS.LocalRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "local_dns_records" do
    field :domain, :string
    field :record_type, :string, default: "A"
    field :target, :string
    field :enabled, :boolean, default: true
    field :comment, :string

    timestamps(type: :utc_datetime)
  end

  @valid_types ~w(A AAAA CNAME)

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:domain, :record_type, :target, :enabled, :comment])
    |> validate_required([:domain, :target])
    |> validate_inclusion(:record_type, @valid_types)
    |> normalize_domain()
    |> validate_target()
    |> unique_constraint([:domain, :record_type])
  end

  defp normalize_domain(changeset) do
    case get_change(changeset, :domain) do
      nil -> changeset
      domain -> put_change(changeset, :domain, String.downcase(String.trim(domain)))
    end
  end

  defp validate_target(changeset) do
    type = get_field(changeset, :record_type)
    target = get_field(changeset, :target)

    cond do
      is_nil(target) ->
        changeset

      type == "A" ->
        case :inet.parse_ipv4_address(String.to_charlist(target)) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :target, "must be a valid IPv4 address")
        end

      type == "AAAA" ->
        case :inet.parse_ipv6_address(String.to_charlist(target)) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :target, "must be a valid IPv6 address")
        end

      type == "CNAME" ->
        if String.match?(target, ~r/^[a-zA-Z0-9._-]+$/) do
          changeset
        else
          add_error(changeset, :target, "must be a valid domain name")
        end

      true ->
        changeset
    end
  end
end
