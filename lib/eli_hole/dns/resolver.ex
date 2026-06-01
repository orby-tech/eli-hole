defmodule EliHole.DNS.Resolver do
  import Bitwise

  alias EliHole.DNS.{Blocklist, Cache, LocalDNS, PauseControl, SpeedTracker, Whitelist}
  alias EliHole.DNSSEC.{Client, Validator}

  require Logger

  @upstream_timeout 5_000
  @race_count 2

  # Query-type names (as produced by extract_query_info/1) → numeric RR type, for the
  # subset worth DNSSEC-validating. Unlisted types are skipped (status nil).
  @dnssec_types %{"A" => 1, "AAAA" => 28, "CNAME" => 5, "MX" => 15, "TXT" => 16, "NS" => 2}

  def resolve(query_packet) when is_binary(query_packet) do
    {domain, type} = extract_query_info(query_packet)

    if blocked_domain?(domain) do
      Logger.debug("Blocked: #{domain}/#{type}")
      {:blocked, nil, build_blocked_response(query_packet, type)}
    else
      case check_local_dns(query_packet, domain, type) do
        {:ok, _, _} = result ->
          result

        nil ->
          case Cache.lookup(domain, type) do
            {:hit, cached_response, original_upstream} ->
              Logger.debug("Cache hit: #{domain}/#{type}")

              finalize_response(
                query_packet,
                domain,
                type,
                "cache (#{original_upstream})",
                rewrite_id(query_packet, cached_response)
              )

            :miss ->
              resolve_upstream(query_packet, domain, type)
          end
      end
    end
  end

  # Single block predicate for both the direct query path and the CNAME-cloaking
  # check. A global pause short-circuits to "not blocked"; the whitelist always
  # overrides the blocklist.
  defp blocked_domain?(domain) do
    not PauseControl.paused?() and Blocklist.blocked?(domain) and
      not Whitelist.allowed?(domain)
  end

  # CNAME cloaking defense: a clean-looking domain may resolve through a CNAME
  # chain whose target is on the blocklist. Inspect the answer section and block
  # if any CNAME target is blocked (and not whitelisted).
  defp finalize_response(query_packet, domain, type, source, response) do
    case cname_cloaked_target(response) do
      nil ->
        {:ok, source, response}

      target ->
        Logger.debug("Blocked (CNAME cloaking): #{domain}/#{type} -> #{target}")
        {:blocked, nil, build_blocked_response(query_packet, type)}
    end
  end

  defp cache_and_finalize(query_packet, domain, type, upstream_str, response) do
    case finalize_response(query_packet, domain, type, upstream_str, response) do
      {:ok, _, _} = result ->
        Cache.put(domain, type, response, upstream_str)
        result

      {:blocked, _, _} = blocked ->
        blocked
    end
  end

  defp cname_cloaked_target(response) do
    case :inet_dns.decode(response) do
      {:ok, record} ->
        record
        |> :inet_dns.msg(:anlist)
        |> Enum.find_value(fn rr ->
          if :inet_dns.rr(rr, :type) == :cname do
            target = rr |> :inet_dns.rr(:data) |> to_string()
            if blocked_domain?(target), do: target
          end
        end)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp check_local_dns(query_packet, domain, type) do
    case LocalDNS.lookup(domain, type) do
      {:ok, target} ->
        Logger.debug("Local DNS: #{domain}/#{type} -> #{target}")
        {:ok, "local", build_local_response(query_packet, type, target)}

      :miss ->
        nil
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
        cache_and_finalize(query_packet, domain, type, upstream_str, response)

      {:error, _reason} ->
        case fallback_forward(query_packet, upstreams -- racers) do
          {:ok, {{ip, port}, response}} ->
            upstream_str = Cache.format_upstream({ip, port})
            cache_and_finalize(query_packet, domain, type, upstream_str, response)

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

  @doc """
  DNSSEC validation status for a resolved query, for display in the query log.

  Returns `:secure | :insecure | :bogus | nil`. Only `:ok` (successfully resolved
  upstream) results are validated; blocked/local/error answers return `nil`. The
  client's forwarded query usually lacks the DO bit, so this issues its own
  DO-enabled lookup via `Client` (cached) and runs the full chain-of-trust
  `Validator`. Best-effort: any failure yields `nil` rather than disrupting DNS.
  This runs off the client's critical path (the answer is already sent).
  """
  def dnssec_status(:ok, domain, type) do
    with rr_type when is_integer(rr_type) <- Map.get(@dnssec_types, type),
         {:ok, answer} <- Client.query(domain, rr_type) do
      Validator.validate(domain, rr_type, answer) |> elem(0)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def dnssec_status(_status, _domain, _type), do: nil

  @doc """
  Apply a DNSSEC verdict to the response when enforcement is enabled:

    * `:bogus` resolved answer → replace with SERVFAIL (the forged/invalid answer is
      withheld from the client).
    * `:secure` resolved answer → set the AD (Authenticated Data) header bit.
    * anything else → response unchanged.
  """
  def enforce_response(_response, :ok, :bogus, query_packet), do: build_servfail(query_packet)
  def enforce_response(response, :ok, :secure, _query_packet), do: set_ad_bit(response)
  def enforce_response(response, _status, _dnssec, _query_packet), do: response

  # AD is bit 5 of the second flags octet (RA Z AD CD RCODE) → mask 0x20.
  defp set_ad_bit(<<id::16, flags1, flags2, rest::binary>>),
    do: <<id::16, flags1, flags2 ||| 0x20, rest::binary>>

  defp set_ad_bit(other), do: other

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

  defp build_local_response(query_packet, query_type, target) do
    case :inet_dns.decode(query_packet) do
      {:ok, record} ->
        header = :inet_dns.msg(record, :header)
        id = :inet_dns.header(header, :id)
        qdlist = :inet_dns.msg(record, :qdlist)
        q = List.first(qdlist)
        domain = :inet_dns.dns_query(q, :domain)

        response_header =
          :inet_dns.make_header(id: id, qr: true, opcode: :query, aa: true, rcode: 0, ra: true)

        answer =
          case query_type do
            "A" ->
              {:ok, ip} = :inet.parse_ipv4_address(String.to_charlist(target))
              :inet_dns.make_rr(domain: domain, type: :a, class: :in, ttl: 300, data: ip)

            "AAAA" ->
              {:ok, ip} = :inet.parse_ipv6_address(String.to_charlist(target))
              :inet_dns.make_rr(domain: domain, type: :aaaa, class: :in, ttl: 300, data: ip)

            "CNAME" ->
              :inet_dns.make_rr(
                domain: domain,
                type: :cname,
                class: :in,
                ttl: 300,
                data: String.to_charlist(target)
              )

            _ ->
              nil
          end

        if answer do
          msg = :inet_dns.make_msg(header: response_header, qdlist: qdlist, anlist: [answer])

          case :inet_dns.encode(msg) do
            {:ok, response} -> response
            response when is_binary(response) -> response
          end
        else
          <<>>
        end

      {:error, _} ->
        <<>>
    end
  rescue
    _ -> <<>>
  end

  defp build_servfail(query_packet), do: build_rcode_response(query_packet, 2)

  @doc """
  Build a REFUSED (rcode 5) response echoing the query's question section.

  Used by the `Handler` to turn a rate-limited query away before any upstream
  resolution. REFUSED (rather than a silent drop) keeps the client's transport
  satisfied while signalling that the server declined to answer.
  """
  def build_refused(query_packet), do: build_rcode_response(query_packet, 5)

  # Header-only response (echoing the question) carrying the given rcode. Shared
  # by SERVFAIL (2) and REFUSED (5).
  defp build_rcode_response(query_packet, rcode) do
    case :inet_dns.decode(query_packet) do
      {:ok, record} ->
        header = :inet_dns.msg(record, :header)
        id = :inet_dns.header(header, :id)

        response_header =
          :inet_dns.make_header(
            id: id,
            qr: true,
            opcode: :query,
            rcode: rcode,
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
