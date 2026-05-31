defmodule EliHole.DNS.Handler do
  @moduledoc """
  Shared query-processing pipeline for every DNS transport — plain UDP,
  DNS-over-TLS (`DoTServer`), and DNS-over-HTTPS (`EliHoleWeb.DohController`).

  Resolves a wire-format query, applies DNSSEC enforcement when enabled,
  records the query in `QueryLog`, and returns the wire-format response.
  Centralizing this keeps the `{:ok | :blocked | :error, upstream, response}`
  contract, enforcement, and query logging identical across all transports.
  """

  alias EliHole.DNS.{QueryLog, Resolver}
  alias EliHole.DNSSEC.Config

  require Logger

  @doc """
  Resolve `packet` (wire format) and return the wire-format response binary.

  `client` is a display string (`"ip:port"`). `transport` tags the query log
  (`:udp | :dot | :doh`) so the admin panel can show how each query arrived.

  When DNSSEC enforcement is on, validation runs before the caller sends the
  response so a `:bogus` answer can be withheld (SERVFAIL) and a `:secure` one
  gets the AD bit. Otherwise classification happens after the answer is built
  (off the client's critical path), exactly as the plain-UDP server did.
  """
  def process(packet, client, transport \\ :udp) do
    enforce = Config.enforce?()

    {time_us, {status, upstream, response, domain, qtype, dnssec}} =
      :timer.tc(fn ->
        {status, upstream, response} = Resolver.resolve(packet)
        {domain, qtype} = Resolver.extract_query_info(packet)

        if enforce do
          d = Resolver.dnssec_status(status, domain, qtype)

          {status, upstream, Resolver.enforce_response(response, status, d, packet), domain,
           qtype, d}
        else
          {status, upstream, response, domain, qtype, nil}
        end
      end)

    duration_ms = div(time_us, 1000)

    Logger.debug(
      "DNS[#{transport}] #{domain}/#{qtype} from #{client} → #{upstream || "fail"} #{duration_ms}ms"
    )

    dnssec = if enforce, do: dnssec, else: Resolver.dnssec_status(status, domain, qtype)

    QueryLog.log(%{
      id: System.unique_integer([:positive]),
      time: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S"),
      client: client,
      domain: domain,
      type: qtype,
      upstream: upstream,
      duration_ms: duration_ms,
      status: status,
      dnssec: dnssec,
      transport: transport
    })

    response
  end
end
