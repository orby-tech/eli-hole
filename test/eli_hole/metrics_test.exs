defmodule EliHole.MetricsTest do
  use EliHole.DataCase, async: false

  alias EliHole.DNS.QueryLog
  alias EliHole.Metrics

  test "emits valid Prometheus exposition with HELP/TYPE and core series" do
    text = Metrics.prometheus_text()

    # Each metric carries its HELP + TYPE preamble.
    assert text =~ "# HELP elihole_dns_queries "
    assert text =~ "# TYPE elihole_dns_queries gauge"
    assert text =~ "# TYPE elihole_cache_entries gauge"
    assert text =~ "# TYPE elihole_component_up gauge"

    # Labelled samples render in `name{label="v"} value` form.
    assert text =~ ~r/elihole_dns_queries\{status="blocked"\} \d+/
    assert text =~ ~r/elihole_dnssec_validations\{verdict="secure"\} \d+/
    assert text =~ ~r/elihole_component_up\{component="database"\} [01]/
    assert text =~ ~r/elihole_cache_ttl_seconds \d+/
    # recent_rate is a float — exercise the one value type the others miss.
    assert text =~ ~r/elihole_dns_queries_per_second \d+\.\d+/
  end

  test "reflects logged queries by status" do
    QueryLog.clear()

    QueryLog.log(%{
      domain: "a.test",
      client: "1.2.3.4",
      status: :blocked,
      time: "00:00",
      type: "A"
    })

    _ = :sys.get_state(QueryLog)

    text = Metrics.prometheus_text()

    assert text =~ ~r/elihole_dns_queries\{status="blocked"\} 1\b/
  end
end
