defmodule EliHole.DNS.QueryLogEntry do
  @moduledoc """
  Ecto schema for the durable query-history table (`query_logs`).

  This is the on-disk backing for `EliHole.DNS.QueryLog`'s in-memory recent
  ring: every logged query is persisted here so the history (and the derived
  aggregates) survive a restart. `status`, `dnssec`, and `transport` are stored
  as strings and converted back to atoms on read — see `EliHole.DNS.QueryHistory`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "query_logs" do
    field :domain, :string
    field :type, :string
    field :client, :string
    field :upstream, :string
    field :status, :string
    field :dnssec, :string
    field :transport, :string
    field :duration_ms, :integer, default: 0
    field :queried_at, :utc_datetime_usec
  end

  @fields [
    :domain,
    :type,
    :client,
    :upstream,
    :status,
    :dnssec,
    :transport,
    :duration_ms,
    :queried_at
  ]

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @fields)
    |> validate_required([:status, :queried_at])
  end
end
