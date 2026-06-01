defmodule EliHole.Repo.Migrations.CreateQueryLogs do
  use Ecto.Migration

  def change do
    create table(:query_logs) do
      add :domain, :string
      add :type, :string
      add :client, :string
      add :upstream, :string
      add :status, :string, null: false
      add :dnssec, :string
      add :transport, :string
      add :duration_ms, :integer, null: false, default: 0
      add :queried_at, :utc_datetime_usec, null: false
    end

    # Newest-first reads, range scans for aggregates, and retention pruning all
    # key on queried_at.
    create index(:query_logs, [:queried_at])
  end
end
