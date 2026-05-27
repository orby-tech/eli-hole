defmodule EliHole.Repo.Migrations.CreateClusterNodes do
  use Ecto.Migration

  def change do
    create table(:cluster_nodes) do
      add :name, :string, null: false
      add :url, :string, null: false
      add :api_key, :string, null: false
      add :status, :string, default: "pending"
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cluster_nodes, [:url])
    create unique_index(:cluster_nodes, [:name])
  end
end
