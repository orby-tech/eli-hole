defmodule EliHole.DNS.Server do
  use GenServer

  alias EliHole.DNS.Handler

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
      ip = to_string(:inet.ntoa(client_ip))
      client = "#{ip}:#{client_port}"
      response = Handler.process(packet, client, :udp, ip)
      :gen_udp.send(socket, client_ip, client_port, response)
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
