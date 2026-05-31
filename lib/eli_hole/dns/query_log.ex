defmodule EliHole.DNS.QueryLog do
  use GenServer

  @table :dns_query_log
  @max_entries 10_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def log(entry) do
    GenServer.cast(__MODULE__, {:log, entry})
  end

  @doc """
  Subscribe the calling process to live query events.

  Each logged query is broadcast as `{:new_query, entry}` on the `dns:queries`
  PubSub topic — the admin LiveView and tests consume it for real-time updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:queries")
  end

  def recent(limit \\ 100) do
    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {ts, _} -> ts end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_ts, entry} -> entry end)
  end

  def stats do
    all = :ets.tab2list(@table)
    total = length(all)

    {resolved, blocked, failed, rate_limited} =
      Enum.reduce(all, {0, 0, 0, 0}, fn {_ts, entry}, {r, b, f, rl} ->
        cond do
          entry.status == :ok -> {r + 1, b, f, rl}
          entry.status == :blocked -> {r, b + 1, f, rl}
          entry.status == :rate_limited -> {r, b, f, rl + 1}
          true -> {r, b, f + 1, rl}
        end
      end)

    %{
      total: total,
      resolved: resolved,
      blocked: blocked,
      failed: failed,
      rate_limited: rate_limited
    }
  end

  def top_domains(limit \\ 10) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_ts, entry} -> entry.domain end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_domain, count} -> count end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {domain, count} -> %{domain: domain, count: count} end)
  end

  def top_clients(limit \\ 10) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_ts, entry} -> entry.client end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_client, count} -> count end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {client, count} -> %{client: client, count: count} end)
  end

  def status_breakdown do
    :ets.tab2list(@table)
    |> Enum.map(fn {_ts, entry} -> entry.status end)
    |> Enum.frequencies()
    |> then(fn freqs ->
      %{
        ok: Map.get(freqs, :ok, 0),
        error: Map.get(freqs, :error, 0),
        blocked: Map.get(freqs, :blocked, 0),
        rate_limited: Map.get(freqs, :rate_limited, 0)
      }
    end)
  end

  @doc "Counts of DNSSEC validation verdicts across logged queries (entries without a verdict ignored)."
  def dnssec_breakdown do
    freqs =
      :ets.tab2list(@table)
      |> Enum.map(fn {_ts, entry} -> Map.get(entry, :dnssec) end)
      |> Enum.frequencies()

    %{
      secure: Map.get(freqs, :secure, 0),
      insecure: Map.get(freqs, :insecure, 0),
      bogus: Map.get(freqs, :bogus, 0)
    }
  end

  def queries_per_minute(minutes \\ 60) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_ts, entry} -> String.slice(entry.time, 0, 5) end)
    |> Enum.frequencies()
    |> Enum.map(fn {minute, count} -> %{minute: minute, count: count} end)
    |> Enum.sort_by(& &1.minute)
    |> Enum.take(-minutes)
  end

  def recent_rate do
    now = System.monotonic_time(:second)
    cutoff = now - 60

    :ets.tab2list(@table)
    |> Enum.count(fn {ts, _entry} ->
      System.convert_time_unit(ts, :native, :second) > cutoff
    end)
    |> then(&Float.round(&1 / 60, 1))
  end

  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  @impl true
  def init(_) do
    table = :ets.new(@table, [:ordered_set, :named_table, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:log, entry}, state) do
    ts = System.monotonic_time()
    :ets.insert(@table, {ts, entry})
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:queries", {:new_query, entry})
    prune()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear, state) do
    :ets.delete_all_objects(@table)
    {:noreply, state}
  end

  defp prune do
    size = :ets.info(@table, :size)

    if size > @max_entries do
      to_delete = size - @max_entries

      @table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {ts, _} -> ts end, :asc)
      |> Enum.take(to_delete)
      |> Enum.each(fn {ts, _} -> :ets.delete(@table, ts) end)
    end
  end
end
