defmodule EliHole.Repo.Migrations.CreateBlocklistEntries do
  use Ecto.Migration

  def change do
    create table(:blocklist_entries) do
      add :domain, :string, null: false
      add :type, :string, null: false, default: "exact"
      add :source, :string
      add :enabled, :boolean, default: true, null: false
      add :comment, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:blocklist_entries, [:domain, :type])
    create index(:blocklist_entries, [:enabled])
  end
end
