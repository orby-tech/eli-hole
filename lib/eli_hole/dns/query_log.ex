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

    {resolved, failed} =
      Enum.reduce(all, {0, 0}, fn {_ts, entry}, {r, f} ->
        if entry.status == :ok, do: {r + 1, f}, else: {r, f + 1}
      end)

    %{total: total, resolved: resolved, failed: failed}
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
