defmodule EliHole.DNS.SpeedTracker do
  use GenServer

  @table :dns_speed_tracker
  @max_samples 50

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def record(upstream, time_ms) when is_tuple(upstream) do
    GenServer.cast(__MODULE__, {:record, upstream, time_ms})
  end

  def record_timeout(upstream) when is_tuple(upstream) do
    GenServer.cast(__MODULE__, {:record, upstream, :timeout})
  end

  def pick_racers(upstreams, count \\ 2) do
    ranked = rank(upstreams)

    case length(ranked) do
      0 -> []
      n when n <= count -> Enum.map(ranked, fn {upstream, _avg} -> upstream end)
      _ -> weighted_pick(ranked, count)
    end
  end

  def rank(upstreams) do
    upstreams
    |> Enum.map(fn upstream -> {upstream, avg(upstream)} end)
    |> Enum.sort_by(fn {_u, avg} -> avg end)
  end

  def avg(upstream) do
    case :ets.lookup(@table, upstream) do
      [{_key, samples}] ->
        valid = Enum.reject(samples, &(&1 == :timeout))

        if valid == [] do
          9999
        else
          div(Enum.sum(valid), length(valid))
        end

      [] ->
        5000
    end
  end

  def stats do
    :ets.tab2list(@table)
    |> Enum.map(fn {upstream, samples} ->
      valid = Enum.reject(samples, &(&1 == :timeout))
      timeouts = length(samples) - length(valid)

      avg =
        if valid == [],
          do: nil,
          else: div(Enum.sum(valid), length(valid))

      min_val = if valid == [], do: nil, else: Enum.min(valid)
      max_val = if valid == [], do: nil, else: Enum.max(valid)

      %{
        upstream: upstream,
        avg_ms: avg,
        min_ms: min_val,
        max_ms: max_val,
        samples: length(samples),
        timeouts: timeouts
      }
    end)
    |> Enum.sort_by(& &1.avg_ms)
  end

  defp weighted_pick(ranked, count) do
    weights =
      ranked
      |> Enum.map(fn {upstream, avg} -> {upstream, max(1, 10_000 - avg)} end)

    total = Enum.sum(Enum.map(weights, fn {_u, w} -> w end))

    pick_n(weights, total, count, MapSet.new())
  end

  defp pick_n(_weights, _total, 0, _seen), do: []

  defp pick_n(weights, total, n, seen) do
    {picked, _} = weighted_random(weights, total)

    if MapSet.member?(seen, picked) do
      remaining = Enum.reject(weights, fn {u, _w} -> MapSet.member?(seen, u) end)
      new_total = Enum.sum(Enum.map(remaining, fn {_u, w} -> w end))

      if remaining == [] do
        []
      else
        {alt, _} = weighted_random(remaining, new_total)
        [alt | pick_n(weights, total, n - 1, MapSet.put(seen, alt))]
      end
    else
      [picked | pick_n(weights, total, n - 1, MapSet.put(seen, picked))]
    end
  end

  defp weighted_random(weights, total) do
    r = :rand.uniform(total)
    find_by_weight(weights, r)
  end

  defp find_by_weight([{upstream, weight}], _r), do: {upstream, weight}

  defp find_by_weight([{upstream, weight} | rest], r) do
    if r <= weight, do: {upstream, weight}, else: find_by_weight(rest, r - weight)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, upstream, time}, state) do
    samples =
      case :ets.lookup(@table, upstream) do
        [{_key, existing}] -> Enum.take([time | existing], @max_samples)
        [] -> [time]
      end

    :ets.insert(@table, {upstream, samples})
    {:noreply, state}
  end
end
