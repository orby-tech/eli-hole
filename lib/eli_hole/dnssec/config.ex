defmodule EliHole.DNSSEC.Config do
  @moduledoc """
  Runtime DNSSEC settings, ETS-cached and persisted to `dns_settings`.

  Currently a single flag, `enforce`: when on, the resolver acts on validation
  results (SERVFAIL on `:bogus`, AD bit on `:secure`) on the client's critical path;
  when off (default), validation is classification-only and runs off the critical
  path. Defaults to off so enabling DNSSEC never silently breaks resolution.
  """

  use GenServer

  alias EliHole.DNS.Setting
  alias EliHole.Repo

  @table :dnssec_config
  @setting_key "dnssec_enforce"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Whether the resolver should enforce validation results (SERVFAIL/AD). Default false."
  def enforce? do
    case :ets.lookup(@table, :enforce) do
      [{:enforce, value}] -> value
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Enable/disable enforcement; persists and broadcasts the change."
  def set_enforce(value) when is_boolean(value) do
    :ets.insert(@table, {:enforce, value})
    persist(value)
    Phoenix.PubSub.broadcast(EliHole.PubSub, "dnssec:config", {:enforce_changed, value})
    :ok
  end

  defp persist(value) do
    str = to_string(value)

    case Repo.get_by(Setting, key: @setting_key) do
      nil -> %Setting{} |> Setting.changeset(%{key: @setting_key, value: str}) |> Repo.insert()
      existing -> existing |> Setting.changeset(%{value: str}) |> Repo.update()
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    :ets.insert(@table, {:enforce, false})
    send(self(), :load_from_db)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:load_from_db, state) do
    case Repo.get_by(Setting, key: @setting_key) do
      %Setting{value: "true"} -> :ets.insert(@table, {:enforce, true})
      _ -> :ok
    end

    {:noreply, state}
  end
end
