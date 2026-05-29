defmodule EliHole.DNS.WhitelistEntry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "whitelist_entries" do
    field :domain, :string
    field :type, :string, default: "exact"
    field :source, :string
    field :enabled, :boolean, default: true
    field :comment, :string

    timestamps(type: :utc_datetime)
  end

  @valid_types ~w(exact wildcard regex)

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:domain, :type, :source, :enabled, :comment])
    |> validate_required([:domain])
    |> validate_inclusion(:type, @valid_types)
    |> normalize_domain()
    |> validate_regex_pattern()
    |> unique_constraint([:domain, :type])
  end

  defp normalize_domain(changeset) do
    case get_change(changeset, :domain) do
      nil -> changeset
      domain -> put_change(changeset, :domain, String.downcase(String.trim(domain)))
    end
  end

  defp validate_regex_pattern(changeset) do
    if get_field(changeset, :type) == "regex" do
      case get_field(changeset, :domain) do
        nil ->
          changeset

        pattern ->
          case Regex.compile(pattern) do
            {:ok, _} -> changeset
            {:error, _} -> add_error(changeset, :domain, "is not a valid regex pattern")
          end
      end
    else
      changeset
    end
  end
end
