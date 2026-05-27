defmodule EliHole.DNS.Gravity do
  use GenServer

  import Ecto.Query

  alias EliHole.Repo
  alias EliHole.DNS.{Adlists, Blocklist, BlocklistEntry}

  require Logger

  @default_interval_hours 24

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def update_now do
    GenServer.cast(__MODULE__, :update)
  end

  def update_sync do
    GenServer.call(__MODULE__, :update, :infinity)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    schedule_update(60_000)

    {:ok,
     %{
       last_update: nil,
       updating: false,
       last_result: nil
     }}
  end

  @impl true
  def handle_cast(:update, %{updating: true} = state) do
    {:noreply, state}
  end

  def handle_cast(:update, state) do
    {:noreply, do_update(state)}
  end

  @impl true
  def handle_call(:update, _from, %{updating: true} = state) do
    {:reply, {:error, :already_updating}, state}
  end

  def handle_call(:update, _from, state) do
    new_state = do_update(state)
    {:reply, {:ok, new_state.last_result}, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:scheduled_update, %{updating: true} = state) do
    schedule_update()
    {:noreply, state}
  end

  def handle_info(:scheduled_update, state) do
    new_state = do_update(state)
    schedule_update()
    {:noreply, new_state}
  end

  defp schedule_update(delay \\ nil) do
    delay = delay || @default_interval_hours * 3_600_000
    Process.send_after(self(), :scheduled_update, delay)
  end

  defp do_update(state) do
    broadcast_status(:updating)
    state = %{state | updating: true}

    adlists = Adlists.list_enabled()

    if adlists == [] do
      broadcast_status(:idle)
      %{state | updating: false, last_result: %{total: 0, lists: 0}}
    else
      results =
        adlists
        |> Task.async_stream(
          &download_and_import/1,
          timeout: :infinity,
          max_concurrency: 4
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> {:error, inspect(reason)}
        end)

      total =
        Enum.reduce(results, 0, fn
          {:ok, count}, acc -> acc + count
          _, acc -> acc
        end)

      Blocklist.flush_cache()

      result = %{total: total, lists: length(adlists)}
      Logger.info("Gravity update complete: #{total} domains from #{length(adlists)} lists")
      broadcast_status(:idle)
      broadcast_change()

      %{state | updating: false, last_update: DateTime.utc_now(), last_result: result}
    end
  end

  defp download_and_import(adlist) do
    Logger.info("Gravity: downloading #{adlist.address}")

    case Req.get(adlist.address, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: body}} ->
        source = "gravity:#{adlist.id}"
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.delete_all(from e in BlocklistEntry, where: e.source == ^source)

        domains =
          body
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
          |> Enum.flat_map(fn line ->
            parts = String.split(line, ~r/\s+/)

            case parts do
              [_ip | doms] -> Enum.reject(doms, &(&1 in ["localhost", "local", ""]))
              _ -> []
            end
          end)
          |> Enum.map(&String.downcase/1)
          |> Enum.uniq()

        entries =
          Enum.map(domains, fn domain ->
            %{
              domain: domain,
              type: "exact",
              source: source,
              enabled: true,
              comment: "gravity",
              inserted_at: now,
              updated_at: now
            }
          end)

        count =
          entries
          |> Enum.chunk_every(5000)
          |> Enum.reduce(0, fn chunk, acc ->
            {c, _} =
              Repo.insert_all(BlocklistEntry, chunk,
                on_conflict: :nothing,
                conflict_target: [:domain, :type]
              )

            acc + c
          end)

        Adlists.update_stats(adlist, length(domains))
        Logger.info("Gravity: #{count} new domains from #{adlist.address}")
        {:ok, count}

      {:ok, %{status: status}} ->
        Logger.warning("Gravity: HTTP #{status} from #{adlist.address}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.warning("Gravity: #{inspect(reason)} from #{adlist.address}")
        {:error, inspect(reason)}
    end
  end

  defp broadcast_status(status) do
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:gravity", {:gravity_status, status})
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dns:gravity", :gravity_updated)
  end
end
