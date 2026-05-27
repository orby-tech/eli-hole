defmodule EliHole.DNS.LocalDNS do
  use GenServer

  import Ecto.Query

  alias EliHole.Repo
  alias EliHole.DNS.LocalRecord

  require Logger

  @table :local_dns
  @page_size 50

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def lookup(domain, type) when is_binary(domain) and is_binary(type) do
    domain = String.downcase(domain)

    case :ets.lookup(@table, {domain, type}) do
      [{_key, target}] -> {:ok, target}
      [] -> :miss
    end
  end

  def list_records(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, @page_size)

    LocalRecord
    |> order_by(desc: :inserted_at)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  def search_records(query, opts \\ []) when is_binary(query) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, @page_size)
    escaped = query |> String.replace(~r/[%_\\]/, "\\\\\\0")
    pattern = "%#{escaped}%"

    LocalRecord
    |> where([r], ilike(r.domain, ^pattern) or ilike(r.target, ^pattern))
    |> order_by(desc: :inserted_at)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  def get_record!(id), do: Repo.get!(LocalRecord, id)

  def create_record(attrs) do
    result =
      %LocalRecord{}
      |> LocalRecord.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, record} ->
        reload_cache()
        broadcast_change()
        {:ok, record}

      error ->
        error
    end
  end

  def update_record(%LocalRecord{} = record, attrs) do
    result =
      record
      |> LocalRecord.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        reload_cache()
        broadcast_change()
        {:ok, updated}

      error ->
        error
    end
  end

  def delete_record(%LocalRecord{} = record) do
    result = Repo.delete(record)

    case result do
      {:ok, _} ->
        reload_cache()
        broadcast_change()
        result

      error ->
        error
    end
  end

  def import_custom_list(content) when is_binary(content) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.flat_map(fn line ->
        case String.split(line, ~r/\s+/, parts: 2) do
          [ip, domain] ->
            type = detect_ip_type(ip)
            if type, do: [%{ip: ip, domain: String.downcase(domain), type: type}], else: []

          _ ->
            []
        end
      end)
      |> Enum.uniq_by(fn %{domain: d, type: t} -> {d, t} end)
      |> Enum.map(fn %{ip: ip, domain: domain, type: type} ->
        %{
          domain: domain,
          record_type: type,
          target: ip,
          enabled: true,
          comment: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(LocalRecord, entries,
        on_conflict: :nothing,
        conflict_target: [:domain, :record_type]
      )

    reload_cache()
    broadcast_change()
    {:ok, count}
  end

  def count_records("") do
    Repo.one(from r in LocalRecord, select: count(r.id))
  end

  def count_records(query) when is_binary(query) do
    escaped = query |> String.replace(~r/[%_\\]/, "\\\\\\0")
    pattern = "%#{escaped}%"

    Repo.one(
      from r in LocalRecord,
        where: ilike(r.domain, ^pattern) or ilike(r.target, ^pattern),
        select: count(r.id)
    )
  end

  def stats do
    total = Repo.one(from r in LocalRecord, select: count(r.id))
    enabled = Repo.one(from r in LocalRecord, select: count(r.id), where: r.enabled == true)

    %{total: total, enabled: enabled, disabled: total - enabled}
  end

  def list_all_enabled do
    LocalRecord
    |> where(enabled: true)
    |> Repo.all()
  end

  def flush_cache do
    GenServer.call(__MODULE__, :flush_cache)
  end

  defp detect_ip_type(ip) do
    cond do
      match?({:ok, _}, :inet.parse_ipv4_address(String.to_charlist(ip))) -> "A"
      match?({:ok, _}, :inet.parse_ipv6_address(String.to_charlist(ip))) -> "AAAA"
      true -> nil
    end
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:local_dns", :local_dns_changed)
  end

  defp reload_cache do
    GenServer.call(__MODULE__, :flush_cache)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    send(self(), :load_from_db)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:load_from_db, state) do
    load_entries_to_ets()
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush_cache, _from, state) do
    load_entries_to_ets()
    {:reply, :ok, state}
  end

  defp load_entries_to_ets do
    entries =
      LocalRecord
      |> where(enabled: true)
      |> Repo.all()

    :ets.delete_all_objects(@table)

    Enum.each(entries, fn record ->
      :ets.insert(@table, {{String.downcase(record.domain), record.record_type}, record.target})
    end)

    Logger.info("Local DNS loaded: #{length(entries)} records")
  end
end
