defmodule EliHole.Repo.Migrations.CreateDnsSettings do
  use Ecto.Migration

  def change do
    create table(:dns_settings) do
      add :key, :string, null: false
      add :value, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dns_settings, [:key])
  end
end
