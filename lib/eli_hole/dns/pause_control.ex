defmodule EliHole.DNS.PauseControl do
  @moduledoc """
  Temporarily disables blocklist enforcement for a fixed duration ("pause blocking").

  While paused, the resolver's block predicate is bypassed so every domain
  resolves normally; the whitelist, local DNS, cache, and DNSSEC paths are
  unaffected. State is ETS-cached for the hot path (`paused?/0` runs on every
  query), persisted to `dns_settings` so an active pause survives a restart, and
  changes broadcast on `"dns:pause"`. A timer re-enables blocking automatically
  at expiry. Blocking is active (not paused) by default.

  The stored value is the absolute unix second at which blocking resumes
  (`paused_until`); `remaining/0` self-heals to 0 once that deadline passes, even
  before the expiry timer fires, so the hot path never trusts a stale flag.
  """

  use GenServer

  alias EliHole.DNS.Setting
  alias EliHole.Repo

  @table :pause_control
  @setting_key "pause_until"
  @topic "dns:pause"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Whether blocking is currently paused. Hot path — reads ETS only."
  def paused?, do: remaining() > 0

  @doc """
  Seconds left on the active pause, or 0 if blocking is active. Reads ETS and
  compares to the wall clock, so an expired deadline reads as 0 immediately.
  """
  def remaining do
    case :ets.lookup(@table, :paused_until) do
      [{:paused_until, until}] when is_integer(until) -> max(until - now(), 0)
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Pause blocking for `minutes` minutes (must be a positive integer)."
  def pause(minutes) when is_integer(minutes) and minutes > 0 do
    GenServer.call(__MODULE__, {:pause, minutes * 60})
  end

  @doc "Resume blocking immediately."
  def resume, do: GenServer.call(__MODULE__, :resume)

  @doc "Current pause state as `%{paused?: boolean, remaining: seconds}`."
  def status, do: %{paused?: paused?(), remaining: remaining()}

  # --- Server ---

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])

    # Load synchronously (like RateLimiter): a pause persisted before a restart
    # must be in effect from the very first query, with no async catch-up gap
    # in which blocking is wrongly enforced.
    until = persisted_until()
    seconds_left = until - now()

    timer =
      if seconds_left > 0 do
        :ets.insert(@table, {:paused_until, until})
        schedule_expiry(seconds_left)
      else
        :ets.insert(@table, {:paused_until, nil})
        nil
      end

    {:ok, %{timer: timer}}
  end

  @impl true
  def handle_info(:expire, state) do
    # Ignore a stale tick from a timer that was superseded by a newer pause:
    # `Process.cancel_timer/1` cannot un-deliver an already-sent message, so a
    # queued `:expire` could otherwise clear a fresh pause. If time still
    # remains, a live timer is already scheduled — leave the pause intact.
    if remaining() > 0 do
      {:noreply, state}
    else
      clear()
      broadcast()
      {:noreply, %{state | timer: nil}}
    end
  end

  @impl true
  def handle_call({:pause, seconds}, _from, state) do
    until = now() + seconds
    :ets.insert(@table, {:paused_until, until})
    persist(until)
    broadcast()
    {:reply, :ok, %{state | timer: reschedule(state.timer, seconds)}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    clear()
    broadcast()
    {:reply, :ok, %{state | timer: cancel(state.timer)}}
  end

  # --- Helpers ---

  defp now, do: System.system_time(:second)

  defp clear do
    :ets.insert(@table, {:paused_until, nil})
    persist(nil)
  end

  defp broadcast do
    Phoenix.PubSub.broadcast(EliHole.PubSub, @topic, {:pause_changed, status()})
  end

  defp schedule_expiry(seconds) when seconds > 0 do
    Process.send_after(self(), :expire, seconds * 1000)
  end

  defp reschedule(timer, seconds) do
    timer |> cancel() |> then(fn _ -> schedule_expiry(seconds) end)
  end

  defp cancel(nil), do: nil

  defp cancel(timer) do
    Process.cancel_timer(timer)
    nil
  end

  defp persisted_until do
    case Repo.get_by(Setting, key: @setting_key) do
      %Setting{value: value} ->
        case Integer.parse(value) do
          {n, _} -> n
          :error -> 0
        end

      nil ->
        0
    end
  end

  # `until` is nil when clearing; persist "0" since `Setting.changeset` rejects
  # an empty string (validate_required), and 0 reads back as "not paused".
  defp persist(until) do
    str = to_string(until || 0)

    case Repo.get_by(Setting, key: @setting_key) do
      nil -> %Setting{} |> Setting.changeset(%{key: @setting_key, value: str}) |> Repo.insert()
      existing -> existing |> Setting.changeset(%{value: str}) |> Repo.update()
    end
  end
end
