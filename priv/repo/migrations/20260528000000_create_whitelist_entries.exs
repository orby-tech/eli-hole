defmodule EliHole.Repo.Migrations.CreateWhitelistEntries do
  use Ecto.Migration

  def change do
    create table(:whitelist_entries) do
      add :domain, :string, null: false
      add :type, :string, null: false, default: "exact"
      add :source, :string
      add :enabled, :boolean, default: true, null: false
      add :comment, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:whitelist_entries, [:domain, :type])
    create index(:whitelist_entries, [:enabled])
  end
end
