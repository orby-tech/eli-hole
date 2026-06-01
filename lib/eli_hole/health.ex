defmodule EliHole.Health do
  @moduledoc """
  Liveness/readiness checks behind the `GET /api/health` endpoint.

  Verifies the database is reachable and the core DNS GenServers are alive.
  `check/0` returns `%{status: :ok | :degraded, checks: %{atom => :ok | :down}}`
  — `:degraded` if any single check is down.
  """

  alias EliHole.Repo

  # Core processes whose death means DNS is not being served correctly.
  @components [
    {:dns_server, EliHole.DNS.Server},
    {:cache, EliHole.DNS.Cache},
    {:query_log, EliHole.DNS.QueryLog}
  ]

  @spec check() :: %{status: :ok | :degraded, checks: %{atom => :ok | :down}}
  def check do
    [
      {:database, database_check()}
      | Enum.map(@components, fn {name, mod} -> {name, process_check(mod)} end)
    ]
    |> Map.new()
    |> summarize()
  end

  @doc """
  Roll a map of per-component results into an overall verdict: `:ok` only when
  every check passed, `:degraded` otherwise. Pure — split out so the degraded
  path is testable without killing shared GenServers.
  """
  @spec summarize(%{atom => :ok | :down}) :: %{
          status: :ok | :degraded,
          checks: %{atom => :ok | :down}
        }
  def summarize(checks) when is_map(checks) do
    status =
      if Enum.all?(checks, fn {_name, result} -> result == :ok end), do: :ok, else: :degraded

    %{status: status, checks: checks}
  end

  defp process_check(mod) do
    case Process.whereis(mod) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: :ok, else: :down
      _ -> :down
    end
  end

  defp database_check do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> :ok
      _ -> :down
    end
  rescue
    _ -> :down
  end
end
