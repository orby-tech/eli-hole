defmodule EliHole.Metrics do
  @moduledoc """
  Prometheus text-exposition (version 0.0.4) exporter behind `GET /metrics`.

  Sourced from the in-memory `QueryLog` and `Cache` plus `Health` component
  liveness. The query/DNSSEC counts are emitted as **gauges**, not counters:
  `QueryLog` is a rolling, capped ETS window (not monotonic), so a counter type
  would be a lie to the scraper.
  """

  alias EliHole.DNS.{Cache, QueryLog}

  @spec prometheus_text() :: binary()
  def prometheus_text do
    qstats = QueryLog.stats()
    dnssec = QueryLog.dnssec_breakdown()
    cache = Cache.stats()
    health = EliHole.Health.check()

    [
      gauge("elihole_dns_queries", "DNS queries in the rolling in-memory log, by status", [
        {%{status: "resolved"}, qstats.resolved},
        {%{status: "blocked"}, qstats.blocked},
        {%{status: "failed"}, qstats.failed},
        {%{status: "rate_limited"}, qstats.rate_limited}
      ]),
      gauge("elihole_dns_queries_logged", "Queries currently retained in the rolling log", [
        {%{}, qstats.total}
      ]),
      gauge("elihole_dns_queries_per_second", "Average queries per second over the last 60s", [
        {%{}, QueryLog.recent_rate()}
      ]),
      gauge("elihole_dnssec_validations", "DNSSEC validation verdicts in the rolling log", [
        {%{verdict: "secure"}, dnssec.secure},
        {%{verdict: "insecure"}, dnssec.insecure},
        {%{verdict: "bogus"}, dnssec.bogus}
      ]),
      gauge("elihole_cache_entries", "DNS response cache entries by state", [
        {%{state: "active"}, cache.active},
        {%{state: "expired"}, cache.expired}
      ]),
      gauge("elihole_cache_ttl_seconds", "Configured DNS cache TTL in seconds", [{%{}, cache.ttl}]),
      gauge(
        "elihole_component_up",
        "Component liveness (1 = up, 0 = down)",
        Enum.map(health.checks, fn {component, result} ->
          {%{component: to_string(component)}, if(result == :ok, do: 1, else: 0)}
        end)
      )
    ]
    |> IO.iodata_to_binary()
  end

  defp gauge(name, help, samples) do
    [
      "# HELP ",
      name,
      " ",
      help,
      "\n",
      "# TYPE ",
      name,
      " gauge\n",
      Enum.map(samples, fn {labels, value} ->
        [name, format_labels(labels), " ", to_string(value), "\n"]
      end)
    ]
  end

  defp format_labels(labels) when map_size(labels) == 0, do: ""

  defp format_labels(labels) do
    inner =
      labels
      |> Enum.map(fn {key, value} -> [to_string(key), "=\"", value, "\""] end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end
end
