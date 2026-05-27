defmodule EliHole.Repo.Migrations.CreateDnsProviders do
  use Ecto.Migration

  def change do
    create table(:dns_providers) do
      add :name, :string
      add :ip, :string, null: false
      add :port, :integer, null: false, default: 53
      add :enabled, :boolean, null: false, default: true
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dns_providers, [:ip, :port])
  end
end
