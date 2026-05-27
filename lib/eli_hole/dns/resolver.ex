defmodule EliHole.DNS.Resolver do
  alias EliHole.DNS.{Blocklist, Cache, SpeedTracker}

  require Logger

  @upstream_timeout 5_000
  @race_count 2

  def resolve(query_packet) when is_binary(query_packet) do
    {domain, type} = extract_query_info(query_packet)

    if Blocklist.blocked?(domain) do
      Logger.debug("Blocked: #{domain}/#{type}")
      {:blocked, nil, build_blocked_response(query_packet, type)}
    else
      case Cache.lookup(domain, type) do
        {:hit, cached_response, original_upstream} ->
          Logger.debug("Cache hit: #{domain}/#{type}")
          {:ok, "cache (#{original_upstream})", rewrite_id(query_packet, cached_response)}

        :miss ->
          resolve_upstream(query_packet, domain, type)
      end
    end
  end

  defp resolve_upstream(query_packet, domain, type) do
    upstreams = Cache.get_upstreams()
    racers = SpeedTracker.pick_racers(upstreams, @race_count)

    case race(query_packet, racers) do
      {:ok, {{ip, port} = upstream, response, time_ms}} ->
        upstream_str = Cache.format_upstream({ip, port})
        SpeedTracker.record(upstream, time_ms)
        Logger.debug("Resolved via #{upstream_str} (#{time_ms}ms, raced #{length(racers)})")
        Cache.put(domain, type, response, upstream_str)
        {:ok, upstream_str, response}

      {:error, _reason} ->
        case fallback_forward(query_packet, upstreams -- racers) do
          {:ok, {{ip, port}, response}} ->
            upstream_str = Cache.format_upstream({ip, port})
            Cache.put(domain, type, response, upstream_str)
            {:ok, upstream_str, response}

          {:error, reason} ->
            Logger.error("DNS resolution failed: #{inspect(reason)}")
            {:error, nil, build_servfail(query_packet)}
        end
    end
  end

  defp race(_packet, []), do: {:error, :no_racers}

  defp race(packet, racers) do
    tasks =
      Enum.map(racers, fn {ip, port} ->
        Task.async(fn ->
          {time_us, result} =
            :timer.tc(fn ->
              case :gen_udp.open(0, [:binary, active: false]) do
                {:ok, socket} ->
                  try do
                    :gen_udp.send(socket, ip, port, packet)
                    :gen_udp.recv(socket, 0, @upstream_timeout)
                  after
                    :gen_udp.close(socket)
                  end

                {:error, reason} ->
                  {:error, reason}
              end
            end)

          case result do
            {:ok, {_recv_ip, _recv_port, response}} ->
              {:ok, {ip, port}, response, div(time_us, 1000)}

            {:error, reason} ->
              SpeedTracker.record_timeout({ip, port})
              {:error, {ip, port}, reason}
          end
        end)
      end)

    try do
      await_first(tasks)
    after
      Enum.each(tasks, fn task ->
        Task.shutdown(task, :brutal_kill)
      end)
    end
  end

  defp await_first([]), do: {:error, :all_racers_failed}

  defp await_first(tasks) do
    receive do
      {ref, {:ok, {ip, port}, response, time_ms}} ->
        Process.demonitor(ref, [:flush])
        {:ok, {{ip, port}, response, time_ms}}

      {ref, {:error, _upstream, _reason}} ->
        Process.demonitor(ref, [:flush])
        remaining = Enum.reject(tasks, fn t -> t.ref == ref end)
        await_first(remaining)

      {:DOWN, ref, :process, _pid, _reason} ->
        remaining = Enum.reject(tasks, fn t -> t.ref == ref end)
        await_first(remaining)
    after
      @upstream_timeout ->
        {:error, :all_racers_timeout}
    end
  end

  defp fallback_forward(_packet, []), do: {:error, :all_upstreams_failed}

  defp fallback_forward(packet, [{ip, port} | rest]) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          :gen_udp.send(socket, ip, port, packet)

          case :gen_udp.recv(socket, 0, @upstream_timeout) do
            {:ok, {_ip, _port, response}} -> {:ok, {{ip, port}, response}}
            {:error, _} -> fallback_forward(packet, rest)
          end
        after
          :gen_udp.close(socket)
        end

      {:error, _} ->
        fallback_forward(packet, rest)
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

  defp build_blocked_response(query_packet, query_type) do
    case :inet_dns.decode(query_packet) do
      {:ok, record} ->
        header = :inet_dns.msg(record, :header)
        id = :inet_dns.header(header, :id)
        qdlist = :inet_dns.msg(record, :qdlist)

        if query_type == "A" do
          q = List.first(qdlist)
          domain = :inet_dns.dns_query(q, :domain)

          response_header =
            :inet_dns.make_header(id: id, qr: true, opcode: :query, aa: true, rcode: 0, ra: true)

          answer =
            :inet_dns.make_rr(domain: domain, type: :a, class: :in, ttl: 0, data: {0, 0, 0, 0})

          msg = :inet_dns.make_msg(header: response_header, qdlist: qdlist, anlist: [answer])

          case :inet_dns.encode(msg) do
            {:ok, response} -> response
            response when is_binary(response) -> response
          end
        else
          response_header =
            :inet_dns.make_header(id: id, qr: true, opcode: :query, aa: true, rcode: 3, ra: true)

          msg = :inet_dns.make_msg(header: response_header, qdlist: qdlist)

          case :inet_dns.encode(msg) do
            {:ok, response} -> response
            response when is_binary(response) -> response
          end
        end

      {:error, _} ->
        <<>>
    end
  rescue
    _ -> <<>>
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
