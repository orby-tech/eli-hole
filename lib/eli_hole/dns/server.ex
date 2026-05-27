defmodule EliHole.DNS.Server do
  use GenServer

  alias EliHole.DNS.{Resolver, QueryLog}

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 5353)

    case :gen_udp.open(port, [:binary, active: true, reuseaddr: true]) do
      {:ok, socket} ->
        Logger.info("DNS server listening on UDP port #{port}")
        {:ok, %{socket: socket, port: port}}

      {:error, reason} ->
        Logger.error("Failed to open UDP port #{port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:udp, socket, client_ip, client_port, packet}, state) do
    Task.start(fn ->
      client = "#{:inet.ntoa(client_ip)}:#{client_port}"

      {time_us, {status, upstream, response, domain, qtype}} =
        :timer.tc(fn ->
          {status, upstream, response} = Resolver.resolve(packet)
          {domain, qtype} = Resolver.extract_query_info(packet)
          {status, upstream, response, domain, qtype}
        end)

      :gen_udp.send(socket, client_ip, client_port, response)
      duration_ms = div(time_us, 1000)

      Logger.debug(
        "DNS #{domain}/#{qtype} from #{client} → #{upstream || "fail"} #{duration_ms}ms"
      )

      QueryLog.log(%{
        id: System.unique_integer([:positive]),
        time: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S"),
        client: client,
        domain: domain,
        type: qtype,
        upstream: upstream,
        duration_ms: duration_ms,
        status: status
      })
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("DNS server got unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_udp.close(socket)
  end
end
