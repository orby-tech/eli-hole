defmodule EliHole.DNSSEC.Client do
  @moduledoc """
  Issues DNSSEC-aware DNS queries (EDNS0 DO bit) to the configured upstreams and
  parses the responses with `EliHole.DNSSEC.Wire`. Used by the validator to fetch
  DNSKEY and DS records while building the chain of trust.

  Owns a small ETS cache (`:dnssec_records`) keyed by `{name, type}` so DNSKEY/DS
  lookups are not re-fetched on every query. Falls back to TCP when a UDP response
  is truncated (DNSKEY RRsets can exceed the UDP payload).
  """

  use GenServer

  alias EliHole.DNS.Cache
  alias EliHole.DNSSEC.Wire

  require Logger

  @table :dnssec_records
  @timeout 5_000
  @min_ttl 60
  @default_ttl 300

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Resolve `name` (binary, e.g. "cloudflare.com" or "." for root) and `type` (integer)
  with the DO bit set. Returns `{:ok, %Wire.Message{}}` or `{:error, reason}`. Caches
  successful answers for the minimum RR TTL.
  """
  def query(name, type) when is_binary(name) and is_integer(type) do
    case cache_lookup({name, type}) do
      {:ok, msg} ->
        {:ok, msg}

      :miss ->
        with {:ok, msg} <- do_query(name, type) do
          cache_put({name, type}, msg)
          {:ok, msg}
        end
    end
  end

  # --- query mechanics ---

  @recv_attempts 4

  defp do_query(name, type) do
    upstreams = Cache.get_upstreams()
    id = :rand.uniform(65_535)
    packet = Wire.build_query(name, type, id)
    try_upstreams(upstreams, name, type, id, packet)
  end

  defp try_upstreams([], _name, _type, _id, _packet), do: {:error, :all_upstreams_failed}

  defp try_upstreams([{ip, port} | rest], name, type, id, packet) do
    reply =
      case udp_query(ip, port, packet, id, name, type) do
        {:ok, %Wire.Message{tc: true}} -> tcp_query(ip, port, packet, id, name, type)
        other -> other
      end

    # NOERROR (0) and NXDOMAIN (3) are usable final answers — the latter carries the signed
    # NSEC/NSEC3 needed to validate a secure denial-of-existence. SERVFAIL/REFUSED/etc. are
    # transient failures: fall through to the next upstream (and don't cache them).
    case reply do
      {:ok, %Wire.Message{rcode: rcode} = msg} when rcode in [0, 3] -> {:ok, msg}
      _ -> try_upstreams(rest, name, type, id, packet)
    end
  end

  defp udp_query(ip, port, packet, id, name, type) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, sock} ->
        try do
          :gen_udp.send(sock, ip, port, packet)
          udp_recv_match(sock, id, name, type, @recv_attempts)
        after
          :gen_udp.close(sock)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Read datagrams until one matches our query id + question, or attempts run out. Guards
  # against off-path spoofed replies racing the real answer on the ephemeral port.
  defp udp_recv_match(_sock, _id, _name, _type, 0), do: {:error, :no_matching_reply}

  defp udp_recv_match(sock, id, name, type, attempts) do
    case :gen_udp.recv(sock, 0, @timeout) do
      {:ok, {_ip, _port, resp}} ->
        with {:ok, msg} <- Wire.parse(resp),
             true <- reply_matches?(msg, id, name, type) do
          {:ok, msg}
        else
          _ -> udp_recv_match(sock, id, name, type, attempts - 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tcp_query(ip, port, packet, id, name, type) do
    case :gen_tcp.connect(ip, port, [:binary, active: false], @timeout) do
      {:ok, sock} ->
        try do
          :gen_tcp.send(sock, <<byte_size(packet)::16>> <> packet)

          with {:ok, <<len::16>>} <- :gen_tcp.recv(sock, 2, @timeout),
               {:ok, resp} <- :gen_tcp.recv(sock, len, @timeout),
               {:ok, msg} <- Wire.parse(resp),
               true <- reply_matches?(msg, id, name, type) do
            {:ok, msg}
          else
            {:error, reason} -> {:error, reason}
            _ -> {:error, :tcp_reply_mismatch}
          end
        after
          :gen_tcp.close(sock)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A usable reply must be a response to our exact id and question (name + type).
  defp reply_matches?(%Wire.Message{id: id, qr: true, questions: [q | _]}, id, name, type) do
    Wire.name_to_string(q.name) == normalize(name) and q.type == type
  end

  defp reply_matches?(_msg, _id, _name, _type), do: false

  defp normalize("."), do: "."
  defp normalize(name), do: name |> String.trim_trailing(".") |> String.downcase()

  # --- cache ---

  defp cache_lookup(key) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, msg, expires_at}] when expires_at > now -> {:ok, msg}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(key, %Wire.Message{} = msg) do
    ttl = response_ttl(msg)
    :ets.insert(@table, {key, msg, System.monotonic_time(:second) + ttl})
  rescue
    ArgumentError -> :ok
  end

  defp response_ttl(%Wire.Message{} = msg) do
    ttls = Enum.map(msg.answers ++ msg.authority, & &1.ttl)

    case ttls do
      [] -> @default_ttl
      _ -> ttls |> Enum.min() |> max(@min_ttl)
    end
  end

  # --- GenServer ---

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
