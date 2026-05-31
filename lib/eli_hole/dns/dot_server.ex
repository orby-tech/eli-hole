defmodule EliHole.DNS.DoTServer do
  @moduledoc """
  DNS-over-TLS listener (RFC 7858).

  Accepts TLS connections (default port 853) carrying length-prefixed DNS
  messages — a 2-byte big-endian length followed by the wire-format query, the
  same framing as DNS-over-TCP. Erlang's `packet: 2` socket option handles the
  length prefix on both directions, so each `:ssl.recv/3` yields a bare query
  and each `:ssl.send/2` prepends the length automatically.

  A single connection may carry many queries (pipelined / keep-alive); idle
  connections are closed after `@idle_timeout`. Every query is resolved through
  the shared `EliHole.DNS.Handler`, so blocking, caching, and DNSSEC behave
  identically to plain-UDP and DoH queries.

  The listener stays disabled (the child returns `:ignore`) unless both a TLS
  certificate and key file are configured and present on disk. Generate a
  self-signed pair for local testing with `mix phx.gen.cert`.
  """

  use GenServer

  alias EliHole.DNS.Handler

  require Logger

  @default_port 853
  # RFC 7858 §3.4: close idle connections; clients reconnect on demand.
  @idle_timeout 30_000
  @handshake_timeout 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The TCP port the listener is actually bound to (useful when started on port 0)."
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    certfile = Keyword.get(opts, :certfile)
    keyfile = Keyword.get(opts, :keyfile)

    cond do
      is_nil(certfile) or is_nil(keyfile) ->
        Logger.info("DNS-over-TLS disabled (no certificate configured)")
        :ignore

      not File.exists?(certfile) or not File.exists?(keyfile) ->
        Logger.warning(
          "DNS-over-TLS disabled: certificate or key not found " <>
            "(certfile=#{certfile}, keyfile=#{keyfile})"
        )

        :ignore

      true ->
        listen(port, certfile, keyfile)
    end
  end

  defp listen(port, certfile, keyfile) do
    ssl_opts = [
      :binary,
      packet: 2,
      active: false,
      reuseaddr: true,
      certfile: certfile,
      keyfile: keyfile,
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]

    case :ssl.listen(port, ssl_opts) do
      {:ok, listen_socket} ->
        actual_port =
          case :ssl.sockname(listen_socket) do
            {:ok, {_ip, p}} -> p
            _ -> port
          end

        Logger.info("DNS-over-TLS listening on TCP port #{actual_port}")
        {:ok, %{listen_socket: listen_socket, port: actual_port}, {:continue, :accept}}

      {:error, reason} ->
        Logger.error("Failed to start DNS-over-TLS on port #{port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:accept, %{listen_socket: listen_socket} = state) do
    spawn_link(fn -> accept_loop(listen_socket) end)
    {:noreply, state}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, %{listen_socket: socket}), do: :ssl.close(socket)
  def terminate(_reason, _state), do: :ok

  defp accept_loop(listen_socket) do
    case :ssl.transport_accept(listen_socket) do
      {:ok, transport_socket} ->
        {:ok, pid} =
          Task.Supervisor.start_child(EliHole.TaskSupervisor, fn ->
            handshake_and_serve(transport_socket)
          end)

        # Transfer ownership before the TLS handshake so the handler process
        # receives the socket's active/passive messages (RFC: documented
        # transport_accept → controlling_process → handshake dance).
        case :ssl.controlling_process(transport_socket, pid) do
          :ok -> send(pid, :handshake)
          {:error, _} -> :ssl.close(transport_socket)
        end

        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("DoT accept error: #{inspect(reason)}")
        accept_loop(listen_socket)
    end
  end

  defp handshake_and_serve(transport_socket) do
    receive do
      :handshake -> :ok
    after
      @handshake_timeout -> :ssl.close(transport_socket)
    end

    case :ssl.handshake(transport_socket, @handshake_timeout) do
      {:ok, socket} ->
        {peer, rate_key} = peer_info(socket)
        serve(socket, peer, rate_key)

      {:error, reason} ->
        Logger.debug("DoT handshake failed: #{inspect(reason)}")
        :ssl.close(transport_socket)
    end
  end

  defp serve(socket, peer, rate_key) do
    case :ssl.recv(socket, 0, @idle_timeout) do
      {:ok, query} when byte_size(query) > 0 ->
        response = Handler.process(query, peer, :dot, rate_key)

        case :ssl.send(socket, response) do
          :ok -> serve(socket, peer, rate_key)
          {:error, _} -> :ssl.close(socket)
        end

      {:ok, _empty} ->
        serve(socket, peer, rate_key)

      {:error, _reason} ->
        :ssl.close(socket)
    end
  end

  # Display string (`"ip:port"`) plus the bare IP key used for rate limiting.
  defp peer_info(socket) do
    case :ssl.peername(socket) do
      {:ok, {ip, port}} ->
        ip_str = to_string(:inet.ntoa(ip))
        {"#{ip_str}:#{port}", ip_str}

      _ ->
        {"dot", nil}
    end
  end
end
