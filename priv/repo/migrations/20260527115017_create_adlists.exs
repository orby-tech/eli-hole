defmodule EliHole.Repo.Migrations.CreateAdlists do
  use Ecto.Migration

  def change do
    create table(:adlists) do
      add :address, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :comment, :string
      add :domain_count, :integer, default: 0
      add :last_updated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:adlists, [:address])
  end
end
