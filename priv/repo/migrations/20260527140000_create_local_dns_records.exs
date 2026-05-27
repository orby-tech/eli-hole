defmodule EliHole.Repo.Migrations.CreateLocalDnsRecords do
  use Ecto.Migration

  def change do
    create table(:local_dns_records) do
      add :domain, :string, null: false
      add :record_type, :string, null: false, default: "A"
      add :target, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :comment, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:local_dns_records, [:domain, :record_type])
    create index(:local_dns_records, [:enabled])
  end
end
