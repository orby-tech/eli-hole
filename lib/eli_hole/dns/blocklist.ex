defmodule EliHole.DNS.Blocklist do
  use GenServer

  import Ecto.Query

  alias EliHole.Repo
  alias EliHole.DNS.BlocklistEntry

  require Logger

  @exact_table :blocklist_exact
  @wildcard_table :blocklist_wildcard
  @regex_table :blocklist_regex

  # --- Client API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Check if a domain is blocked. Fast path: ETS lookup."
  def blocked?(domain) when is_binary(domain) do
    domain = String.downcase(domain)

    exact_match?(domain) or wildcard_match?(domain) or regex_match?(domain)
  end

  def blocked?(_), do: false

  @page_size 50

  @doc "List blocklist entries with pagination."
  def list_entries(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, @page_size)

    BlocklistEntry
    |> order_by(desc: :inserted_at)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  @doc "List only enabled entries."
  def list_enabled do
    BlocklistEntry
    |> where(enabled: true)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc "Search entries by domain substring with pagination."
  def search_entries(query, opts \\ []) when is_binary(query) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, @page_size)
    escaped = query |> String.replace(~r/[%_\\]/, "\\\\\\0")
    pattern = "%#{escaped}%"

    BlocklistEntry
    |> where([e], ilike(e.domain, ^pattern))
    |> order_by(desc: :inserted_at)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  @doc """
  Add a single exact-match domain to the blocklist.

  Creates the entry and synchronously reloads the ETS cache, so `blocked?/1`
  reflects it immediately. Returns `{:ok, entry}` or an Ecto error changeset.
  """
  def add_exact(domain) when is_binary(domain) do
    create_entry(%{domain: String.downcase(domain), type: "exact", source: "manual"})
  end

  def get_entry!(id), do: Repo.get!(BlocklistEntry, id)

  def create_entry(attrs) do
    result =
      %BlocklistEntry{}
      |> BlocklistEntry.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, entry} ->
        reload_cache()
        broadcast_change()
        {:ok, entry}

      error ->
        error
    end
  end

  def update_entry(%BlocklistEntry{} = entry, attrs) do
    result =
      entry
      |> BlocklistEntry.changeset(attrs)
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

  def delete_entry(%BlocklistEntry{} = entry) do
    result = Repo.delete(entry)

    case result do
      {:ok, _} ->
        reload_cache()
        broadcast_change()
        result

      error ->
        error
    end
  end

  @doc "Import hosts-file format string. Returns {:ok, count} or {:error, reason}."
  def import_hosts(content) when is_binary(content) do
    domains =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.flat_map(fn line ->
        parts = String.split(line, ~r/\s+/)

        case parts do
          [_ip | domains] -> Enum.reject(domains, &(&1 in ["localhost", "local", ""]))
          _ -> []
        end
      end)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    do_bulk_insert(domains, "hosts_import")
  end

  @doc "Import newline-separated domain list. Returns {:ok, count} or {:error, reason}."
  def import_domains(content) when is_binary(content) do
    domains =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    do_bulk_insert(domains, "domain_import")
  end

  @doc "Flush and reload the ETS cache from DB."
  def flush_cache do
    GenServer.call(__MODULE__, :flush_cache)
  end

  @doc "Return blocklist stats."
  def stats do
    total = Repo.one(from e in BlocklistEntry, select: count(e.id))
    enabled = Repo.one(from e in BlocklistEntry, select: count(e.id), where: e.enabled == true)

    %{
      total: total,
      enabled: enabled,
      disabled: total - enabled
    }
  end

  # --- Matching logic (reads ETS directly, no GenServer call) ---

  defp exact_match?(domain) do
    :ets.lookup(@exact_table, domain) != []
  end

  defp wildcard_match?(domain) do
    domain
    |> domain_parents()
    |> Enum.any?(fn parent ->
      :ets.lookup(@wildcard_table, parent) != []
    end)
  end

  defp regex_match?(domain) do
    case :ets.lookup(@regex_table, :patterns) do
      [{:patterns, patterns}] ->
        Enum.any?(patterns, fn regex ->
          Regex.match?(regex, domain)
        end)

      [] ->
        false
    end
  end

  @doc false
  def domain_parents(domain) do
    parts = String.split(domain, ".")

    parts
    |> Enum.drop(1)
    |> do_domain_parents([])
  end

  defp do_domain_parents([], acc), do: Enum.reverse(acc)

  defp do_domain_parents(parts, acc) do
    parent = Enum.join(parts, ".")
    do_domain_parents(tl(parts), [parent | acc])
  end

  # --- Bulk insert ---

  defp do_bulk_insert(domains, source) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(domains, fn domain ->
        %{
          domain: domain,
          type: "exact",
          source: source,
          enabled: true,
          comment: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(BlocklistEntry, entries,
        on_conflict: :nothing,
        conflict_target: [:domain, :type]
      )

    reload_cache()
    broadcast_change()
    {:ok, count}
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:blocklist", :blocklist_changed)
  end

  defp reload_cache do
    GenServer.call(__MODULE__, :flush_cache)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    :ets.new(@exact_table, [:set, :named_table, :public, read_concurrency: true])
    :ets.new(@wildcard_table, [:set, :named_table, :public, read_concurrency: true])
    :ets.new(@regex_table, [:set, :named_table, :public, read_concurrency: true])

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
      BlocklistEntry
      |> where(enabled: true)
      |> Repo.all()

    :ets.delete_all_objects(@exact_table)
    :ets.delete_all_objects(@wildcard_table)
    :ets.delete_all_objects(@regex_table)

    regex_patterns =
      Enum.reduce(entries, [], fn entry, regexes ->
        case entry.type do
          "exact" ->
            :ets.insert(@exact_table, {entry.domain, true})
            regexes

          "wildcard" ->
            if String.starts_with?(entry.domain, "*.") do
              parent = String.slice(entry.domain, 2, String.length(entry.domain))
              :ets.insert(@wildcard_table, {parent, true})
            else
              :ets.insert(@exact_table, {entry.domain, true})
            end

            regexes

          "regex" ->
            case Regex.compile(entry.domain) do
              {:ok, regex} -> [regex | regexes]
              {:error, _} -> regexes
            end

          _ ->
            regexes
        end
      end)

    :ets.insert(@regex_table, {:patterns, regex_patterns})

    Logger.info(
      "Blocklist loaded: #{:ets.info(@exact_table, :size)} exact, " <>
        "#{:ets.info(@wildcard_table, :size)} wildcard, " <>
        "#{length(regex_patterns)} regex patterns"
    )
  end
end
