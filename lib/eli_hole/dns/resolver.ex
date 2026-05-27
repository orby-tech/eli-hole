defmodule EliHole.DNS.Resolver do
  alias EliHole.DNS.Cache

  require Logger

  @upstream_timeout 5_000

  def resolve(query_packet) when is_binary(query_packet) do
    {domain, type} = extract_query_info(query_packet)

    case Cache.lookup(domain, type) do
      {:hit, cached_response, original_upstream} ->
        Logger.debug("Cache hit: #{domain}/#{type}")
        {:ok, "cache (#{original_upstream})", rewrite_id(query_packet, cached_response)}

      :miss ->
        resolve_upstream(query_packet, domain, type)
    end
  end

  defp resolve_upstream(query_packet, domain, type) do
    upstreams = Cache.get_upstreams()

    case forward(query_packet, upstreams) do
      {:ok, {upstream, response}} ->
        upstream_str = to_string(:inet.ntoa(upstream))
        Logger.debug("Resolved via #{upstream_str}")
        Cache.put(domain, type, response, upstream_str)
        {:ok, upstream_str, response}

      {:error, reason} ->
        Logger.error("DNS resolution failed: #{inspect(reason)}")
        {:error, nil, build_servfail(query_packet)}
    end
  end

  def extract_query_info(packet) do
    case :inet_dns.decode(packet) do
      {:ok, record} ->
        case :inet_dns.msg(record, :qdlist) |> List.first() do
          nil ->
            {"?", "?"}

          q ->
            domain = q |> :inet_dns.dns_query(:domain) |> to_string()
            type = q |> :inet_dns.dns_query(:type) |> to_string() |> String.upcase()
            {domain, type}
        end

      _ ->
        {"?", "?"}
    end
  end

  defp rewrite_id(query_packet, cached_response) do
    <<query_id::16, _::binary>> = query_packet
    <<_::16, rest::binary>> = cached_response
    <<query_id::16, rest::binary>>
  end

  defp forward(_packet, []) do
    {:error, :all_upstreams_failed}
  end

  defp forward(packet, [{ip, port} | rest]) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          :gen_udp.send(socket, ip, port, packet)

          case :gen_udp.recv(socket, 0, @upstream_timeout) do
            {:ok, {_ip, _port, response}} ->
              {:ok, {ip, response}}

            {:error, reason} ->
              Logger.warning("Upstream #{:inet.ntoa(ip)}:#{port} failed: #{inspect(reason)}")
              forward(packet, rest)
          end
        after
          :gen_udp.close(socket)
        end

      {:error, _reason} ->
        forward(packet, rest)
    end
  end

  defp build_servfail(query_packet) do
    case :inet_dns.decode(query_packet) do
      {:ok, record} ->
        header = :inet_dns.msg(record, :header)
        id = :inet_dns.header(header, :id)

        response_header =
          :inet_dns.make_header(
            id: id,
            qr: true,
            opcode: :query,
            rcode: 2,
            ra: true
          )

        msg =
          :inet_dns.make_msg(
            header: response_header,
            qdlist: :inet_dns.msg(record, :qdlist)
          )

        case :inet_dns.encode(msg) do
          {:ok, response} -> response
          response when is_binary(response) -> response
        end

      {:error, _} ->
        <<>>
    end
  rescue
    _ -> <<>>
  end
end
